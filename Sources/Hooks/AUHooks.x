// Aura's hooks: plain Objective-C runtime swaps (Logos's internal generator), no Substrate, so they work on a sideloaded
// app. They are installed on the first main queue turn, when every injected dylib (Taurus's too) has loaded.
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#import "UI/AUCoverEffects.h"
#import "UI/AULockScreen.h"
#import "UI/AUSettings.h"
#import "UI/AUTheme.h"

%group Player
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    AUCoverEffectsTiltLaidOut((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    AUCoverEffectsTiltLaidOut((UIView *)self);
}
%end
%end

%group Field
%hook SGRArtworkField
- (void)layoutSubviews {
    %orig;
    AUCoverEffectsFieldLaidOut((UIView *)self);
}
- (void)setFills:(BOOL)fills {
    %orig;
    AUCoverEffectsFieldLaidOut((UIView *)self);
}
%end
%end

%group Glass
%hook UIVisualEffectView
- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    UIVisualEffectView *view = %orig;
    if (view) AUThemeRemember(view, effect);
    return view;
}
- (void)setEffect:(UIVisualEffect *)effect {
    %orig(AUThemeEffectFor((UIVisualEffectView *)self, effect));
}
- (void)didMoveToWindow {
    %orig;
    AUThemeViewMoved((UIVisualEffectView *)self);
}
%end
%end

%group Settings
%hook SGTaurusSettingsPage
- (id)initWithSections:(NSArray *)sections {
    return %orig(AUSettingsWithAuraRow(sections));
}
%end
%end

static void start(void) {
    double started = AUNowMs();
    if (!AUTaurusPresent()) {
        AULog(@"Aura %s: Taurus (spotifyglass) not found, staying off. Missing: %@", AURA_VERSION, AUTaurusMissing());
        return;
    }
    NSString *missing = AUTaurusMissing();
    if (![missing isEqualToString:@"none"]) AULog(@"Taurus lacks: %@", missing);
    if (NSClassFromString(@"SGTaurusSettingsPage") && AUTaurusRowsAvailable()) {
        %init(Settings);
    } else {
        AULog(@"no Taurus settings page to join; Aura's settings are unreachable");
    }
    if (!AUTaurusRedesigned()) {
        AULog(@"Aura %s: Taurus runs the native look; Aura needs the redesign (Mod Settings > Appearance > Redesigned UI)", AURA_VERSION);
        return;
    }
    AUSystemStart();
    AUTaurusFollowTrack();
    [AUPipeline.shared start];
    if (NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView")) {
        %init(Player);
        AUCoverEffectsStart();
    } else {
        AULog(@"no CoverArtTiltView in this Spotify: no cover effects");
    }
    if (NSClassFromString(@"SGRArtworkField")) {
        %init(Field);
        AUCoverEffectsStart();
    } else {
        AULog(@"no SGRArtworkField in Taurus: no effects on the Fill background");
    }
    if (NSClassFromString(@"UIGlassEffect")) %init(Glass);
    AUThemeStart();
    AULockScreenStart();
    AULog(@"Aura %s started in %.1f ms on iOS %@, footprint %@, models from %@", AURA_VERSION, AUNowMs() - started,
          UIDevice.currentDevice.systemVersion, AUBytes(AUFootprint()), AUModelManager.shared.serverConfigured ? @"the server" : @"nowhere (no URL in this build)");
}

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ start(); });
    }
}
