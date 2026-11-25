// A cover taken apart for a 3D scene, the way the lock screen's spatial photos are: the objects on it (people, a
// logo, things — Vision's foreground subjects) each lifted whole onto a layer of its own, and the background under
// them painted in by an inpainting model (Big-LaMa). The layers then slide over the background by their depth, and the
// background, its depth smoothed where the objects were, bends gently by its own: the whole picture moves.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AUSceneLayer : NSObject
@property (nonatomic, strong) UIImage *image;   // the canvas's size, the object alone, edges feathered
@property (nonatomic) double depth;             // its median depth, 0 far ... 1 near
@end

@interface AUScene : NSObject
@property (nonatomic, strong) UIImage *background;            // the cover with its objects painted out
@property (nonatomic, strong, nullable) UIImage *plateDepth;  // the background's depth: smooth, the objects' room filled from around
@property (nonatomic) CGRect square;                          // where the cover sits in the canvas, pixels, origin top left
@property (nonatomic, copy) NSArray<AUSceneLayer *> *layers;  // far to near
@property (nonatomic) double backgroundDepth;
@property (nonatomic) BOOL inpainted;                         // painted by the model, not the quick fallback
// Everything moves by its depth around the background's median c: a point at depth d shifts by tilt x motion x side
// x factor, factor = (d - c) x 2, so the near goes with the tilt and the far against it. The background bends so per
// pixel (its depth is smooth, nothing tears; factor kept within -0.7...0.7); every object moves whole at its own
// median depth, at least 0.3 so each visibly steps forward of what is behind it.
- (double)weightOf:(AUSceneLayer *)layer;
- (double)plateFactorOf:(double)depth;
@property (nonatomic, readonly) double plateCenter, plateLimit;
@property (nonatomic, readonly) double plateReach;            // the largest |factor| on the background: how far its edge moves
@property (nonatomic, readonly, nullable) NSData *plateBytes; // plateDepth as 8-bit gray, plateSide x plateSide
@property (nonatomic, readonly) size_t plateSide;
// plateDepth cut to the cover's square, as squareOf: cuts the background.
- (nullable UIImage *)plateSquare;
// The canvas's square (the cover's own frame) cut out of the background and each layer, for the cover view.
- (nullable UIImage *)squareOf:(UIImage *)image;
- (BOOL)writeTo:(NSString *)folder;
+ (nullable instancetype)readFrom:(NSString *)folder;
@end

// The largest move, a share of the picture's side, at a full tilt and factor 1 (strength x1).
extern const double AUSceneMotion;

// The CPU side of the same motion (lock-screen clips, the Mac harness). Factors for a w x h frame (rows top down)
// where the canvas is drawn in `canvas` (pixels, origin top left); outside it the factor fades to 0 over `falloff`
// pixels. malloc'd; free() it.
float *_Nullable AUScenePlateFactors(AUScene *scene, size_t w, size_t h, CGRect canvas, double falloff);
// Each frame pixel takes the source at (x + margin - shift.x x f, y + margin - shift.y x f), bilinear; the source is
// 4-byte pixels, (w + 2 margin) x (h + 2 margin), the frame's position offset by the margin.
void AUSceneWarp(uint8_t *frame, size_t frameRow, size_t w, size_t h, const uint8_t *source, size_t sourceRow,
                 size_t margin, const float *factors, CGPoint shift);

NS_ASSUME_NONNULL_END
