// Bitmaps the way the features want them: sRGB RGBA8, premultiplied, at most a given side.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A copy drawn into sRGB RGBA8 at most maxSide on its longer side (never enlarged). Caller releases.
CGImageRef _Nullable AUImageNormalized(CGImageRef image, size_t maxSide) CF_RETURNS_RETAINED;
// A copy drawn at exactly width x height. Caller releases.
CGImageRef _Nullable AUImageResized(CGImageRef image, size_t width, size_t height) CF_RETURNS_RETAINED;
// An 8-bit gray image over the bytes (copied). Caller releases.
CGImageRef _Nullable AUGrayImage(const uint8_t *bytes, size_t width, size_t height) CF_RETURNS_RETAINED;
// The gray image's bytes at its own size, row after row with no padding.
NSData *_Nullable AUGrayBytes(CGImageRef image);
NSData *_Nullable AUPNGData(CGImageRef image);
NSData *_Nullable AUJPEGData(CGImageRef image, double quality);
CGImageRef _Nullable AUImageFromData(NSData *data) CF_RETURNS_RETAINED;

// Tiles over a width x height picture, `tile` square, overlapping by at least `overlap`, the last flush with the
// edge. Each value is a CGRect (in pixels) of where the tile reads; a picture smaller than a tile is one tile.
NSArray<NSValue *> *AUTiles(size_t width, size_t height, size_t tile, size_t overlap);

NS_ASSUME_NONNULL_END
