// DynuclearVolume — the room decides how loud your phone is.
//
// Measures ambient noise through the mic right before a notification sound or
// a Siri response plays, then drives the system volume: quiet room → the
// configured minimum, loud room → the configured maximum (linear in between).
//
// How, concretely:
//   1. MSHookFunction the four `AudioServicesPlay{System,Alert}Sound*` C
//      entry points. Every notification tone / SMS alert / Siri earcon on iOS
//      funnels through them BEFORE audio starts — the perfect moment to sample
//      the room and retune volume.
//   2. MSHookMessageEx -[AVAudioPlayer play] — Siri spoken responses play
//      through AVAudioPlayer while the session mode is "SpokenAudio".
//   3. Sampling: AVAudioEngine input tap, 120 ms window, RMS → dBFS → 0…1
//      anchor, 300 ms debounce so bursts (message + preview + haptic) sample
//      once. The mic is only hot for the length of the window.
//   4. Applying: runtime-probed backend. iOS 27 exposes per-category volumes
//      on AVSystemController (`setVolumeTo:forCategory:`; singleton
//      `+sharedAVSystemController` — the old `+systemController` is gone).
//      Fallback: `MRMediaRemoteSetSystemVolume` if exported. On jailbroken
//      iOS both routes exist on device; simulators stub them out (logged).
//
// Everything is resolved at runtime (dynamic_lookup): no private SDK stubs,
// nothing to break when Apple renames things — worst case a backend logs
// "unavailable" and the tweak degrades to pass-through.

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

static NSString *const kDomain  = @"com.nucleartweaks.dynuclear-volume";
static NSString *const kChanged = @"com.nucleartweaks.dynuclear-volume/changed";

static BOOL   gEnabled   = YES;
static float  gNotifMin  = 0.35f, gNotifMax = 0.85f;
static float  gSiriMin   = 0.45f, gSiriMax  = 0.95f;

// ─── substrate (runtime-resolved; never call a NULL pointer) ────────────────

typedef void (*DVMHookMsg)(Class, SEL, IMP, IMP *);
typedef void *(*DVMHookFn)(void *, void *, void **);

static DVMHookMsg gMsgHook = NULL;
static DVMHookFn  gCFuncHook = NULL;

// forward
static void DVHandleAudioServices(SystemSoundID ID, BOOL alert);

static void DVFindSubstrate(void) {
    void *h = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                     RTLD_LAZY | RTLD_GLOBAL);
    if (!h) h = dlopen("/usr/lib/ellekit/libellekit.dylib", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) h = dlopen("/var/jb/usr/lib/ellekit/libellekit.dylib", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) h = dlopen("/usr/lib/libhooker.dylib", RTLD_LAZY | RTLD_GLOBAL);
    gMsgHook   = h ? (DVMHookMsg)dlsym(h, "MSHookMessageEx") : NULL;
    gCFuncHook = h ? (DVMHookFn)dlsym(h, "MSHookFunction") : NULL;
    // loader-prelinked substrate is globally visible even when the image is RTLD_FIRST
    if (!gMsgHook)   gMsgHook   = (DVMHookMsg)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!gCFuncHook) gCFuncHook = (DVMHookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
}

static FILE *DVProof(void) {
    return fopen("/Users/spencer/dynuclearvolume-proof.txt", "a"); // JB-sim host FS; absent on device
}
static void DVLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[DynuclearVolume] %@", s);
    FILE *pf = DVProof();
    if (pf) { fprintf(pf, "%s\n", s.UTF8String); fclose(pf); }
}

// ─── preferences ────────────────────────────────────────────────────────────

static float DVReadFloat(NSString *key, float dflt) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyValue((__bridge CFStringRef)key, dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    float v = dflt;
    if (n) { double d = dflt; CFNumberGetValue(n, kCFNumberDoubleType, &d); v = (float)d; CFRelease(n); }
    if (v < 0.f) v = 0.f;
    if (v > 1.f) v = 1.f;
    return v;
}

