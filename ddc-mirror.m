// Mirror the built-in MacBook display brightness to all external displays.

@import Foundation;
@import IOKit;
@import CoreGraphics;
@import ApplicationServices;

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

#if defined(__arm64__)
#define DDC_SUPPORTED 1
#else
#define DDC_SUPPORTED 0
#endif

typedef CFTypeRef IOAVServiceRef;

#if DDC_SUPPORTED
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn       IOAVServiceWriteI2C(IOAVServiceRef service,
                                          uint32_t chipAddress,
                                          uint32_t dataAddress,
                                          void *inputBuffer,
                                          uint32_t inputBufferSize);
#endif

extern int  DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int  DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);
extern int  DisplayServicesRegisterForBrightnessChangeNotifications(
                CGDirectDisplayID display,
                CGDirectDisplayID observer,
                CFNotificationCallback callback);
extern int  DisplayServicesUnregisterForBrightnessChangeNotifications(
                CGDirectDisplayID display, CGDirectDisplayID observer);

extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

#define MAX_DISPLAYS 16
#define DDC_BRIGHTNESS_VCP 0x10
#define DDC_WRITE_RETRIES 3
#define DDC_WRITE_DELAY_US 50000
#define BRIGHTNESS_EPSILON 0.005f
#define MIN_SOFTWARE_BRIGHTNESS 0.05f
#define SOFTWARE_DIM_ANIMATION_SECONDS 0.18
#define SOFTWARE_DIM_FRAME_INTERVAL_US 16667

typedef enum {
    MODE_APPLE_NATIVE,
    MODE_DDC,
    MODE_SOFTWARE_DIM,
} BrightnessMode;

typedef struct {
    uint32_t      sampleCount;
    CGGammaValue *original[3];
    CGGammaValue *scaled[3];
} SoftwareDimTransfer;

typedef struct {
    CGDirectDisplayID id;
    BrightnessMode    mode;
    IOAVServiceRef    av;   // valid only when mode == MODE_DDC
    SoftwareDimTransfer dim;
} ExtDisplay;

static CGDirectDisplayID g_builtin   = 0;
static ExtDisplay        g_externals[MAX_DISPLAYS];
static int               g_extCount  = 0;

static dispatch_source_t g_debounce;
static dispatch_source_t g_softwareDimTimer;
static dispatch_queue_t  g_writeQueue;
static dispatch_source_t g_signalSources[3];
static float             g_pending     = -1.0f;
static float             g_lastHardwareWritten = -1.0f;
static float             g_softwareDimCurrent = -1.0f;
static float             g_externalBrightnessOffset = 0.0f;

static io_connect_t          g_pmRoot     = MACH_PORT_NULL;
static IONotificationPortRef g_pmPort     = NULL;
static io_object_t           g_pmNotifier = MACH_PORT_NULL;
static IONotificationPortRef g_avServicePort = NULL;
static io_iterator_t         g_avServiceMatched = MACH_PORT_NULL;
static io_iterator_t         g_avServiceTerminated = MACH_PORT_NULL;

static int  g_rebootstrapGen     = 0;
static int  g_softwareDimGen     = 0;
static bool g_softwareDimApplied = false;

#define PREFERENCES_DOMAIN CFSTR("ch.emin.ddc-mirror")
#define EXTERNAL_BRIGHTNESS_OFFSET_KEY CFSTR("externalBrightnessOffset")

