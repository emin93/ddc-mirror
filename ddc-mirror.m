//
// ddc-mirror.m
//
// Mirror the built-in MacBook display's brightness to all connected
// external displays. Apple Silicon only.
//
// Per-display strategy, picked at startup and on every hot-plug / wake:
//   1. Apple-native externals (Studio Display, Pro Display XDR)
//        → DisplayServicesSetBrightness   (real backlight)
//   2. DDC-capable externals (most monitors on direct USB-C/DP cables)
//        → IOAVServiceWriteI2C VCP 0x10   (real backlight)
//   3. DDC-rejecting externals (most monitors via USB-C dock / KVM / HDMI hub)
//        → CGSetDisplayTransferByFormula  (software gamma scaling)
//
// Build:  make
// Run:    ./ddc-mirror
//

@import Foundation;
@import IOKit;
@import CoreGraphics;
@import ApplicationServices;

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Private framework symbols.
// DisplayServices: linked via -F PrivateFrameworks -framework DisplayServices.
// IOAVService:     re-exported by IOKit on macOS 12+.
// CoreDisplay_*:   re-exported by CoreDisplay.
// ---------------------------------------------------------------------------

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn       IOAVServiceWriteI2C(IOAVServiceRef service,
                                          uint32_t chipAddress,
                                          uint32_t dataAddress,
                                          void *inputBuffer,
                                          uint32_t inputBufferSize);

extern int  DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int  DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);
extern int  DisplayServicesRegisterForBrightnessChangeNotifications(
                CGDirectDisplayID display,
                CGDirectDisplayID observer,
                CFNotificationCallback callback);
extern int  DisplayServicesUnregisterForBrightnessChangeNotifications(
                CGDirectDisplayID display, CGDirectDisplayID observer);

extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#define MAX_DISPLAYS 16

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
static dispatch_queue_t  g_writeQueue;
static float             g_pending     = -1.0f;
static float             g_lastWritten = -1.0f;

static io_connect_t          g_pmRoot     = MACH_PORT_NULL;
static IONotificationPortRef g_pmPort     = NULL;
static io_object_t           g_pmNotifier = MACH_PORT_NULL;

static int  g_rebootstrapGen     = 0;
static bool g_softwareDimApplied = false;

// ---------------------------------------------------------------------------
// DDC/CI write — VCP code 0x10 (luminance/brightness)
// Returns the IOReturn of the LAST write attempt.
// ---------------------------------------------------------------------------

static IOReturn ddcWriteBrightness(IOAVServiceRef av, uint8_t value /* 0..100 */) {
    uint8_t pkt[6];
    pkt[0] = 0x84;
    pkt[1] = 0x03;
    pkt[2] = 0x10;
    pkt[3] = 0x00;
    pkt[4] = value;
    pkt[5] = 0x6E ^ 0x51 ^ pkt[0] ^ pkt[1] ^ pkt[2] ^ pkt[3] ^ pkt[4];

    IOReturn last = KERN_SUCCESS;
    for (int i = 0; i < 3; i++) {
        usleep(50000);  // 50 ms — many monitors drop the first write
        last = IOAVServiceWriteI2C(av, 0x37, 0x51, pkt, sizeof(pkt));
        if (last == KERN_SUCCESS) break;
    }
    return last;
}

// ---------------------------------------------------------------------------
// Software dim via gamma-curve scaling. Works through any cable / dock / KVM
// because it's applied in the WindowServer before pixels hit the wire.
// ---------------------------------------------------------------------------

static void softwareDimBrightness(CGDirectDisplayID id, float brightness) {
    // Linear scale: out = in * brightness, gamma = 1.0
    // brightness=1.0 → no dimming, brightness=0.0 → black
    float b = brightness < 0.05f ? 0.05f : brightness;  // never go fully black
    CGSetDisplayTransferByFormula(id,
        0.0f, b, 1.0f,
        0.0f, b, 1.0f,
        0.0f, b, 1.0f);
    g_softwareDimApplied = true;
}

