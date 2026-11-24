// The cover cut by its depth map into three soft-edged layers, far (the whole cover, opaque), middle and near, for
// a 2.5D parallax that slides whole layers instead of stretching pixels: the look the lock screen's clip has.
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
    CGImageRef far, middle, near;   // the cover's size, premultiplied; middle and near NULL without a depth map
} AUDepthLayers;

// How far each layer stands (1 near, 0 far): its shift is the tilt times (depth - 0.5).
extern const double AUDepthLayerDepths[3];
extern const double AUSubjectDepth;   // the lifted subject, nearer than anything on the cover

AUDepthLayers AUDepthLayersMake(CGImageRef color, CGImageRef depth);
void AUDepthLayersRelease(AUDepthLayers *layers);