static float clampBrightness(float value) {
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

static float externalBrightness(float builtinBrightness) {
    return clampBrightness(builtinBrightness + g_externalBrightnessOffset);
}

static void loadPreferences(void) {
    g_externalBrightnessOffset = 0.0f;

    CFPropertyListRef offsetValue =
        CFPreferencesCopyAppValue(EXTERNAL_BRIGHTNESS_OFFSET_KEY, PREFERENCES_DOMAIN);
    if (!offsetValue) return;

    if (CFGetTypeID(offsetValue) == CFNumberGetTypeID()) {
        double offset = 0.0;
        if (CFNumberGetValue((CFNumberRef)offsetValue, kCFNumberDoubleType, &offset) &&
            isfinite(offset)) {
            if (offset < -1.0) offset = -1.0;
            if (offset > 1.0) offset = 1.0;
            g_externalBrightnessOffset = (float)offset;
        }
    } else {
        NSLog(@"ddc-mirror: ignoring non-numeric externalBrightnessOffset preference");
    }

    CFRelease(offsetValue);

    if (fabsf(g_externalBrightnessOffset) >= BRIGHTNESS_EPSILON) {
        NSLog(@"ddc-mirror: external brightness offset %.0f points",
              g_externalBrightnessOffset * 100.0f);
    }
}

static uint8_t ddcBrightness(float value) {
    return (uint8_t)(clampBrightness(value) * 100.0f + 0.5f);
}

#if DDC_SUPPORTED
static IOReturn ddcWriteBrightness(IOAVServiceRef av, uint8_t value) {
    uint8_t pkt[6] = {0};
    pkt[0] = 0x84;
    pkt[1] = 0x03;
    pkt[2] = DDC_BRIGHTNESS_VCP;
    pkt[4] = value;
    pkt[5] = 0x6E ^ 0x51 ^ pkt[0] ^ pkt[1] ^ pkt[2] ^ pkt[3] ^ pkt[4];

    IOReturn last = KERN_SUCCESS;
    for (int i = 0; i < DDC_WRITE_RETRIES; i++) {
        usleep(DDC_WRITE_DELAY_US);
        last = IOAVServiceWriteI2C(av, 0x37, 0x51, pkt, sizeof(pkt));
        if (last == KERN_SUCCESS) break;
    }
    return last;
}
#else
static IOReturn ddcWriteBrightness(IOAVServiceRef av, uint8_t value) {
    (void)av; (void)value;
    return kIOReturnUnsupported;
}
#endif

static float softwareDimLevel(float brightness) {
    return fmaxf(clampBrightness(brightness), MIN_SOFTWARE_BRIGHTNESS);
}

static void freeSoftwareDimTransfer(SoftwareDimTransfer *transfer) {
    for (int i = 0; i < 3; i++) {
        free(transfer->original[i]);
        free(transfer->scaled[i]);
    }
    memset(transfer, 0, sizeof(*transfer));
}

static bool captureSoftwareDimTransfer(CGDirectDisplayID id,
                                       SoftwareDimTransfer *transfer) {
    memset(transfer, 0, sizeof(*transfer));

    uint32_t capacity = CGDisplayGammaTableCapacity(id);
    if (capacity == 0) return false;

    for (int i = 0; i < 3; i++) {
        transfer->original[i] = calloc(capacity, sizeof(CGGammaValue));
        transfer->scaled[i] = calloc(capacity, sizeof(CGGammaValue));
        if (!transfer->original[i] || !transfer->scaled[i]) {
            freeSoftwareDimTransfer(transfer);
            return false;
        }
    }

    uint32_t sampleCount = 0;
    CGError err = CGGetDisplayTransferByTable(id, capacity,
                                              transfer->original[0],
                                              transfer->original[1],
                                              transfer->original[2],
                                              &sampleCount);
    if (err != kCGErrorSuccess || sampleCount == 0) {
        freeSoftwareDimTransfer(transfer);
        return false;
    }

    transfer->sampleCount = sampleCount;
    return true;
}

static bool softwareDimBrightness(ExtDisplay *display, float dimLevel) {
    SoftwareDimTransfer *transfer = &display->dim;
    if (transfer->sampleCount == 0) return false;

    for (uint32_t i = 0; i < transfer->sampleCount; i++) {
        for (int channel = 0; channel < 3; channel++) {
            transfer->scaled[channel][i] = transfer->original[channel][i] * dimLevel;
        }
    }

    CGError err = CGSetDisplayTransferByTable(display->id,
                                              transfer->sampleCount,
                                              transfer->scaled[0],
                                              transfer->scaled[1],
                                              transfer->scaled[2]);
    if (err != kCGErrorSuccess) {
        NSLog(@"ddc-mirror: software dim failed for display %u (%d)",
              display->id, err);
        return false;
    }
    return true;
}

static bool setSoftwareDimBrightnessAll(float brightness) {
    float dimLevel = softwareDimLevel(brightness);
    bool applied = false;

    for (int i = 0; i < g_extCount; i++) {
        ExtDisplay *d = &g_externals[i];
        if (d->mode != MODE_SOFTWARE_DIM) continue;

        applied = softwareDimBrightness(d, dimLevel) || applied;
    }

    if (applied) {
        g_softwareDimApplied = true;
        g_softwareDimCurrent = dimLevel;
    }
    return applied;
}

static void cancelSoftwareDimAnimation(void) {
    g_softwareDimGen++;
    if (g_softwareDimTimer) {
        dispatch_source_cancel(g_softwareDimTimer);
        g_softwareDimTimer = NULL;
    }
}

static void applySoftwareDimBrightness(float brightness, bool animated) {
    if (brightness < 0) return;

    float target = softwareDimLevel(brightness);
    float start = g_softwareDimCurrent >= 0 ? g_softwareDimCurrent : target;

    cancelSoftwareDimAnimation();

    if (!animated || fabsf(target - start) < BRIGHTNESS_EPSILON) {
        setSoftwareDimBrightnessAll(target);
        return;
    }

    int generation = g_softwareDimGen;
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    if (!setSoftwareDimBrightnessAll(start)) return;

    g_softwareDimTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                dispatch_get_main_queue());
    dispatch_source_set_timer(g_softwareDimTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              SOFTWARE_DIM_FRAME_INTERVAL_US * NSEC_PER_USEC,
                              2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_softwareDimTimer, ^{
        if (generation != g_softwareDimGen) return;

        double elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
        float t = (float)fmin(1.0, elapsed / SOFTWARE_DIM_ANIMATION_SECONDS);
        float eased = t * t * (3.0f - 2.0f * t);
        float value = start + (target - start) * eased;

        setSoftwareDimBrightnessAll(value);

        if (t >= 1.0f) {
            cancelSoftwareDimAnimation();
            setSoftwareDimBrightnessAll(target);
        }
    });
    dispatch_resume(g_softwareDimTimer);
}

