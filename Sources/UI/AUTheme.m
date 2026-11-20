#import "AUTheme.h"
#import "AUCoverEffects.h"
#import "Core/AUCompat.h"
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#import <objc/runtime.h>

static char kOriginalKey;
static NSHashTable<UIVisualEffectView *> *sg_glass;
static UIColor *sg_tint;                 // the glass's tint now, nil for the system's own
static BOOL sg_applying;                 // our own setEffect: passes straight through
static AURGB sg_controls = {-1, -1, -1}; // the controls' color now
static NSString *sg_themedKey;

static Class glassClass(void) {
    static Class glass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ glass = NSClassFromString(@"UIGlassEffect"); });
    return glass;
}

UIColor *AUThemeTint(void) {
    return sg_tint;
}

static BOOL themeOn(void) {
    return AUEnabled(AUKeyTheme);
}

static BOOL eligible(UIVisualEffectView *view) {
    if (!sg_tint || !themeOn()) return NO;
    if (AUInteger(AUKeyThemeScope, 0) == 1) {
        UIView *root = AUCoverEffectsPlayerRoot();
        return root && [view isDescendantOfView:root];
    }
    return YES;
}

// A glass of the system's color: the only kind the theme tints.
static BOOL plainGlass(UIVisualEffect *effect) {
    if (@available(iOS 26.0, *)) {
        Class glass = glassClass();
        if (!glass || ![effect isKindOfClass:glass]) return NO;
        return ((UIGlassEffect *)effect).tintColor == nil;
    }
    return NO;
}

static UIVisualEffect *tinted(UIVisualEffect *original, UIColor *tint) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *copy = [(UIGlassEffect *)original copy];
        copy.tintColor = tint;
        return copy;
    }
    return original;
}

void AUThemeRemember(UIVisualEffectView *view, UIVisualEffect *effect) {
    if (sg_applying) return;
    objc_setAssociatedObject(view, &kOriginalKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (plainGlass(effect)) {
        if (!sg_glass) sg_glass = [NSHashTable weakObjectsHashTable];
        [sg_glass addObject:view];
    }
}

UIVisualEffect *AUThemeEffectFor(UIVisualEffectView *view, UIVisualEffect *effect) {
    if (sg_applying) return effect;
    AUThemeRemember(view, effect);
    return plainGlass(effect) && eligible(view) ? tinted(effect, sg_tint) : effect;
}

static void applyTo(UIVisualEffectView *view) {
    UIVisualEffect *original = objc_getAssociatedObject(view, &kOriginalKey);
    if (!plainGlass(original)) return;
    UIVisualEffect *target = eligible(view) ? tinted(original, sg_tint) : original;
    sg_applying = YES;
    view.effect = target;
    sg_applying = NO;
}

void AUThemeViewMoved(UIVisualEffectView *view) {
    if (!view.window || !objc_getAssociatedObject(view, &kOriginalKey)) return;
    applyTo(view);
}

#pragma mark - the controls

static UIColor *colorOf(AURGB c) {
    return [UIColor colorWithRed:c.r green:c.g blue:c.b alpha:1];
}

@interface AUControlsFade : NSObject
+ (void)fadeTo:(AURGB)target;
@end

@implementation AUControlsFade {
    CADisplayLink *_link;
    AURGB _from, _to;
    CFTimeInterval _start;
}

+ (instancetype)shared {
    static AUControlsFade *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AUControlsFade new]; });
    return shared;
}

+ (void)fadeTo:(AURGB)target {
    [[self shared] fadeTo:target];
}

