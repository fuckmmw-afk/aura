#import "AUPalette.h"
#import <Accelerate/Accelerate.h>

static const int kSide = 48;     // the cover read at 48 x 48: 2304 points
static const int kIterations = 12;

void AURGBToHSV(AURGB c, float *h, float *s, float *v) {
    float maxv = fmaxf(c.r, fmaxf(c.g, c.b)), minv = fminf(c.r, fminf(c.g, c.b)), d = maxv - minv;
    *v = maxv;
    *s = maxv > 0 ? d / maxv : 0;
    if (d <= 1e-6f) {
        *h = 0;
        return;
    }
    float hue;
    if (maxv == c.r) hue = fmodf((c.g - c.b) / d, 6);
    else if (maxv == c.g) hue = (c.b - c.r) / d + 2;
    else hue = (c.r - c.g) / d + 4;
    hue /= 6;
    *h = hue < 0 ? hue + 1 : hue;
}

AURGB AUHSVToRGB(float h, float s, float v) {
    float hh = fmodf(h, 1) * 6, c = v * s, x = c * (1 - fabsf(fmodf(hh, 2) - 1)), m = v - c;
    float r = 0, g = 0, b = 0;
    if (hh < 1) { r = c; g = x; }
    else if (hh < 2) { r = x; g = c; }
    else if (hh < 3) { g = c; b = x; }
    else if (hh < 4) { g = x; b = c; }
    else if (hh < 5) { r = x; b = c; }
    else { r = c; b = x; }
    return (AURGB){r + m, g + m, b + m};
}

AURGB AURGBMix(AURGB a, AURGB b, float t) {
    return (AURGB){a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t};
}

static float luminance(AURGB c) {
    return 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;
}

static NSValue *boxed(AURGB c) {
    return [NSValue valueWithBytes:&c objCType:@encode(AURGB)];
}

static AURGB unboxed(NSValue *value) {
    AURGB c = {0, 0, 0};
    [value getValue:&c size:sizeof(c)];
    return c;
}

@implementation AUPalette {
    NSArray<NSValue *> *_colors;
    NSArray<NSNumber *> *_weights;
}

- (instancetype)initWithColors:(NSArray<NSValue *> *)colors weights:(NSArray<NSNumber *> *)weights {
    if (!(self = [super init])) return nil;
    _colors = colors;
    _weights = weights;
    _dominant = unboxed(colors.firstObject);
    float bestScore = -1, darkest = 2;
    _accent = _dominant;
    _dark = _dominant;
    _gray = YES;
    for (NSUInteger i = 0; i < colors.count; i++) {
        AURGB c = unboxed(colors[i]);
        float w = weights[i].floatValue, h, s, v;
        AURGBToHSV(c, &h, &s, &v);
        if (s > 0.18f && v > 0.18f) _gray = NO;
        // Colorful, not too dark, and enough of the cover that it reads as the cover's: a 3% fleck is not the theme.
        float score = w < 0.03f ? -1 : s * sqrtf(fminf(v, 0.85f)) * sqrtf(w + 0.05f);
        if (score > bestScore) {
            bestScore = score;
            _accent = c;
        }
        float l = luminance(c);
        if (l < darkest) {
            darkest = l;
            _dark = c;
        }
    }
    return self;
}

- (NSArray<NSValue *> *)colors { return _colors; }
- (NSArray<NSNumber *> *)weights { return _weights; }