#if DDC_SUPPORTED
static bool isExternalAVService(io_service_t service) {
    io_name_t name;
    if (IORegistryEntryGetName(service, name) != KERN_SUCCESS ||
        strcmp(name, "DCPAVServiceProxy") != 0) {
        return false;
    }

    CFTypeRef loc = IORegistryEntryCreateCFProperty(service, CFSTR("Location"),
                                                     kCFAllocatorDefault, 0);
    bool external = loc &&
                    CFGetTypeID(loc) == CFStringGetTypeID() &&
                    CFStringCompare((CFStringRef)loc, CFSTR("External"), 0) == kCFCompareEqualTo;
    if (loc) CFRelease(loc);
    return external;
}

static IOAVServiceRef avServiceForDisplay(CGDirectDisplayID displayID) {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (!info) return NULL;

    CFStringRef ioLocation = (CFStringRef)CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!ioLocation || CFGetTypeID(ioLocation) != CFStringGetTypeID()) {
        CFRelease(info);
        return NULL;
    }

    io_string_t path;
    Boolean ok = CFStringGetCString(ioLocation, path, sizeof(path),
                                    kCFStringEncodingUTF8);
    CFRelease(info);
    if (!ok) return NULL;

    io_registry_entry_t display = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (display == MACH_PORT_NULL) return NULL;

    io_iterator_t iter = MACH_PORT_NULL;
    if (IORegistryEntryCreateIterator(display, kIOServicePlane,
                                      kIORegistryIterateRecursively, &iter) != KERN_SUCCESS) {
        IOObjectRelease(display);
        return NULL;
    }

    IOAVServiceRef found = NULL;
    io_service_t s;
    while ((s = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        if (isExternalAVService(s)) {
            found = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
            IOObjectRelease(s);
            break;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(iter);
    IOObjectRelease(display);
    return found;
}
#else
static IOAVServiceRef avServiceForDisplay(CGDirectDisplayID displayID) {
    (void)displayID;
    return NULL;
}
#endif

static void releaseDisplayMap(void) {
    for (int i = 0; i < g_extCount; i++) {
        if (g_externals[i].av) CFRelease(g_externals[i].av);
        g_externals[i].av = NULL;
        freeSoftwareDimTransfer(&g_externals[i].dim);
    }
    g_extCount = 0;
}

static void restoreSoftwareDimIfApplied(void) {
    if (!g_softwareDimApplied) return;

    for (int i = 0; i < g_extCount; i++) {
        ExtDisplay *d = &g_externals[i];
        SoftwareDimTransfer *transfer = &d->dim;
        if (d->mode != MODE_SOFTWARE_DIM || transfer->sampleCount == 0) continue;

        CGSetDisplayTransferByTable(d->id,
                                    transfer->sampleCount,
                                    transfer->original[0],
                                    transfer->original[1],
                                    transfer->original[2]);
    }
    g_softwareDimApplied = false;
    g_softwareDimCurrent = -1.0f;
}

static void addExternal(CGDirectDisplayID id, BrightnessMode mode, IOAVServiceRef av) {
    if (g_extCount >= MAX_DISPLAYS) {
        if (av) CFRelease(av);
        return;
    }

    ExtDisplay display = { .id = id, .mode = mode, .av = av };
    if (mode == MODE_SOFTWARE_DIM && !captureSoftwareDimTransfer(id, &display.dim)) {
        NSLog(@"ddc-mirror: display %u - software-dim unavailable", id);
        return;
    }

    g_externals[g_extCount++] = display;

    const char *name = mode == MODE_APPLE_NATIVE ? "Apple-native" :
                       mode == MODE_DDC ? "DDC" : "software-dim";
    NSLog(@"ddc-mirror: display %u - %s", id, name);
}

static float builtinBrightnessOrDefault(float fallback) {
    float b = 0.0f;
    return g_builtin && DisplayServicesGetBrightness(g_builtin, &b) == 0 ? b : fallback;
}

static void buildDisplayMap(void) {
    restoreSoftwareDimIfApplied();
    releaseDisplayMap();
    g_builtin = 0;

    CGDirectDisplayID ids[MAX_DISPLAYS];
    uint32_t count = 0;
    CGError err = CGGetOnlineDisplayList(MAX_DISPLAYS, ids, &count);
    if (err != kCGErrorSuccess) {
        NSLog(@"ddc-mirror: CGGetOnlineDisplayList failed (%d)", err);
        return;
    }

    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(ids[i])) {
            g_builtin = ids[i];
            break;
        }
    }

    uint8_t probeBrightness = ddcBrightness(externalBrightness(builtinBrightnessOrDefault(0.5f)));
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID id = ids[i];
        if (CGDisplayIsBuiltin(id)) continue;
        if (CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay) continue;

        float probe = 0;
        if (DisplayServicesGetBrightness(id, &probe) == 0) {
            addExternal(id, MODE_APPLE_NATIVE, NULL);
            continue;
        }

        IOAVServiceRef av = avServiceForDisplay(id);
        if (av) {
            if (ddcWriteBrightness(av, probeBrightness) == KERN_SUCCESS) {
                addExternal(id, MODE_DDC, av);
                continue;
            }
            CFRelease(av);
        }

        addExternal(id, MODE_SOFTWARE_DIM, NULL);
    }

    NSLog(@"ddc-mirror: builtin=%u, externals=%d", g_builtin, g_extCount);
}

