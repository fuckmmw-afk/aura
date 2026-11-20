// The redesigned player's artwork with Aura's effects, in either of the two places Taurus draws it:
//
// - The cover (any background but Fill). Taurus's tree (PlayerArtwork.x): CoverArtCellImpl > ... > CoverArtTiltView
//   (354 x 354) > an ElementView the same size (the cover, rounded and shrunk while paused) > ImageViewProxy > ...
//   Aura's picture goes inside the ElementView (so it takes its corners, its shrink and Taurus hiding it under an
//   animated artwork); the subject goes in the tilt view above it, unclipped, so it steps out of the frame.
// - Fill (the cover stretched over the top of the screen, Kit/SGRField.m): SGRArtworkField's `_fill` layer, aspect
//   filled, faded out by a gradient mask, with four blurred bands over its foot. Aura's picture goes in as `_fill`'s
//   lowest sublayer, so the mask and the bands lie over it as over the cover; the subject goes above `_fill`, fading
//   later than it, so the artist stays sharp where the cover has already melted into the player.
//
// Spotify's and Taurus's own pictures stay underneath, untouched.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void AUCoverEffectsStart(void);
void AUCoverEffectsTiltLaidOut(UIView *tilt);
void AUCoverEffectsFieldLaidOut(UIView *field);
UIView *_Nullable AUCoverEffectsPlayerRoot(void);

NS_ASSUME_NONNULL_END
