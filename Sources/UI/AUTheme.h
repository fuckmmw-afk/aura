// The theme from the cover: every Liquid Glass pane Spotify and Taurus draw takes the cover's accent as its tint,
// moving to the next track's over 0.6 s, and the player's lit controls (Taurus's Follow the cover paints the shuffle,
// repeat, like and progress bar) slide to it over 0.45 s. Glass that already has a tint of its own is left alone.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void AUThemeStart(void);
// From UIVisualEffectView's hooks: the effect a view should get when it is handed `effect`.
UIVisualEffect *_Nullable AUThemeEffectFor(UIVisualEffectView *view, UIVisualEffect *_Nullable effect);
void AUThemeRemember(UIVisualEffectView *view, UIVisualEffect *_Nullable effect);
void AUThemeViewMoved(UIVisualEffectView *view);
UIColor *_Nullable AUThemeTint(void);

NS_ASSUME_NONNULL_END
