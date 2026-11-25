// A scene's background (its objects painted out) bent by its smooth depth toward the device's tilt, on Metal, into a
// CAMetalLayer the caller places under the object layers. A point at depth d moves by tilt x reach x factor(d),
// factor = clamp((d - center) x 2, -limit, limit) — the same rule the objects move by (AUScene). The picture is
// aspect-filled into the layer and zoomed.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface AUParallaxRenderer : NSObject
+ (BOOL)supported;
@property (nonatomic, readonly) CAMetalLayer *layer;
@property (nonatomic, readonly) BOOL hasContent;
@property (nonatomic) CGPoint tilt;          // -1...1 each axis
@property (nonatomic) CGFloat reach;         // the shift at factor 1, a share of the picture's side
@property (nonatomic) CGFloat center, limit;
@property (nonatomic) BOOL presentsWithTransaction;   // drawn in step with the Core Animation layers moved alongside
@property (nonatomic) CGFloat zoom;          // > 1 so a shifted edge never shows past the frame
@property (nonatomic) CGFloat maxPixels;     // the drawable's longer side at most this
// Both drawn into sRGB RGBA8 first: whatever format a picture came in (Core Image's, a JPEG's) the texture is the same.
- (void)setColor:(nullable CGImageRef)color depth:(nullable CGImageRef)depth;
// Sizes the drawable from the layer's bounds and scale; call after the layer's frame changes.
- (void)layoutForScale:(CGFloat)scale;
- (void)render;
// The same drawing into a picture of the given size (the Mac harness looks at these).
- (nullable CGImageRef)renderImageWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
