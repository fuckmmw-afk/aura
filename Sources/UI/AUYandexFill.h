// Fill for Yandex Music's player, as Taurus draws it in Spotify: the cover across the width at the top of the screen,
// melting into the player below, instead of the cover in the carousel (whose cells are hidden, still swiped).
// AUYandexFillView answers to what UI/AUCoverEffects asks of Taurus's field (a `_fill` layer), so the same 3D scene
// goes onto it.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyYandexFill @"aura.ym.fill"   // on until switched off

@interface AUYandexFillView : UIView
@property (nonatomic, strong, readonly) CALayer *fill;
@end

// From the PlayerArtworkView's layout.
void AUYandexFillUpdate(UIView *artworkView, UICollectionView *_Nullable carousel);
// The fill now showing, or nil (what Taurus's SGRPlayerField() is to UI/AUCoverEffects).
UIView *_Nullable AUYandexFillField(void);
BOOL AUYandexFillOn(void);

NS_ASSUME_NONNULL_END