static void flushHardwareBrightness(void) {
    if (g_pending < 0) return;

    float b = externalBrightness(g_pending);
    if (fabsf(b - g_lastHardwareWritten) < BRIGHTNESS_EPSILON) return;
    g_lastHardwareWritten = b;

    uint8_t ddcVal = ddcBrightness(b);

    for (int i = 0; i < g_extCount; i++) {
        ExtDisplay d = g_externals[i];
        switch (d.mode) {
            case MODE_APPLE_NATIVE: {
                CGDirectDisplayID id = d.id;
                dispatch_async(g_writeQueue, ^{
                    DisplayServicesSetBrightness(id, b);
                });
                break;
            }
            case MODE_DDC: {
                IOAVServiceRef av = d.av;
                CFRetain(av);
                dispatch_async(g_writeQueue, ^{
                    IOReturn r = ddcWriteBrightness(av, ddcVal);
                    if (r != KERN_SUCCESS) {
                        NSLog(@"ddc-mirror: I2C write failed (0x%x)", r);
                    }
                    CFRelease(av);
                });
                break;
            }
            case MODE_SOFTWARE_DIM: {
                break;
            }
        }
    }
}

static void onBrightnessChanged(CFNotificationCenterRef center,
                                void *observer,
                                CFNotificationName name,
                                const void *object,
                                CFDictionaryRef userInfo) {
    NSDictionary *info = (__bridge NSDictionary *)userInfo;
    NSNumber *v = info[@"value"];
    if (v) {
        g_pending = v.floatValue;
    } else {
        g_pending = builtinBrightnessOrDefault(g_pending);
    }
    applySoftwareDimBrightness(externalBrightness(g_pending), true);
    dispatch_source_set_timer(g_debounce,
        dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER,
        5 * NSEC_PER_MSEC);
}