// ---------------------------------------------------------------------------
// IORegistry walk: CGDirectDisplayID → DCPAVServiceProxy (Location=External)
// ---------------------------------------------------------------------------

static IOAVServiceRef avServiceForDisplay(CGDirectDisplayID displayID) {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (!info) return NULL;

    CFStringRef ioLocation = (CFStringRef)CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!ioLocation || CFGetTypeID(ioLocation) != CFStringGetTypeID()) {
        CFRelease(info);
        return NULL;
    }

    char ioLocationCStr[1024] = {0};
    Boolean ok = CFStringGetCString(ioLocation, ioLocationCStr, sizeof(ioLocationCStr),
                                    kCFStringEncodingUTF8);
    CFRelease(info);
    if (!ok) return NULL;

    io_iterator_t iter = MACH_PORT_NULL;
    if (IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault),
                                       kIOServicePlane,
                                       kIORegistryIterateRecursively,
                                       &iter) != KERN_SUCCESS) {
        return NULL;
    }

    IOAVServiceRef found = NULL;
    bool inDisplaySubtree = false;
    io_service_t s;
    while ((s = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        if (!inDisplaySubtree) {
            io_string_t path;
            if (IORegistryEntryGetPath(s, kIOServicePlane, path) == KERN_SUCCESS &&
                strcmp(path, ioLocationCStr) == 0) {
                inDisplaySubtree = true;
            }
            IOObjectRelease(s);
            continue;
        }

        io_name_t name;
        if (IORegistryEntryGetName(s, name) == KERN_SUCCESS &&
            strcmp(name, "DCPAVServiceProxy") == 0) {
            CFTypeRef loc = IORegistryEntryCreateCFProperty(s, CFSTR("Location"),
                                                             kCFAllocatorDefault, 0);
            bool external = loc &&
                            CFGetTypeID(loc) == CFStringGetTypeID() &&
                            CFStringCompare((CFStringRef)loc, CFSTR("External"), 0) == kCFCompareEqualTo;
            if (loc) CFRelease(loc);
            if (external) {
                found = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
                IOObjectRelease(s);
                break;
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(iter);
    return found;
}

// ---------------------------------------------------------------------------
// Build / tear down the external display map. Probes each external once to
// pick the right strategy.
// ---------------------------------------------------------------------------

static void releaseDisplayMap(void) {
    for (int i = 0; i < g_extCount; i++) {
        if (g_externals[i].av) CFRelease(g_externals[i].av);
        g_externals[i].av = NULL;
    }
    g_extCount = 0;
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

    // Read current built-in brightness once for the DDC probe value
    float currentBrightness = 0.5f;
    {
        float b = 0;
        for (uint32_t i = 0; i < count; i++) {
            if (CGDisplayIsBuiltin(ids[i]) && DisplayServicesGetBrightness(ids[i], &b) == 0) {
                currentBrightness = b;
                break;
            }
        }
    }

    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID id = ids[i];
        if (CGDisplayIsBuiltin(id)) {
            g_builtin = id;
            continue;
        }
        if (CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay) continue;
        if (g_extCount >= MAX_DISPLAYS) break;

        ExtDisplay *d = &g_externals[g_extCount];
        d->id = id;
        d->av = NULL;

        // 1. Apple-native?
        float probe = 0;
        if (DisplayServicesGetBrightness(id, &probe) == 0) {
            d->mode = MODE_APPLE_NATIVE;
            g_extCount++;
            NSLog(@"ddc-mirror: display %u — Apple-native", id);
            continue;
        }

        // 2. DDC-capable? Probe with a write of the current built-in brightness.
        IOAVServiceRef av = avServiceForDisplay(id);
        if (av) {
            uint8_t v = (uint8_t)(currentBrightness * 100.0f + 0.5f);
            if (v > 100) v = 100;
            if (ddcWriteBrightness(av, v) == KERN_SUCCESS) {
                d->mode = MODE_DDC;
                d->av = av;
                g_extCount++;
                NSLog(@"ddc-mirror: display %u — DDC", id);
                continue;
            }
            CFRelease(av);
        }

        // 3. Software dim fallback.
        d->mode = MODE_SOFTWARE_DIM;
        g_extCount++;
        NSLog(@"ddc-mirror: display %u — software-dim (DDC not reachable)", id);
    }

    NSLog(@"ddc-mirror: builtin=%u, externals=%d", g_builtin, g_extCount);
}

// ---------------------------------------------------------------------------
// Apply pending brightness to all externals
// ---------------------------------------------------------------------------

static void flushBrightness(void) {
    if (g_pending < 0) return;
    if (fabsf(g_pending - g_lastWritten) < 0.005f) return;
    g_lastWritten = g_pending;

    float clamped = g_pending;
    if (clamped < 0) clamped = 0;
    if (clamped > 1) clamped = 1;
    uint8_t ddcVal = (uint8_t)(clamped * 100.0f + 0.5f);

    for (int i = 0; i < g_extCount; i++) {
        ExtDisplay d = g_externals[i];
        switch (d.mode) {
            case MODE_APPLE_NATIVE: {
                CGDirectDisplayID id = d.id;
                float b = clamped;
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
                CGDirectDisplayID id = d.id;
                float b = clamped;
                dispatch_async(g_writeQueue, ^{
                    softwareDimBrightness(id, b);
                });
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Brightness change callback
// ---------------------------------------------------------------------------

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
        float b = 0;
        if (DisplayServicesGetBrightness(g_builtin, &b) == 0) g_pending = b;
    }
    dispatch_source_set_timer(g_debounce,
        dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER,
        5 * NSEC_PER_MSEC);
}

// ---------------------------------------------------------------------------
// Re-bootstrap (after hot-plug or wake)
// ---------------------------------------------------------------------------

static void doRebootstrap(void) {
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
    float b = 0;
    if (DisplayServicesGetBrightness(g_builtin, &b) == 0) {
        g_pending = b;
        g_lastWritten = -1.0f;
        flushBrightness();
    }
}

static void scheduleRebootstrap(double delaySeconds) {
    int my = ++g_rebootstrapGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (my != g_rebootstrapGen) return;
        doRebootstrap();
    });
}

// ---------------------------------------------------------------------------
// Display reconfiguration (hot-plug, mode change)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Sleep / wake
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Clean-up on signal: restore factory gamma so software-dimmed displays
// don't stay dimmed after we exit.
// ---------------------------------------------------------------------------

static void onSignal(int sig) {
    if (g_softwareDimApplied) {
        CGDisplayRestoreColorSyncSettings();
    }
    _exit(sig == SIGTERM || sig == SIGINT ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

static void printUsage(void) {
    fputs("Usage: ddc-mirror\n"
          "\n"
          "Mirrors the built-in MacBook display's brightness to all connected\n"
          "external displays. Per display, picks one of:\n"
          "  - Apple-native API (Studio Display, Pro Display XDR)\n"
          "  - DDC/CI VCP 0x10 (most monitors on direct cables)\n"
          "  - Software gamma dim (monitors behind docks/hubs that strip DDC)\n"
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

#if !defined(__arm64__)
        fputs("ddc-mirror: Apple Silicon required.\n", stderr);
        return 1;
#endif

        signal(SIGTERM, onSignal);
        signal(SIGINT,  onSignal);
        signal(SIGHUP,  onSignal);

        g_writeQueue = dispatch_queue_create("ch.emin.ddc-mirror.write",
                                             DISPATCH_QUEUE_CONCURRENT);

        g_debounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
        dispatch_source_set_event_handler(g_debounce, ^{ flushBrightness(); });
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

        // Initial sync
        float b = 0;
        if (DisplayServicesGetBrightness(g_builtin, &b) == 0) {
            g_pending = b;
            g_lastWritten = -1.0f;
            flushBrightness();
        }

        CFRunLoopRun();
    }
    return 0;
}
