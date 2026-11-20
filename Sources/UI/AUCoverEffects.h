// The redesigned player's cover with Aura's effects on it.
//
// Taurus's tree (PlayerArtwork.x): CoverArtCellImpl > ... > CoverArtTiltView (354 x 354) > an ElementView the same
// size (the cover Taurus rounds and shrinks while paused) > ImageViewProxy > Encore.ImageView > UIImageView. Each
// queue cell has one; the one on screen is in a window with nothing hidden over it, nearest the window's middle.
//
// Aura lays its own plane over the cover inside the ElementView (so it takes the cover's corners, its paused shrink
// and Taurus's hiding of it under an animated artwork) and the subject, when there is one, in the tilt view above
// the cover, unclipped, so it can step out of the frame. Spotify's own image stays underneath, untouched.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void AUCoverEffectsStart(void);
// From the tilt view's layout and window hooks.
void AUCoverEffectsTiltLaidOut(UIView *tilt);
UIView *_Nullable AUCoverEffectsPlayerRoot(void);

NS_ASSUME_NONNULL_END