static void syncNow(void) {
    g_pending = builtinBrightnessOrDefault(g_pending);
    g_lastHardwareWritten = -1.0f;
    applySoftwareDimBrightness(externalBrightness(g_pending), false);
    flushHardwareBrightness();
}

static void rebootstrap(void) {
    if (g_builtin) {
        DisplayServicesUnregisterForBrightnessChangeNotifications(g_builtin, g_builtin);
    }
    loadPreferences();
    buildDisplayMap();
    if (g_builtin == 0) {
        NSLog(@"ddc-mirror: no built-in display — idling");
        return;
    }
    DisplayServicesRegisterForBrightnessChangeNotifications(g_builtin, g_builtin,
                                                             onBrightnessChanged);
    syncNow();
}

static void scheduleRebootstrapAttempt(double delaySeconds, int generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != g_rebootstrapGen) return;
        rebootstrap();
    });
}

static void scheduleRebootstrap(double delaySeconds) {
    scheduleRebootstrapAttempt(delaySeconds, ++g_rebootstrapGen);
}

static void scheduleHotplugRebootstrap(void) {
    int generation = ++g_rebootstrapGen;
    scheduleRebootstrapAttempt(1.0, generation);
    scheduleRebootstrapAttempt(4.0, generation);
    scheduleRebootstrapAttempt(8.0, generation);
}

static void onDisplayReconfigured(CGDirectDisplayID display,
                                  CGDisplayChangeSummaryFlags flags,
                                  void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;

    CGDisplayChangeSummaryFlags relevant =
        kCGDisplayAddFlag |
        kCGDisplayRemoveFlag |
        kCGDisplayEnabledFlag |
        kCGDisplayDisabledFlag |
        kCGDisplaySetMainFlag |
        kCGDisplaySetModeFlag |
        kCGDisplayMirrorFlag |
        kCGDisplayUnMirrorFlag |
        kCGDisplayDesktopShapeChangedFlag;
    if ((flags & relevant) == 0) {
        return;
    }
    scheduleHotplugRebootstrap();
}

