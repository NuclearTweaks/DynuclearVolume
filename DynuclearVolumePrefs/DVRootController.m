// DynuclearVolumePrefs — Settings pane (PreferenceLoader bundle).
//
// Private Preferences classes declared minimally, resolved at runtime
// (dynamic_lookup) — no SDK stubs, immune to iOS drift.

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
- (NSMutableDictionary *)properties;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
@end

static NSString *const kDomain  = @"com.nucleartweaks.dynuclear-volume";
static NSString *const kChanged = @"com.nucleartweaks.dynuclear-volume/changed";

static float DVRead(NSString *key, float dflt) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyValue((__bridge CFStringRef)key, dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    float v = dflt;
    if (n) { double d = dflt; CFNumberGetValue(n, kCFNumberDoubleType, &d); v = (float)d; CFRelease(n); }
    if (v < 0.f) v = 0.f;
    if (v > 1.f) v = 1.f;
    return v;
}

static void DVWrite(NSString *key, float v) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    double d = v;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &d);
    CFPreferencesSetValue((__bridge CFStringRef)key, n, dom,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(n);
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kChanged, NULL, NULL, true);
}

static NSString *DVFooterText(void) {
    float nmin = DVRead(@"notifMin", 0.35f), nmax = DVRead(@"notifMax", 0.85f);
    float smin = DVRead(@"siriMin", 0.45f),  smax = DVRead(@"siriMax", 0.95f);
    if (DVRead(@"enabled", 1.f) < 0.5f)
        return @"DynuclearVolume is OFF — notification and Siri volumes stay wherever you left them.";
    return [NSString stringWithFormat:
        @"Right before a sound plays, your phone listens to the room for 0.12s.\n\n"
         "Notifications: %.0f%% volume in a quiet room, up to %.0f%% in a loud one.\n"
         "Siri: %.0f%% – %.0f%% on the same scale.",
        nmin * 100, nmax * 100, smin * 100, smax * 100];
}

@interface DVRootController : PSListController
@end

@implementation DVRootController {
    PSSpecifier *_footerSpec;
}

- (NSArray *)specifiers {
    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}

- (PSSpecifier *)liveFooter {
    if (!_footerSpec) {
        for (PSSpecifier *s in [self specifiers]) {
            if ([[s properties] objectForKey:@"footerText"]) { _footerSpec = s; break; }
        }
    }
    return _footerSpec;
}

- (void)updateFooter {
    PSSpecifier *g = [self liveFooter];
    [[g properties] setObject:DVFooterText() forKey:@"footerText"];
    SEL r = NSSelectorFromString(@"reloadSpecifier:");
    if ([self respondsToSelector:r]) {
        IMP imp = [self methodForSelector:r];
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))imp;
        fn(self, r, g);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:NO];
    [self updateFooter];
}

// ─── enabled ────────────────────────────────────────────────────────────────

- (id)readEnabled:(id)spec {
    return @(DVRead(@"enabled", 1.f) >= 0.5f);
}
- (void)writeEnabled:(id)val forSpecifier:(id)spec {
    DVWrite(@"enabled", [val boolValue] ? 1.f : 0.f);
    [self updateFooter];
}

// ─── sliders (value space = 0…1 system volume) ──────────────────────────────

- (id)readNotifMin:(id)spec { return @(DVRead(@"notifMin", 0.35f)); }
- (id)readNotifMax:(id)spec { return @(DVRead(@"notifMax", 0.85f)); }
- (id)readSiriMin:(id)spec  { return @(DVRead(@"siriMin", 0.45f)); }
- (id)readSiriMax:(id)spec  { return @(DVRead(@"siriMax", 0.95f)); }

- (void)writeNotifMin:(id)val forSpecifier:(id)spec {
    float v = [val floatValue];
    float mx = DVRead(@"notifMax", 0.85f);
    if (v > mx) DVWrite(@"notifMax", v);        // keep min ≤ max, pushing the other end
    DVWrite(@"notifMin", v);
    [self updateFooter];
}
- (void)writeNotifMax:(id)val forSpecifier:(id)spec {
    float v = [val floatValue];
    float mn = DVRead(@"notifMin", 0.35f);
    if (v < mn) DVWrite(@"notifMin", v);
    DVWrite(@"notifMax", v);
    [self updateFooter];
}
- (void)writeSiriMin:(id)val forSpecifier:(id)spec {
    float v = [val floatValue];
    float mx = DVRead(@"siriMax", 0.95f);
    if (v > mx) DVWrite(@"siriMax", v);
    DVWrite(@"siriMin", v);
    [self updateFooter];
}
- (void)writeSiriMax:(id)val forSpecifier:(id)spec {
    float v = [val floatValue];
    float mn = DVRead(@"siriMin", 0.45f);
    if (v < mn) DVWrite(@"siriMin", v);
    DVWrite(@"siriMax", v);
    [self updateFooter];
}

@end
