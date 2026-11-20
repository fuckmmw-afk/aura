// The cover as a 3D postcard: the color texture displaced by its depth map toward the device's tilt, found per pixel
// by a short march through the map (steep parallax with a linear refine), on Metal. Draws only when asked.
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AUParallaxView : MTKView
+ (BOOL)supported;
- (void)setColor:(nullable UIImage *)color depth:(nullable UIImage *)depth;
@property (nonatomic, readonly) BOOL hasContent;
@property (nonatomic) CGPoint tilt;        // -1...1 each axis
@property (nonatomic) CGFloat strength;    // the largest shift, a share of the side (0.03 at 1x)
@property (nonatomic) CGFloat zoom;        // > 1 so a shifted edge never shows past the frame
- (void)render;
@end

NS_ASSUME_NONNULL_END
