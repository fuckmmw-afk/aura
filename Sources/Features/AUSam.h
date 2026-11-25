// Segment Anything 2.1 Tiny run over a grid of points on the cover ("segment everything"): every object the model
// sees, not just the one or two Vision calls the subject — each sheep in a flock, a tree, a chair.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Masks side x side (8-bit, soft edge), best first, at most `limit`. Those that do not stand out in front of what is
// around them (by `depth`, side x side, 1 near) are left out: a patch of grass or of sky is not an object. Pixels
// already `taken` (other objects, side x side) are not given again. nil when the models are not ready.
NSArray<NSData *> *_Nullable AUSamObjects(CGImageRef square, size_t side, const uint8_t *_Nullable depth,
                                          const uint8_t *_Nullable taken, NSUInteger limit, NSString *_Nullable *_Nullable log);

NS_ASSUME_NONNULL_END
