// The cover's colors by k-means over its pixels (vDSP), no network: the theme's source.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    float r, g, b;   // 0...1, sRGB
} AURGB;

@interface AUPalette : NSObject
// The clusters, the largest first, and the share of the cover each holds.
@property (nonatomic, readonly) NSArray<NSValue *> *colors;   // AURGB each
@property (nonatomic, readonly) NSArray<NSNumber *> *weights;
@property (nonatomic, readonly) AURGB dominant;  // the largest cluster
@property (nonatomic, readonly) AURGB accent;    // the most colorful one that holds enough of the cover
@property (nonatomic, readonly) AURGB dark;      // the darkest
@property (nonatomic, readonly) BOOL gray;       // no cluster is colorful: a black and white cover
+ (nullable instancetype)paletteForImage:(CGImageRef)image clusters:(int)k;
+ (nullable instancetype)paletteFromPlist:(NSDictionary *)plist;
- (NSDictionary *)plist;
@end

void AURGBToHSV(AURGB c, float *h, float *s, float *v);
AURGB AUHSVToRGB(float h, float s, float v);
AURGB AURGBMix(AURGB a, AURGB b, float t);

NS_ASSUME_NONNULL_END
