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
@property (nonatomic, strong, nullable) UIImage *tall;        // the same with the room below it painted on (Fill, lock screen)
@property (nonatomic) double tallness;                        // tall's height over its width (1 when there is none)
@property (nonatomic, strong, nullable) UIImage *plateDepth;  // the background's depth (over `tall` when there is one): smooth
@property (nonatomic, strong, nullable) UIImage *rawDepth;    // the model's depth as it is (256 px): the objects' own relief
@property (nonatomic) CGRect square;                          // where the cover sits in the canvas, pixels, origin top left
@property (nonatomic, copy) NSArray<AUSceneLayer *> *layers;  // far to near
@property (nonatomic) double backgroundDepth;
@property (nonatomic) BOOL inpainted;                         // painted by the model, not the quick fallback
@property (nonatomic) BOOL segmented;                         // SAM looked for every object (not only Vision's subjects)
@property (nonatomic, readonly) BOOL complete;                // both: nothing to make again once the models are here
// Everything moves by its depth around the background's median c: a point at depth d shifts by tilt x motion x side
// x factor, factor = (d - c) x 2, so the near goes with the tilt and the far against it. The background bends so per
// pixel (its depth is smooth, nothing tears; factor kept within -0.6...0.6); every object moves whole at its own
// median depth, at least 0.3 so each visibly steps forward of what is behind it.
- (double)weightOf:(AUSceneLayer *)layer;
- (double)plateFactorOf:(double)depth;
@property (nonatomic, readonly) double plateCenter, plateLimit;
@property (nonatomic, readonly) double plateReach;            // the largest |factor| on the background: how far its edge moves
@property (nonatomic, readonly, nullable) NSData *plateBytes; // plateDepth as 8-bit gray, plateSide x plateHigh
@property (nonatomic, readonly) size_t plateSide, plateHigh;
@property (nonatomic, readonly) double plateLow;              // the background's far end (5th percentile of its depth)
@property (nonatomic, readonly, nullable) NSData *rawBytes;   // rawDepth as 8-bit gray, rawSide x rawSide
@property (nonatomic, readonly) size_t rawSide;
// The canvas's square (the cover's own frame) cut out of the background and each layer, for the cover view.
- (nullable UIImage *)squareOf:(UIImage *)image;
- (BOOL)writeTo:(NSString *)folder;
+ (nullable instancetype)readFrom:(NSString *)folder;
@end

// The largest move of the plain (no Metal) look, a share of the picture's side, at a full tilt and factor 1.
extern const double AUSceneMotion;

NS_ASSUME_NONNULL_END