+ (instancetype)paletteForImage:(CGImageRef)image clusters:(int)k {
    if (!image || k < 1) return nil;
    const int n = kSide * kSide;
    uint8_t *pixels = calloc(n * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) {
        free(pixels);
        return nil;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextRelease(context);

    float *channel[3], *distance = malloc(n * sizeof(float)), *best = malloc(n * sizeof(float)), *scratch = malloc(n * sizeof(float));
    int *label = calloc(n, sizeof(int));
    for (int c = 0; c < 3; c++) {
        channel[c] = malloc(n * sizeof(float));
        vDSP_vfltu8(pixels + c, 4, channel[c], 1, n);
        float scale = 1.0f / 255.0f;
        vDSP_vsmul(channel[c], 1, &scale, channel[c], 1, n);
    }
    free(pixels);

    // Seeds: the mean, then each next the point farthest from every seed so far (deterministic k-means++).
    float centers[16][3];
    k = MIN(k, 16);
    for (int c = 0; c < 3; c++) vDSP_meanv(channel[c], 1, &centers[0][c], n);
    float big = INFINITY;
    vDSP_vfill(&big, best, 1, n);
    for (int seed = 1; seed < k; seed++) {
        for (int c = 0; c < 3; c++) {
            float negative = -centers[seed - 1][c];
            vDSP_vsadd(channel[c], 1, &negative, scratch, 1, n);
            if (c == 0) vDSP_vsq(scratch, 1, distance, 1, n);
            else vDSP_vma(scratch, 1, scratch, 1, distance, 1, distance, 1, n);
        }
        vDSP_vmin(distance, 1, best, 1, best, 1, n);
        float farthest;
        vDSP_Length at;
        vDSP_maxvi(best, 1, &farthest, &at, n);
        for (int c = 0; c < 3; c++) centers[seed][c] = channel[c][at];
    }

    int counts[16];
    for (int iteration = 0; iteration < kIterations; iteration++) {
        vDSP_vfill(&big, best, 1, n);
        for (int j = 0; j < k; j++) {
            for (int c = 0; c < 3; c++) {
                float negative = -centers[j][c];
                vDSP_vsadd(channel[c], 1, &negative, scratch, 1, n);
                if (c == 0) vDSP_vsq(scratch, 1, distance, 1, n);
                else vDSP_vma(scratch, 1, scratch, 1, distance, 1, distance, 1, n);
            }
            for (int i = 0; i < n; i++) {
                if (distance[i] < best[i]) {
                    best[i] = distance[i];
                    label[i] = j;
                }
            }
        }
        double sums[16][3] = {{0}};
        memset(counts, 0, sizeof(counts));
        for (int i = 0; i < n; i++) {
            int j = label[i];
            counts[j]++;
            sums[j][0] += channel[0][i];
            sums[j][1] += channel[1][i];
            sums[j][2] += channel[2][i];
        }
        BOOL moved = NO;
        for (int j = 0; j < k; j++) {
            if (!counts[j]) continue;
            for (int c = 0; c < 3; c++) {
                float value = (float)(sums[j][c] / counts[j]);
                if (fabsf(value - centers[j][c]) > 1e-4f) moved = YES;
                centers[j][c] = value;
            }
        }
        if (!moved) break;
    }
    for (int c = 0; c < 3; c++) free(channel[c]);
    free(distance);
    free(best);
    free(scratch);
    free(label);

    int order[16];
    for (int j = 0; j < k; j++) order[j] = j;
    for (int a = 0; a < k; a++) {
        for (int b = a + 1; b < k; b++) {
            if (counts[order[b]] > counts[order[a]]) {
                int t = order[a];
                order[a] = order[b];
                order[b] = t;
            }
        }
    }
    NSMutableArray *colors = [NSMutableArray array], *weights = [NSMutableArray array];
    for (int a = 0; a < k; a++) {
        int j = order[a];
        if (!counts[j]) continue;
        [colors addObject:boxed((AURGB){centers[j][0], centers[j][1], centers[j][2]})];
        [weights addObject:@((double)counts[j] / n)];
    }
    return colors.count ? [[AUPalette alloc] initWithColors:colors weights:weights] : nil;
}

- (NSDictionary *)plist {
    NSMutableArray *colors = [NSMutableArray array];
    for (NSValue *value in _colors) {
        AURGB c = unboxed(value);
        [colors addObject:@[@(c.r), @(c.g), @(c.b)]];
    }
    return @{@"colors": colors, @"weights": _weights};
}

+ (instancetype)paletteFromPlist:(NSDictionary *)plist {
    NSArray *colors = [plist[@"colors"] isKindOfClass:NSArray.class] ? plist[@"colors"] : nil;
    NSArray *weights = [plist[@"weights"] isKindOfClass:NSArray.class] ? plist[@"weights"] : nil;
    if (!colors.count || colors.count != weights.count) return nil;
    NSMutableArray *boxedColors = [NSMutableArray array];
    for (NSArray *c in colors) {
        if (![c isKindOfClass:NSArray.class] || c.count != 3) return nil;
        [boxedColors addObject:boxed((AURGB){[c[0] floatValue], [c[1] floatValue], [c[2] floatValue]})];
    }
    return [[AUPalette alloc] initWithColors:boxedColors weights:weights];
}

@end