static void DVReload(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    gEnabled  = DVReadFloat(@"enabled", 1.f) >= 0.5f;
    gNotifMin = DVReadFloat(@"notifMin", 0.35f);
    gNotifMax = DVReadFloat(@"notifMax", 0.85f);
    gSiriMin  = DVReadFloat(@"siriMin", 0.45f);
    gSiriMax  = DVReadFloat(@"siriMax", 0.95f);
    if (gNotifMin > gNotifMax) { float t = gNotifMin; gNotifMin = gNotifMax; gNotifMax = t; }
    if (gSiriMin  > gSiriMax)  { float t = gSiriMin;  gSiriMin  = gSiriMax;  gSiriMax  = t; }
}

static void DVPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *u, CFDictionaryRef d) {
    DVReload();
    DVLog([NSString stringWithFormat:@"prefs reloaded: enabled=%d notif=[%.2f,%.2f] siri=[%.2f,%.2f]",
           gEnabled, gNotifMin, gNotifMax, gSiriMin, gSiriMax]);
}

// Debug/test trigger: `notifyutil -p com.nucleartweaks.dynuclear-volume/selftest`
// runs one full listen→map→apply cycle right now (proof file shows the numbers).
static void DVSelftest(CFNotificationCenterRef c, void *o, CFStringRef n,
                       const void *u, CFDictionaryRef d) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DVHandleAudioServices(1005, YES);
    });
}

// ─── ambient noise sampling ─────────────────────────────────────────────────

static CFAbsoluteTime gLastSampleT = 0;
static float gLastAmbient = 0.f;   // 0 = quiet room … 1 = loud room

// Map dBFS to the 0…1 room-loudness anchor. -60 dBFS and below reads as
// silence (mechanical floor of phone mics), -12 dBFS reads as a loud room.
static float DVAmbientFromDb(float dbfs) {
    float a = (dbfs + 60.f) / 48.f;
    return a < 0.f ? 0.f : (a > 1.f ? 1.f : a);
}

static float DVAmbient(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastSampleT < 0.30) return gLastAmbient;   // burst debounce
    gLastSampleT = now;

    @autoreleasepool {
        AVAudioEngine *eng = [[AVAudioEngine alloc] init];
        AVAudioInputNode *input = eng.inputNode;
        AVAudioFormat *fmt = [input inputFormatForBus:0];
        if (!fmt || fmt.sampleRate <= 0 || fmt.channelCount == 0) {
            return gLastAmbient;          // no mic in this process/device
        }

        __block double sum = 0, count = 0;
        [input installTapOnBus:0 bufferSize:1024 format:fmt
                           block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
            float *ch = buf.floatChannelData[0];
            NSUInteger n = buf.frameLength;
            for (NSUInteger i = 0; i < n; i++) { sum += (double)ch[i] * ch[i]; count += 1; }
        }];
        NSError *err = nil;
        [eng prepare];
        BOOL started = [eng startAndReturnError:&err];
        usleep(120 * 1000);                                 // 120 ms window
        [input removeTapOnBus:0];
        if (started) [eng stop];

        float ambient = gLastAmbient;
        if (started && count > 0) {
            float rms = (float)sqrt(sum / count);
            float dbfs = rms > 1e-7f ? 20.f * log10f(rms) : -80.f;
            float a = DVAmbientFromDb(dbfs);
            ambient = 0.5f * gLastAmbient + 0.5f * a;       // light smoothing
        }
        gLastAmbient = ambient;
    }
    return gLastAmbient;
}

// ─── volume application ─────────────────────────────────────────────────────

typedef void (*MRSetSystemVolume)(float);

static id gASC = nil;                                   // AVSystemController singleton
static MRSetSystemVolume gMRSet = NULL;                 // MediaRemote fallback
static BOOL gBackendProbed = NO;

