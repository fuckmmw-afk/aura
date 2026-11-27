// The scene (AUScene3D) on Metal: the background and every object a mesh lifted by its depth, seen by the swinging
// perspective camera, into a CAMetalLayer the size of the (zoomed) picture.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "Features/AUScene.h"

NS_ASSUME_NONNULL_BEGIN

@interface AUSceneRenderer : NSObject
+ (BOOL)supported;
@property (nonatomic, readonly) CAMetalLayer *layer;
@property (nonatomic) BOOL presentsWithTransaction;   // drawn in step with Core Animation's own changes
@property (nonatomic) CGPoint tilt;                    // -1...1 each axis
@property (nonatomic) CGFloat strength;                // the slider's multiple
@property (nonatomic) CGFloat zoom;                    // only for renderImage: the layer itself is the zoomed picture
@property (nonatomic) BOOL withObjects;
// tall: the picture with the room painted below it (Fill, when the scene has one); the layer is then that tall.
- (void)setScene:(nullable AUScene *)scene tall:(BOOL)tall;
@property (nonatomic, readonly) double frameTall;   // the layer's height over its width
@property (nonatomic, readonly) double frameTop;    // the room above the cover in the layer, a share of its width
// Fill: the finished frame blurred further down — ramps in shares of the layer's height (from, to), sizes in shares
// of its width (the blur's radius); the blur is of the drawn frame, so its sharp and soft parts never slide apart.
- (void)setBlurRamp1:(CGPoint)ramp1 size1:(double)size1 ramp2:(CGPoint)ramp2 size2:(double)size2;
- (void)clearBlur;
- (void)layoutForScale:(CGFloat)scale;
- (void)render;
- (nullable CGImageRef)renderImageWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