static void drainDisplayIterator(io_iterator_t iterator) {
    io_object_t object;
    while ((object = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        IOObjectRelease(object);
    }
}

static void onAVServiceChanged(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    drainDisplayIterator(iterator);
    scheduleHotplugRebootstrap();
}

static bool addAVServiceNotification(const char *notificationType,
                                     io_iterator_t *iterator) {
    CFMutableDictionaryRef matching = IOServiceMatching("DCPAVServiceProxy");
    if (!matching) return false;

    kern_return_t r = IOServiceAddMatchingNotification(g_avServicePort,
                                                       notificationType,
                                                       matching,
                                                       onAVServiceChanged,
                                                       NULL,
                                                       iterator);
    if (r != KERN_SUCCESS) return false;

    drainDisplayIterator(*iterator);
    return true;
}

static void startAVServiceNotifications(void) {
    g_avServicePort = IONotificationPortCreate(kIOMainPortDefault);
    if (!g_avServicePort) {
        NSLog(@"ddc-mirror: failed to create AV service notification port");
        return;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(g_avServicePort),
                       kCFRunLoopDefaultMode);

    bool matched = addAVServiceNotification(kIOFirstMatchNotification,
                                            &g_avServiceMatched);
    bool terminated = addAVServiceNotification(kIOTerminatedNotification,
                                               &g_avServiceTerminated);
    if (!matched || !terminated) {
        NSLog(@"ddc-mirror: failed to register AV service notifications");
    }
}

static void onSystemPower(void *refcon, io_service_t service,
                          natural_t messageType, void *messageArgument) {
    switch (messageType) {
        case kIOMessageSystemHasPoweredOn:
            scheduleRebootstrap(3.0);
            break;
        case kIOMessageCanSystemSleep:
        case kIOMessageSystemWillSleep:
            IOAllowPowerChange(g_pmRoot, (long)messageArgument);
            break;
        default:
            break;
    }
}

static void quit(int code) {
    cancelSoftwareDimAnimation();
    if (g_avServiceMatched != MACH_PORT_NULL) {
        IOObjectRelease(g_avServiceMatched);
        g_avServiceMatched = MACH_PORT_NULL;
    }
    if (g_avServiceTerminated != MACH_PORT_NULL) {
        IOObjectRelease(g_avServiceTerminated);
        g_avServiceTerminated = MACH_PORT_NULL;
    }
    if (g_avServicePort) {
        IONotificationPortDestroy(g_avServicePort);
        g_avServicePort = NULL;
    }
    restoreSoftwareDimIfApplied();
    releaseDisplayMap();
    exit(code);
}

static void watchSignal(int sig, size_t index) {
    signal(sig, SIG_IGN);
    g_signalSources[index] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0,
                                                    dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_signalSources[index], ^{
        quit(sig == SIGHUP ? 1 : 0);
    });
    dispatch_resume(g_signalSources[index]);
}

static void printUsage(void) {
    fputs("Usage: ddc-mirror\n"
          "\n"
          "Mirrors the built-in MacBook display's brightness to all connected\n"
          "external displays. Per display, picks one of:\n"
          "  - Apple-native API (Studio Display, Pro Display XDR)\n"
          "  - DDC/CI VCP 0x10 (Apple Silicon, monitors on direct cables)\n"
          "  - Profile-aware software dim (Intel, or monitors behind docks/hubs)\n"
          "\n"
          "Optional calibration:\n"
          "  defaults write ch.emin.ddc-mirror externalBrightnessOffset -float 0.10\n"
          "Use 0.10 for +10 brightness points. Values are clamped to 0.0-1.0.\n", stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                printUsage();
                return 0;
            }
        }

        watchSignal(SIGTERM, 0);
        watchSignal(SIGINT,  1);
        watchSignal(SIGHUP,  2);

        g_writeQueue = dispatch_queue_create("ch.emin.ddc-mirror.write", NULL);

        g_debounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
        dispatch_source_set_event_handler(g_debounce, ^{ flushHardwareBrightness(); });
        dispatch_source_set_timer(g_debounce, DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER, 0);
        dispatch_resume(g_debounce);

        loadPreferences();
        buildDisplayMap();
        if (g_builtin == 0) {
            NSLog(@"ddc-mirror: no built-in display detected — exiting");
            return 0;
        }

        if (DisplayServicesRegisterForBrightnessChangeNotifications(
                g_builtin, g_builtin, onBrightnessChanged) != 0) {
            NSLog(@"ddc-mirror: failed to register brightness notifications");
            return 1;
        }

        CGDisplayRegisterReconfigurationCallback(onDisplayReconfigured, NULL);
        startAVServiceNotifications();

        g_pmRoot = IORegisterForSystemPower(NULL, &g_pmPort, onSystemPower, &g_pmNotifier);
        if (g_pmRoot != MACH_PORT_NULL && g_pmPort != NULL) {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(g_pmPort),
                               kCFRunLoopDefaultMode);
        }

        syncNow();

        CFRunLoopRun();
    }
    return 0;
}