static void DVProbeBackends(void) {
    if (gBackendProbed) return;
    gBackendProbed = YES;

    Class ASC = NSClassFromString(@"AVSystemController");
    SEL sh = NSSelectorFromString(@"sharedAVSystemController");
    if (ASC && [ASC respondsToSelector:sh]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        gASC = [ASC performSelector:sh];
#pragma clang diagnostic pop
    }
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                      RTLD_LAZY);
    gMRSet = (MRSetSystemVolume)dlsym(mr ?: RTLD_DEFAULT, "MRMediaRemoteSetSystemVolume");
    if (!gMRSet) gMRSet = (MRSetSystemVolume)dlsym(RTLD_DEFAULT, "MRMediaRemoteSetSystemVolume");

    DVLog([NSString stringWithFormat:@"backends: AVSystemController=%@ MRMediaRemoteSetSystemVolume=%@",
           gASC ? @"yes" : @"no", gMRSet ? @"yes" : @"no"]);
}

static void DVSetASCCategoryVolume(float v, NSString *category) {
    SEL svc = NSSelectorFromString(@"setVolumeTo:forCategory:");
    if (!gASC || ![gASC respondsToSelector:svc]) return;
    NSMethodSignature *sig = [gASC methodSignatureForSelector:svc];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:svc];
    [inv setTarget:gASC];
    [inv setArgument:&v atIndex:2];
    [inv setArgument:&category atIndex:3];
    [inv invoke];
}

// isSiri picks the volume bucket: on iOS Siri has its own volume category.
static void DVApplyVolume(float v, BOOL isSiri) {
    v = v < 0.f ? 0.f : (v > 1.f ? 1.f : v);
    DVProbeBackends();
    BOOL any = NO;
    if (gASC) {
        @try {
            DVSetASCCategoryVolume(v, isSiri ? @"Siri" : @"Ringtone");
            any = YES;
        } @catch (id e) {
            // unknown category on this iOS — fall through to MR only
            DVLog([NSString stringWithFormat:@"ASC category '%@' rejected: %@",
                   isSiri ? @"Siri" : @"Ringtone", [e name]]);
        }
    }
    if (gMRSet) { gMRSet(v); any = YES; }
    DVLog([NSString stringWithFormat:@"apply %.2f (%@) %@backend",
           v, isSiri ? @"siri" : @"notif", any ? @"" : @"NO — pass-through "]);
}

static float DVMapVolume(float ambient, BOOL isSiri) {
    float lo = isSiri ? gSiriMin : gNotifMin;
    float hi = isSiri ? gSiriMax : gNotifMax;
    return lo + ambient * (hi - lo);
}

// ─── AudioServices hooks (the notification moment) ──────────────────────────

// Sounds that fire on every keystroke / trivial UI event. They play no audible
// alert, and sampling for them would keep the mic hot — skip outright.
static BOOL DVIsUltrasonicSystemSound(SystemSoundID ID) {
    static const SystemSoundID skip[] = {
        1152, 1153, 1154, 1155, 1156, 1157,   // keyboard clicks, lock flicks
        1300, 1301, 1302, 1303,               // haptic-only + system ticks
        4096                                  // silent/vibrate sentinel
    };
    for (unsigned i = 0; i < sizeof(skip)/sizeof(skip[0]); i++)
        if (ID == skip[i]) return YES;
    return NO;
}

static void DVHandleAudioServices(SystemSoundID ID, BOOL alert) {
    if (!gEnabled || DVIsUltrasonicSystemSound(ID)) return;
    // An alert *about* Siri while the assistant session is up belongs to Siri.
    BOOL siri = NO;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if ([s.mode isEqualToString:AVAudioSessionModeSpokenAudio]) siri = YES;
    } @catch (id e) {}
    float ambient = DVAmbient();
    float target  = DVMapVolume(ambient, siri);
    DVLog([NSString stringWithFormat:@"%@(%lu): ambient %.2f -> vol %.2f%@",
           alert ? @"Alert" : @"System", (unsigned long)ID, ambient, target,
           siri ? @" [siri]" : @""]);
    DVApplyVolume(target, siri);
}

typedef void (*PlayWithCompletion)(SystemSoundID, void (^)(void));
typedef void (*PlayPlain)(SystemSoundID);

