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
- (void)setScene:(nullable AUScene *)scene;
- (void)layoutForScale:(CGFloat)scale;
- (void)render;
- (nullable CGImageRef)renderImageWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
