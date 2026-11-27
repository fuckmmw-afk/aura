// Aura's own lyrics screen for Yandex Music, in place of the app's: the line being sung big and white, the others
// dimmed and blurred the further they are, a sweep through the line as it is sung, a spring as it moves on; a tap on a
// line goes there. Every part of the look is a setting (Aura → «Текст песни»).
//
// The words come from the app's own lyrics (its LRC, caught as it downloads it) or, when there is none, from LRCLIB
// (lrclib.net, by title, artist and length). The time comes from the now playing info the app keeps up to date.
// Laid over the app's lyrics view (PlayerViewController's trackLyricsHostingView), which stays there unseen.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyLyrics @"aura.lyr.on"   // on until switched off

void AULyricsStart(void);
// The player's view controller laid out (Core/AUYandex).
void AULyricsPlayerLaidOut(UIViewController *controller);
// A body some download brought: kept if it is the lyrics of the playing song (LRC).
void AULyricsSawBody(NSData *_Nullable data, NSURL *_Nullable url);
UIViewController *_Nullable AULyricsSettingsPage(void);
// The app's lyrics folded up into the cover's card: Aura's over it, in the centred cell's place.
void AULyricsMiniUpdate(UIView *artworkView, UIView *_Nullable cell, BOOL (^visible)(void));

NS_ASSUME_NONNULL_END
