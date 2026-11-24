// A cover taken apart for a 3D scene, the way the lock screen's spatial photos are: the objects on it (people, a
// logo, things — Vision's foreground subjects) each lifted whole onto a layer of its own, and the background under
// them painted in by an inpainting model (Big-LaMa), extended above and below the cover so it fills a 3:4 screen
// without cropping its sides. The layers then slide over the background by their depth; nothing is ever bent.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AUSceneLayer : NSObject
@property (nonatomic, strong) UIImage *image;   // the canvas's size, the object alone, edges feathered
@property (nonatomic) double depth;             // its median depth, 0 far ... 1 near
@end

@interface AUScene : NSObject
@property (nonatomic, strong) UIImage *background;            // the canvas (3:4): the cover with its objects painted out, extended
@property (nonatomic) CGRect square;                          // where the cover sits in the canvas, pixels, origin top left
@property (nonatomic, copy) NSArray<AUSceneLayer *> *layers;  // far to near
@property (nonatomic) double backgroundDepth;
@property (nonatomic) BOOL inpainted;                         // painted by the model, not the quick fallback
// How far a layer moves with the tilt, as a share of the strength: 0.5 ... 1 by its depth (the background moves against it).
- (double)weightOf:(AUSceneLayer *)layer;
// The canvas's square (the cover's own frame) cut out of the background and each layer, for the cover view.
- (nullable UIImage *)squareOf:(UIImage *)image;
- (BOOL)writeTo:(NSString *)folder;
+ (nullable instancetype)readFrom:(NSString *)folder;
@end

NS_ASSUME_NONNULL_END