- (void)fadeTo:(AURGB)target {
    if (!AUTaurusFollowsCover()) return;
    _from = sg_controls.r < 0 ? target : sg_controls;
    _to = target;
    _start = CACurrentMediaTime();
    if (!_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)step:(CADisplayLink *)link {
    double t = MIN(1.0, (CACurrentMediaTime() - _start) / 0.45);
    double eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2;
    // Through hue, not RGB: a straight line from red to cyan passes through gray, and a gray Taurus reads as
    // "give Spotify's green back" for a frame.
    float h0, s0, v0, h1, s1, v1;
    AURGBToHSV(_from, &h0, &s0, &v0);
    AURGBToHSV(_to, &h1, &s1, &v1);
    float dh = h1 - h0;
    if (dh > 0.5f) dh -= 1;
    if (dh < -0.5f) dh += 1;
    float h = h0 + dh * (float)eased;
    if (h < 0) h += 1;
    sg_controls = t >= 1 ? _to : AUHSVToRGB(h, s0 + (s1 - s0) * (float)eased, v0 + (v1 - v0) * (float)eased);
    AUTaurusSetCoverAccent(colorOf(sg_controls));
    if (t >= 1) {
        [_link invalidate];
        _link = nil;
        // Taurus works its own color out from the same cover at about the same time; ours is said last.
        AURGB final = _to;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_link == nil && sg_controls.r == final.r && sg_controls.g == final.g && sg_controls.b == final.b) {
                AUTaurusSetCoverAccent(colorOf(final));
            }
        });
    }
}

@end

#pragma mark - following the artwork

static UIColor *glassTint(AUPalette *palette) {
    if (!palette || palette.gray) return nil;
    float h, s, v;
    AURGBToHSV(palette.accent, &h, &s, &v);
    AURGB c = AUHSVToRGB(h, fminf(0.85f, fmaxf(0.35f, s)), fminf(0.9f, fmaxf(0.55f, v)));
    double strength = AUNumber(AUKeyThemeStrength, 0.32);
    return [UIColor colorWithRed:c.r green:c.g blue:c.b alpha:strength];
}

static void applyAll(BOOL animated) {
    NSArray<UIVisualEffectView *> *views = sg_glass.allObjects;
    void (^apply)(void) = ^{
        for (UIVisualEffectView *view in views) {
            if (view.window) applyTo(view);
        }
    };
    if (animated) [UIView animateWithDuration:0.6 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                                   animations:apply completion:nil];
    else apply();
}

static void follow(AUArtwork *artwork, BOOL force) {
    // A new cover's palette comes a few ms after the cover: the old theme stays until then, no flash of plain glass.
    if (themeOn() && artwork && !artwork.palette) return;
    AUPalette *palette = themeOn() ? artwork.palette : nil;
    NSString *key = palette ? artwork.key : nil;
    if (!force && (key == sg_themedKey || [key isEqualToString:sg_themedKey])) return;
    sg_themedKey = key;
    sg_tint = glassTint(palette);
    applyAll(YES);
    if (palette && !palette.gray) [AUControlsFade fadeTo:palette.accent];
    static NSUInteger logged;
    if (palette && logged++ < 30) {
        AURGB a = palette.accent;
        AULog(@"theme: accent #%02X%02X%02X%@, %lu glass panes", (int)(a.r * 255), (int)(a.g * 255), (int)(a.b * 255),
              palette.gray ? @" (gray cover: system glass)" : @"", (unsigned long)sg_glass.count);
    }
}

void AUThemeStart(void) {
    // The buttons follow the cover through Taurus's own switch: turned on once for the theme, unless it was ever set.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (themeOn() && ![defaults objectForKey:AUTaurusKeyFollowsCover] && ![defaults boolForKey:@"aura.followsCoverSet"]) {
        AUTaurusSetSwitch(AUTaurusKeyFollowsCover, YES);
        [defaults setBool:YES forKey:@"aura.followsCoverSet"];
        AULog(@"theme: Taurus's Follow the cover switched on for the buttons; it takes over from the next launch");
    }
    if (!glassClass()) {
        AULog(@"theme: no UIGlassEffect on this iOS; the controls follow the cover only");
    }
    [NSNotificationCenter.defaultCenter addObserverForName:AUArtworkDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { follow(note.object, NO); }];
    [NSNotificationCenter.defaultCenter addObserverForName:AUSettingsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { follow([AUPipeline shared].current, YES); }];
}
