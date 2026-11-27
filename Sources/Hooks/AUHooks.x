// Aura's hooks: plain Objective-C runtime swaps (Logos's internal generator), no Substrate, so they work on a sideloaded
// app. They are installed on the first main queue turn, when every injected dylib (Taurus's too) has loaded.
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTaurus.h"
#import "Core/AUYandex.h"
#import <MediaPlayer/MediaPlayer.h>
#import "Features/AUPipeline.h"
#import "UI/AUCoverEffects.h"
#import "UI/AULockScreen.h"
#import "UI/AUSettings.h"
#import "UI/AUTheme.h"
#import "UI/AUVideoCover.h"
#import "UI/AULyrics.h"
#import "Core/AUYandexColors.h"
#import <AVFoundation/AVFoundation.h>

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

// Yandex Music: the player's cover carousel, its settings screens and the now playing info it hands iOS.
%group YandexPlayer
%hook _TtC23MusicPlayerLandingMaple17PlayerArtworkView
- (void)layoutSubviews {
    %orig;
    AUYandexArtworkViewLaidOut((UIView *)self);
}
%end
%end

%group YandexCell
%hook _TtC23MusicPlayerLandingMaple31PlayerArtworkCollectionViewCell
- (void)layoutSubviews {
    %orig;
    AUYandexArtworkCellLaidOut((UIView *)self);
}
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes {
    %orig;
    AUYandexArtworkCellLaidOut((UIView *)self);
}
%end
%end

// The player's screen: Fill and the lyrics (Core/AUYandex, UI/AULyrics).
%group YandexPlayerScreen
%hook _TtC23MusicPlayerLandingMaple20PlayerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    AUYandexPlayerLaidOut((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    AUYandexPlayerLaidOut((UIViewController *)self);
}
%end
%end

// The app's lyrics as they download (only bodies that look like LRC are read).
%group YandexNet
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!handler) return %orig;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        AULyricsSawBody(data, response.URL);
        handler(data, response, error);
    };
    return %orig(request, wrapped);
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!handler) return %orig;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        AULyricsSawBody(data, response.URL);
        handler(data, response, error);
    };
    return %orig(url, wrapped);
}
%end
%end

// The app's handler for "change playback position", for a tap on a line of the lyrics.
%group YandexRemote
%hook MPRemoteCommand
- (id)addTargetWithHandler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler {
    id token = %orig;
    AUYandexRemoteHandlerAdded(self, handler, nil, NULL);
    return token;
}
- (void)addTarget:(id)target action:(SEL)action {
    %orig;
    AUYandexRemoteHandlerAdded(self, nil, target, action);
}
%end
%end

// The video covers the app plays in its player (UI/AUVideoCover).
%group YandexVideo
%hook AVPlayer
- (void)play {
    %orig;
    AUVideoCoverPlayerStarted((AVPlayer *)self);
}
- (void)setRate:(float)rate {
    %orig;
    if (rate > 0) AUVideoCoverPlayerStarted((AVPlayer *)self);
}
- (void)playImmediatelyAtRate:(float)rate {
    %orig;
    if (rate > 0) AUVideoCoverPlayerStarted((AVPlayer *)self);
}
%end
%end

%group YandexNowPlaying
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig(AUYandexNowPlayingWillSet(self, info));
}
%end
%end

%group YandexSettings
%hook _TtC16MusicLegacyMaple24YPSettingsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    AUYandexSettingsAppeared((UIViewController *)self);
}
%end
%end

%group YandexSettingsCommon
%hook _TtC16MusicLegacyMaple28SettingsCommonViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    AUYandexSettingsAppeared((UIViewController *)self);
}
%end
%end

static void initGlass(void) {
    if (NSClassFromString(@"UIGlassEffect")) %init(Glass);
}

static void startYandex(double started) {
    AUSystemStart();
    %init(YandexNowPlaying);
    %init(YandexVideo);
    %init(YandexNet);
    if (NSClassFromString(@"_TtC23MusicPlayerLandingMaple20PlayerViewController")) %init(YandexPlayerScreen);
    AUYandexStart();
    [AUPipeline.shared start];
    if (NSClassFromString(@"_TtC23MusicPlayerLandingMaple17PlayerArtworkView")) {
        %init(YandexPlayer);
        if (NSClassFromString(@"_TtC23MusicPlayerLandingMaple31PlayerArtworkCollectionViewCell")) %init(YandexCell);
        else AULog(@"no PlayerArtworkCollectionViewCell: covers are found on the artwork view's layout only");
        AUCoverEffectsStart();
    } else {
        AULog(@"no PlayerArtworkView in this Yandex Music: no cover effects");
    }
    if (NSClassFromString(@"_TtC16MusicLegacyMaple24YPSettingsViewController")) %init(YandexSettings);
    if (NSClassFromString(@"_TtC16MusicLegacyMaple28SettingsCommonViewController")) %init(YandexSettingsCommon);
    initGlass();
    AUThemeStart();
    AULockScreenStart();
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    AULog(@"Aura %s started in Yandex Music %@ in %.1f ms on iOS %@, footprint %@, models from %@", AURA_VERSION, version, AUNowMs() - started,
          UIDevice.currentDevice.systemVersion, AUBytes(AUFootprint()), AUModelManager.shared.serverConfigured ? @"the server" : @"nowhere (no URL in this build)");
}

static void start(void) {
    double started = AUNowMs();
    if (AUHostYandex()) {
        startYandex(started);
        return;
    }
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
    initGlass();
    AUThemeStart();
    AULockScreenStart();
    AULog(@"Aura %s started in %.1f ms on iOS %@, footprint %@, models from %@", AURA_VERSION, AUNowMs() - started,
          UIDevice.currentDevice.systemVersion, AUBytes(AUFootprint()), AUModelManager.shared.serverConfigured ? @"the server" : @"nowhere (no URL in this build)");
}

%ctor {
    @autoreleasepool {
        // Before the app's own code: its colours and its remote command handlers pass through Aura from the start.
        if (AUHostYandex()) {
            AUCrashLogInstall();
            AUYandexColorsInstall();
            %init(YandexRemote);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ start(); });
    }
}
