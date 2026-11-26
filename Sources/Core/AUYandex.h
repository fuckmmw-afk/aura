// Yandex Music (ru.yandex.mobile.music) as Aura's host, in place of Taurus on Spotify.
//
// There is no Taurus there to hand over the artwork, the track or a settings page, so Aura reads them where every
// player puts them: the now playing info the app gives MPNowPlayingInfoCenter (title, artist, album, artwork). The
// lock screen's 3:4 clip rides on that same info: Aura's keys are merged into what the app sets, for as long as the
// app's info is still about the track the clip was made for.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL AUHostYandex(void);
void AUYandexStart(void);

// From the MPNowPlayingInfoCenter hook, on any thread: what the app is setting, with Aura's own keys merged in.
NSDictionary *_Nullable AUYandexNowPlayingWillSet(id center, NSDictionary *_Nullable info);

UIImage *_Nullable AUYandexArtwork(NSString *_Nullable *_Nullable trackURI, NSString *_Nullable *_Nullable pictureKey, BOOL *_Nullable exact);
extern NSNotificationName const AUYandexArtworkDidChangeNotification;
NSString *_Nullable AUYandexTrackURI(void);
NSString *_Nullable AUYandexTrackTitle(void);
NSString *_Nullable AUYandexTrackPictureKey(void);

// The lock screen's extras (nil to take them back) for the track called `title`.
void AUYandexSetExtras(NSDictionary *_Nullable extras, NSString *_Nullable title);

// The player: Yandex's PlayerArtworkView laid out (its carousel holds one cell per track, the playing one centred).
void AUYandexArtworkViewLaidOut(UIView *view);
void AUYandexArtworkCellLaidOut(UIView *cell);   // one of its cells, as the carousel scrolls
// A settings screen of Yandex's appeared: Aura's button goes under its table (the table's own rows stay as they are).
void AUYandexSettingsAppeared(UIViewController *controller);
// Aura's page over whatever shows now.
void AUYandexPresentSettings(void);

NS_ASSUME_NONNULL_END