static PlayWithCompletion orig_PlaySystemCompletion = NULL;
static PlayWithCompletion orig_PlayAlertCompletion  = NULL;
static PlayPlain          orig_PlaySystem           = NULL;
static PlayPlain          orig_PlayAlert            = NULL;

static void rep_PlaySystemCompletion(SystemSoundID ID, void (^cb)(void)) {
    DVHandleAudioServices(ID, NO);
    if (orig_PlaySystemCompletion) orig_PlaySystemCompletion(ID, cb);
}
static void rep_PlayAlertCompletion(SystemSoundID ID, void (^cb)(void)) {
    DVHandleAudioServices(ID, YES);
    if (orig_PlayAlertCompletion) orig_PlayAlertCompletion(ID, cb);
}
static void rep_PlaySystem(SystemSoundID ID) {
    DVHandleAudioServices(ID, NO);
    if (orig_PlaySystem) orig_PlaySystem(ID);
}
static void rep_PlayAlert(SystemSoundID ID) {
    DVHandleAudioServices(ID, YES);
    if (orig_PlayAlert) orig_PlayAlert(ID);
}

// ─── AVAudioPlayer hook (Siri spoken responses) ─────────────────────────────

static BOOL (*orig_AP_play)(id, SEL) = NULL;

static BOOL rep_AP_play(id self, SEL _cmd) {
    if (gEnabled) {
        @try {
            AVAudioSession *s = [AVAudioSession sharedInstance];
            if ([s.mode isEqualToString:AVAudioSessionModeSpokenAudio]) {
                float ambient = DVAmbient();
                float target  = DVMapVolume(ambient, YES);
                DVLog([NSString stringWithFormat:@"AVAudioPlayer play (siri): ambient %.2f -> vol %.2f",
                       ambient, target]);
                DVApplyVolume(target, YES);
            }
        } @catch (id e) {}
    }
    return orig_AP_play ? orig_AP_play(self, _cmd) : NO;
}

// ─── install ────────────────────────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        DVFindSubstrate();
        DVReload();
        if (!gEnabled) { DVLog(@"disabled in settings — idle"); return; }
        if (!gCFuncHook) { DVLog(@"no MSHookFunction available — idle"); return; }

        DVLog([NSString stringWithFormat:@"installed pid=%d notif=[%.2f,%.2f] siri=[%.2f,%.2f]",
               getpid(), gNotifMin, gNotifMax, gSiriMin, gSiriMax]);

        struct { const char *name; void *rep; void **orig; } hooks[] = {
            { "AudioServicesPlaySystemSoundWithCompletion", (void *)rep_PlaySystemCompletion, (void **)&orig_PlaySystemCompletion },
            { "AudioServicesPlayAlertSoundWithCompletion",  (void *)rep_PlayAlertCompletion,  (void **)&orig_PlayAlertCompletion },
            { "AudioServicesPlaySystemSound",               (void *)rep_PlaySystem,           (void **)&orig_PlaySystem },
            { "AudioServicesPlayAlertSound",                (void *)rep_PlayAlert,            (void **)&orig_PlayAlert },
        };
        int nh = (int)(sizeof(hooks) / sizeof(hooks[0]));
        for (int i = 0; i < nh; i++) {
            void *sym = dlsym(RTLD_DEFAULT, hooks[i].name);
            if (sym) gCFuncHook(sym, hooks[i].rep, hooks[i].orig);
            else DVLog([NSString stringWithFormat:@"missing symbol %s", hooks[i].name]);
        }

        if (gMsgHook) {
            Class AP = NSClassFromString(@"AVAudioPlayer");
            if (AP) gMsgHook(AP, @selector(play), (IMP)rep_AP_play, (IMP *)&orig_AP_play);
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, DVPrefsChanged,
                                        (__bridge CFStringRef)kChanged, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, DVSelftest,
                                        CFSTR("com.nucleartweaks.dynuclear-volume/selftest"), NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }
}
