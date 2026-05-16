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
    CGDirectDisplayID id;
    BrightnessMode    mode;
    IOAVServiceRef    av;   // valid only when mode == MODE_DDC
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

static io_connect_t          g_pmRoot     = MACH_PORT_NULL;
static IONotificationPortRef g_pmPort     = NULL;
static io_object_t           g_pmNotifier = MACH_PORT_NULL;

static int  g_rebootstrapGen     = 0;
static int  g_softwareDimGen     = 0;
static bool g_softwareDimApplied = false;

static float clampBrightness(float value) {
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
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

static void softwareDimBrightness(CGDirectDisplayID id, float brightness) {
    CGSetDisplayTransferByFormula(id,
        0.0f, brightness, 1.0f,
        0.0f, brightness, 1.0f,
        0.0f, brightness, 1.0f);
}

static bool setSoftwareDimBrightnessAll(float brightness) {
    float b = softwareDimLevel(brightness);
    bool applied = false;

    for (int i = 0; i < g_extCount; i++) {
        ExtDisplay d = g_externals[i];
        if (d.mode != MODE_SOFTWARE_DIM) continue;

        softwareDimBrightness(d.id, b);
        applied = true;
    }

    if (applied) {
        g_softwareDimApplied = true;
        g_softwareDimCurrent = b;
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
    }
    g_extCount = 0;
}

static void addExternal(CGDirectDisplayID id, BrightnessMode mode, IOAVServiceRef av) {
    if (g_extCount >= MAX_DISPLAYS) {
        if (av) CFRelease(av);
        return;
    }

    g_externals[g_extCount++] = (ExtDisplay){ .id = id, .mode = mode, .av = av };

    const char *name = mode == MODE_APPLE_NATIVE ? "Apple-native" :
                       mode == MODE_DDC ? "DDC" : "software-dim";
    NSLog(@"ddc-mirror: display %u - %s", id, name);
}

static float builtinBrightnessOrDefault(float fallback) {
    float b = 0.0f;
    return g_builtin && DisplayServicesGetBrightness(g_builtin, &b) == 0 ? b : fallback;
}

static void buildDisplayMap(void) {
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

    uint8_t probeBrightness = ddcBrightness(builtinBrightnessOrDefault(0.5f));
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
    if (fabsf(g_pending - g_lastHardwareWritten) < BRIGHTNESS_EPSILON) return;
    g_lastHardwareWritten = g_pending;

    float b = clampBrightness(g_pending);
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
    applySoftwareDimBrightness(g_pending, true);
    dispatch_source_set_timer(g_debounce,
        dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER,
        5 * NSEC_PER_MSEC);
}

static void syncNow(void) {
    g_pending = builtinBrightnessOrDefault(g_pending);
    g_lastHardwareWritten = -1.0f;
    applySoftwareDimBrightness(g_pending, false);
    flushHardwareBrightness();
}

static void rebootstrap(void) {
    if (g_builtin) {
        DisplayServicesUnregisterForBrightnessChangeNotifications(g_builtin, g_builtin);
    }
    buildDisplayMap();
    if (g_builtin == 0) {
        NSLog(@"ddc-mirror: no built-in display — idling");
        return;
    }
    DisplayServicesRegisterForBrightnessChangeNotifications(g_builtin, g_builtin,
                                                             onBrightnessChanged);
    syncNow();
}

static void scheduleRebootstrap(double delaySeconds) {
    int my = ++g_rebootstrapGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (my != g_rebootstrapGen) return;
        rebootstrap();
    });
}

static void onDisplayReconfigured(CGDirectDisplayID display,
                                  CGDisplayChangeSummaryFlags flags,
                                  void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if ((flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag |
                  kCGDisplaySetMainFlag | kCGDisplayDesktopShapeChangedFlag)) == 0) {
        return;
    }
    scheduleRebootstrap(1.0);
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
    if (g_softwareDimApplied) {
        CGDisplayRestoreColorSyncSettings();
    }
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
          "  - Software gamma dim (Intel, or monitors behind docks/hubs)\n"
          "No flags, no config.\n", stdout);
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
