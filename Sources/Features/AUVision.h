// The three model stages, each a plain function run on the pipeline's queue.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Depth Anything V2 Small: a gray map, near bright, spread over 0...255 by its own 1st and 99th percentiles and
// softened a little, at the model's 518 x 392. nil when the model is not on the phone yet (it is being fetched).
CGImageRef _Nullable AUDepthMap(CGImageRef image, NSString *_Nullable *_Nullable error) CF_RETURNS_RETAINED;

// The depth map heavily softened: for a background whose subject was lifted out, so its parallax warps smoothly
// instead of tearing where the subject's outline was.
CGImageRef _Nullable AUSoftenedDepth(CGImageRef depth) CF_RETURNS_RETAINED;

typedef struct {
    CGImageRef _Nullable cutout;       // the subject alone, RGBA, the cover's size
    CGImageRef _Nullable background;   // the cover blurred, the subject's room dimmed a touch
    CGRect bounds;                     // the subject's box, 0...1 of the cover, origin top left
    double coverage;                   // the share of the cover the subject takes
} AUCutoutResult;

// People on the cover (Vision's person instance mask, iOS 17), or with `objects` any foreground subject. The result's
// images are the caller's to release (AUCutoutResultRelease). Empty when there is no subject or it would not read:
// under 3% of the cover, or over 85% (a face filling the frame has nowhere to step out to).
AUCutoutResult AUCutoutSubject(CGImageRef image, BOOL objects, NSString *_Nullable *_Nullable error);
void AUCutoutResultRelease(AUCutoutResult *result);

// Real-ESRGAN x4 over 128 px tiles with an 8 px overlap, the seams cut halfway through each overlap; the result
// scaled down to at most maxSide. nil when the model is not on the phone yet.
CGImageRef _Nullable AUUpscaled(CGImageRef image, size_t maxSide, NSString *_Nullable *_Nullable error) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
