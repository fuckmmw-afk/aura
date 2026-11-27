#import "AUSceneRenderer.h"
#import <UIKit/UIKit.h>
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import "Core/AUTune.h"
#import "Features/AUScene3D.h"
#import <Metal/Metal.h>

// The same arithmetic as AUScene3D's project(), per vertex.
static NSString *const kShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Cam { float2 angles; float2 range; float2 rangeY; float pivot; float scale; float focal; float relief; float median;\n\
             float kind; float zFar; float zNear; float zoom; float reliefBack; float reliefFront; float texTall; float plateTall;\n\
             float frameTall; float texTop; float plateTop; float frameTop; };\n\
struct VOut { float4 position [[position]]; float2 uv; };\n\
vertex VOut au_mesh(uint vid [[vertex_id]], const device float2 *grid [[buffer(1)]], constant Cam &c [[buffer(0)]],\n\
                    texture2d<float> depth [[texture(0)]]) {\n\
    constexpr sampler sd(address::mirrored_repeat, filter::linear);\n\
    float2 g = grid[vid];\n\
    float2 uv = float2(mix(c.range.x, c.range.y, g.x), mix(c.rangeY.x, c.rangeY.y, g.y));\n\
    float d = depth.sample(sd, c.kind < 0.5 ? float2(uv.x, (uv.y + c.plateTop) / c.plateTall) : uv, level(0)).r;\n\
    float z = c.kind < 0.5 ? (d - c.pivot) * c.scale\n\
        : (c.median - c.pivot) * c.scale + clamp(d - c.median, -c.reliefBack, c.reliefFront) * c.relief * c.scale;\n\
    z = clamp(z, -c.zFar, c.zNear);\n\
    float2 q = uv - 0.5;\n\
    float k = (c.focal - z) / c.focal;\n\
    float x = q.x * k, y = q.y * k;\n\
    float ca = cos(c.angles.x), sa = sin(c.angles.x), cb = cos(c.angles.y), sb = sin(c.angles.y);\n\
    float x1 = x * ca + z * sa, z1 = -x * sa + z * ca;\n\
    float y2 = y * cb + z1 * sb, z2 = -y * sb + z1 * cb;\n\
    float w = c.focal / (c.focal - z2);\n\
    VOut o;\n\
    o.position = float4(x1 * w * 2 * c.zoom, 1 - 2 * (y2 * w * c.zoom + 0.5 + c.frameTop) / c.frameTall, 0.5, 1);\n\
    o.uv = c.kind < 0.5 ? float2(uv.x, (uv.y + c.texTop) / c.texTall) : uv;\n\
    return o;\n\
}\n\
fragment half4 au_back(VOut in [[stage_in]], texture2d<half> color [[texture(0)]]) {\n\
    constexpr sampler s(address::mirrored_repeat, filter::linear);\n\
    return half4(color.sample(s, in.uv).rgb, 1);\n\
}\n\
fragment half4 au_object(VOut in [[stage_in]], texture2d<half> color [[texture(0)]]) {\n\
    constexpr sampler s(address::clamp_to_zero, filter::linear);\n\
    return color.sample(s, in.uv);\n\
}\n\
struct Sheet { float2 angles; float pivot; float scale; float focal; float zFar; float zNear; float zoom; float texTall;\n\
               float frameTall; float tear; float span; float texTop; float frameTop; };\n\
struct SOut { float4 position [[position]]; float2 uv; float nearCut [[flat]]; };\n\
// The solid surface: a triangle whose corners sit on both sides of a depth jump is laid wholly at the near side\'s\n\
// depth, and its fragments of the far side are thrown away: the near edge stays sharp, a gap opens behind it.\n\
vertex SOut au_sheet(uint vid [[vertex_id]], const device float2 *grid [[buffer(1)]], constant Sheet &c [[buffer(0)]],\n\
                     texture2d<float> depth [[texture(0)]]) {\n\
    constexpr sampler sn(address::clamp_to_edge, filter::nearest);\n\
    uint first = vid - vid % 3;\n\
    // Picture units: the cover\'s top-left is (0, 0); the drawn span starts frameTop above it, the texture texTop.\n\
    float2 g = grid[vid] * float2(1, c.span) - float2(0, c.frameTop);\n\
    float2 tex = float2(1, 1 / c.texTall);\n\
    float2 shift = float2(0, c.texTop - c.frameTop);\n\
    float d0 = depth.sample(sn, (grid[first] * float2(1, c.span) + shift) * tex, level(0)).r;\n\
    float d1 = depth.sample(sn, (grid[first + 1] * float2(1, c.span) + shift) * tex, level(0)).r;\n\
    float d2 = depth.sample(sn, (grid[first + 2] * float2(1, c.span) + shift) * tex, level(0)).r;\n\
    float hi = max(d0, max(d1, d2)), lo = min(d0, min(d1, d2));\n\
    float d = depth.sample(sn, float2(g.x, g.y + c.texTop) * tex, level(0)).r;\n\
    bool torn = hi - lo > c.tear;\n\
    if (torn) d = hi;\n\
    float z = clamp((d - c.pivot) * c.scale, -c.zFar, c.zNear);\n\
    float2 q = g - 0.5;\n\
    float k = (c.focal - z) / c.focal;\n\
    float x = q.x * k, y = q.y * k;\n\
    float ca = cos(c.angles.x), sa = sin(c.angles.x), cb = cos(c.angles.y), sb = sin(c.angles.y);\n\
    float x1 = x * ca + z * sa, z1 = -x * sa + z * ca;\n\
    float y2 = y * cb + z1 * sb, z2 = -y * sb + z1 * cb;\n\
    float w = c.focal / (c.focal - z2);\n\
    SOut o;\n\
    o.position = float4(x1 * w * 2 * c.zoom, 1 - 2 * (y2 * w * c.zoom + 0.5 + c.frameTop) / c.frameTall, clamp(0.5 - z2 * 0.25, 0.01, 0.99), 1);\n\
    o.uv = float2(g.x, g.y + c.texTop) * tex;\n\
    o.nearCut = torn ? hi - c.tear * 0.5 : -1;\n\
    return o;\n\
}\n\
fragment half4 au_sheet_color(SOut in [[stage_in]], texture2d<half> color [[texture(0)]], texture2d<float> depth [[texture(1)]]) {\n\
    constexpr sampler s(address::clamp_to_edge, filter::linear);\n\
    constexpr sampler sn(address::clamp_to_edge, filter::nearest);\n\
    if (in.nearCut >= 0 && depth.sample(sn, in.uv).r < in.nearCut) discard_fragment();\n\
    return half4(color.sample(s, in.uv).rgb, 1);\n\
}\n\
struct Blur { float4 ramp1; float4 ramp2; float2 size; };\n\
struct BOut { float4 position [[position]]; float2 uv; };\n\
vertex BOut au_full(uint vid [[vertex_id]]) {\n\
    float2 p = float2((vid << 1) & 2, vid & 2);\n\
    BOut o;\n\
    o.position = float4(p * 2 - 1, 0, 1);\n\
    o.uv = float2(p.x, 1 - p.y);\n\
    return o;\n\
}\n\
// The finished frame, blurred more the further down it is (the player\'s Fill): the blur is of what was drawn, so\n\
// the sharp and the soft part are one picture and can never slide apart.\n\
fragment half4 au_blur(BOut in [[stage_in]], texture2d<half> scene [[texture(0)]], constant Blur &b [[buffer(0)]]) {\n\
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);\n\
    float t1 = smoothstep(b.ramp1.x, b.ramp1.y, in.uv.y) * b.ramp1.z;\n\
    float t2 = smoothstep(b.ramp2.x, b.ramp2.y, in.uv.y) * b.ramp2.z;\n\
    float r = max(t1, t2) * b.size.x;\n\
    if (r < 0.6) return half4(scene.sample(s, in.uv, level(0)).rgb, 1);\n\
    float lod = max(0.0, log2(r * 0.5));\n\
    float2 px = r / b.size;\n\
    const float2 taps[12] = {float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),\n\
                             float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),\n\
                             float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)};\n\
    half3 sum = scene.sample(s, in.uv, level(lod)).rgb;\n\
    for (int i = 0; i < 12; i++) sum += scene.sample(s, in.uv + taps[i] * px, level(lod)).rgb;\n\
    return half4(sum / 13, 1);\n\
}\n";

typedef struct {
    float angles[2], range[2], rangeY[2];
    float pivot, scale, focal, relief, median, kind, zFar, zNear, zoom, reliefBack, reliefFront, texTall, plateTall, frameTall;
    float texTop, plateTop, frameTop;
    float pad;                  // the shader's struct is 8-aligned: 96 bytes
} AUCam;

typedef struct {
    float angles[2];
    float pivot, scale, focal, zFar, zNear, zoom, texTall, frameTall, tear, span, texTop, frameTop;
} AUSheet;

typedef struct {
    float ramp1[4], ramp2[4];
    float size[2];
    float pad[2];               // the shader's struct is 16-aligned: 48 bytes
} AUBlurParams;

enum { kGrid = 96 };

@implementation AUSceneRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLBuffer> _grid, _indices;
    NSUInteger _indexCount;
    id<MTLTexture> _background, _plate, _raw;
    NSArray<id<MTLTexture>> *_objects;
    NSArray<NSNumber *> *_medians, *_reliefs;
    AUScene *_scene;
    double _texTall;
    double _texTop, _frameTop;  // the room above the cover in the background texture and in the drawn frame
    id<MTLTexture> _front, _frontDepth;
    double _frontTall;          // the front picture's height over its width
    double _sheetSpan;          // how much of it is drawn: 1 (the cover) or all of it (Fill)
    id<MTLBuffer> _sheet;
    NSUInteger _sheetVertices, _sheetColumns;
    double _sheetBuiltSpan;
    id<MTLTexture> _depthTarget, _sceneTarget;
    BOOL _blurs;
    AUBlurParams _blur;
}

+ (id<MTLDevice>)device {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

+ (id<MTLDepthStencilState>)depthState:(BOOL)writes {
    static id<MTLDepthStencilState> states[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int w = 0; w < 2; w++) {
            MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
            d.depthCompareFunction = w ? MTLCompareFunctionLess : MTLCompareFunctionAlways;
            d.depthWriteEnabled = w ? YES : NO;
            states[w] = [[self device] newDepthStencilStateWithDescriptor:d];
        }
    });
    return states[writes ? 1 : 0];
}

+ (BOOL)supported {
    return [self device] != nil;
}

+ (NSArray<id<MTLRenderPipelineState>> *)pipelines {
    static NSArray *pipelines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        double started = AUNowMs();
        NSError *error = nil;
        id<MTLLibrary> library = [[self device] newLibraryWithSource:kShader options:nil error:&error];
        if (!library) {
            AULog(@"scene shader: %@", error.localizedDescription);
            return;
        }
        NSMutableArray *made = [NSMutableArray array];
        // 0 the background, 1 an object, 2 the solid surface (all into a pass with a depth buffer), 3 the blur.
        for (int object = 0; object < 4; object++) {
            MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
            NSString *vertex = object == 2 ? @"au_sheet" : object == 3 ? @"au_full" : @"au_mesh";
            NSString *fragment = object == 0 ? @"au_back" : object == 1 ? @"au_object" : object == 2 ? @"au_sheet_color" : @"au_blur";
            descriptor.vertexFunction = [library newFunctionWithName:vertex];
            descriptor.fragmentFunction = [library newFunctionWithName:fragment];
            if (object < 3) descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
            color.pixelFormat = MTLPixelFormatBGRA8Unorm;
            if (object == 1) {
                color.blendingEnabled = YES;
                color.sourceRGBBlendFactor = color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                color.destinationRGBBlendFactor = color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }
            id<MTLRenderPipelineState> pipeline = [[self device] newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (!pipeline) {
                AULog(@"scene pipeline: %@", error.localizedDescription);
                return;
            }
            [made addObject:pipeline];
        }
        pipelines = made;
        AULog(@"scene shader compiled in %.0f ms", AUNowMs() - started);
    });
    return pipelines;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    id<MTLDevice> device = [AUSceneRenderer device];
    _queue = [device newCommandQueue];
    _layer = [CAMetalLayer layer];
    _layer.device = device;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    _layer.opaque = YES;
    _layer.maximumDrawableCount = 3;
    _layer.contentsGravity = kCAGravityResize;
    _layer.hidden = YES;
    _layer.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null, @"contents": NSNull.null,
                       @"opacity": NSNull.null, @"transform": NSNull.null, @"hidden": NSNull.null};
    _strength = 1;
    _zoom = 1;
    _withObjects = YES;
    _texTall = 1;
    // The mesh: kGrid x kGrid points over 0...1, two triangles a cell.
    NSMutableData *grid = [NSMutableData dataWithLength:kGrid * kGrid * sizeof(float) * 2];
    float *g = grid.mutableBytes;
    for (int y = 0; y < kGrid; y++) {
        for (int x = 0; x < kGrid; x++) {
            g[(y * kGrid + x) * 2] = x / (float)(kGrid - 1);
            g[(y * kGrid + x) * 2 + 1] = y / (float)(kGrid - 1);
        }
    }
    NSMutableData *indices = [NSMutableData data];
    for (int y = 0; y + 1 < kGrid; y++) {
        for (int x = 0; x + 1 < kGrid; x++) {
            uint16_t a = (uint16_t)(y * kGrid + x), b = a + 1, c = a + kGrid, d = c + 1;
            uint16_t six[6] = {a, b, c, b, d, c};
            [indices appendBytes:six length:sizeof(six)];
        }
    }
    _indexCount = indices.length / sizeof(uint16_t);
    _grid = [device newBufferWithBytes:grid.bytes length:grid.length options:MTLResourceStorageModeShared];
    _indices = [device newBufferWithBytes:indices.bytes length:indices.length options:MTLResourceStorageModeShared];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [AUSceneRenderer pipelines]; });
    return self;
}

- (void)setPresentsWithTransaction:(BOOL)presents {
    _presentsWithTransaction = presents;
    _layer.presentsWithTransaction = presents;
}

static id<MTLTexture> colorTexture(CGImageRef image, BOOL premultiplied) {
    if (!image) return nil;
    CGImageRef normal = AUImageNormalized(image, 2048);
    if (!normal) return nil;
    size_t width = CGImageGetWidth(normal), height = CGImageGetHeight(normal);
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4, space,
                                                 (premultiplied ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast) | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), normal);
    CGContextRelease(context);
    CGImageRelease(normal);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [[AUSceneRenderer device] newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:width * 4];
    return texture;
}

static id<MTLTexture> grayTexture(NSData *bytes, size_t side) {
    if (!bytes || side < 2) return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                          width:side height:side mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [[AUSceneRenderer device] newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:side];
    return texture;
}

static id<MTLTexture> grayRectTexture(NSData *bytes, size_t width, size_t height) {
    if (!bytes || width < 2 || height < 2 || bytes.length < width * height) return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                          width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [[AUSceneRenderer device] newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:width];
    return texture;
}

// The solid surface's mesh: `columns` cells across the cover, as many down `span` (its height over its width), every
// triangle its own three corners (the shader looks at all three to see whether it straddles a jump).
- (void)buildSheetColumns:(NSUInteger)columns span:(double)span {
    if (_sheet && _sheetColumns == columns && fabs(_sheetBuiltSpan - span) < 1e-6) return;
    NSUInteger rows = MAX((NSUInteger)1, (NSUInteger)lround(columns * span));
    NSMutableData *data = [NSMutableData dataWithLength:columns * rows * 6 * sizeof(float) * 2];
    float *v = data.mutableBytes;
    // y in units of the drawn span (0...1); the shader scales it back by the span.
    for (NSUInteger y = 0; y < rows; y++) {
        for (NSUInteger x = 0; x < columns; x++) {
            float x0 = x / (float)columns, x1 = (x + 1) / (float)columns, y0 = y / (float)rows, y1 = (y + 1) / (float)rows;
            float six[12] = {x0, y0, x1, y0, x0, y1, x1, y0, x1, y1, x0, y1};
            memcpy(v, six, sizeof(six));
            v += 12;
        }
    }
    _sheet = [[AUSceneRenderer device] newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared];
    _sheetVertices = columns * rows * 6;
    _sheetColumns = columns;
    _sheetBuiltSpan = span;
}

- (void)setBlurRamp1:(CGPoint)ramp1 size1:(double)size1 ramp2:(CGPoint)ramp2 size2:(double)size2 {
    _blurs = size1 > 0.0005 || size2 > 0.0005;
    _blur.ramp1[0] = (float)ramp1.x; _blur.ramp1[1] = (float)MAX(ramp1.x + 0.001, ramp1.y); _blur.ramp1[2] = (float)size1;
    _blur.ramp2[0] = (float)ramp2.x; _blur.ramp2[1] = (float)MAX(ramp2.x + 0.001, ramp2.y); _blur.ramp2[2] = (float)size2;
}

- (void)clearBlur {
    _blurs = NO;
}

- (void)setScene:(AUScene *)scene tall:(BOOL)tall {
    // Until it is drawn again, the last cover must not show over the new one.
    _layer.hidden = YES;
    _scene = scene;
    UIImage *picture = tall && scene.tall ? scene.tall : scene.background;
    _texTall = tall && scene.tall ? scene.tallness : 1;
    _texTop = _frameTop = tall && scene.tall ? scene.tallTop : 0;
    _background = colorTexture(picture.CGImage, NO);
    uint8_t flat = (uint8_t)lround(MAX(0.0, MIN(1.0, scene.backgroundDepth)) * 255);
    NSData *flatBytes = [NSData dataWithBytes:(uint8_t[4]){flat, flat, flat, flat} length:4];
    _plate = grayTexture(scene.plateBytes, scene.plateSide) ?: grayTexture(flatBytes, 2);
    _raw = grayTexture(scene.rawBytes, scene.rawSide) ?: _plate;
    NSMutableArray *objects = [NSMutableArray array], *medians = [NSMutableArray array], *reliefs = [NSMutableArray array];
    for (AUSceneLayer *layer in scene.layers) {
        id<MTLTexture> texture = colorTexture(layer.image.CGImage, YES);
        if (!texture) continue;
        [objects addObject:texture];
        [medians addObject:@(layer.depth)];
        [reliefs addObject:@(layer.relief)];
    }
    _objects = objects;
    _medians = medians;
    _reliefs = reliefs;
    _front = _frontDepth = nil;
    if (scene.solid) {
        _front = colorTexture(scene.front.CGImage, NO);
        _frontDepth = grayRectTexture(scene.frontBytes, scene.frontSide, scene.frontHigh);
        CGImageRef f = scene.front.CGImage;
        _frontTall = f ? CGImageGetHeight(f) / (double)MAX((size_t)1, CGImageGetWidth(f)) : 1;
        // The cover view draws the square only; Fill the whole picture with its room below.
        _sheetSpan = tall && scene.tall ? _frontTall : 1;
        if (!_front || !_frontDepth) _front = _frontDepth = nil;
    }
}

- (void)layoutForScale:(CGFloat)scale {
    CGSize size = _layer.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    // Two pixels a point at most: the picture is a cover enlarged, three would only cost heat.
    CGFloat pixels = MIN(MIN(scale, AUTune(@"appScale")), 2048 / MAX(size.width, size.height));
    _layer.contentsScale = pixels;
    CGSize drawable = CGSizeMake(round(size.width * pixels), round(size.height * pixels));
    if (!CGSizeEqualToSize(_layer.drawableSize, drawable)) _layer.drawableSize = drawable;
}

- (id<MTLTexture>)depthTargetFor:(id<MTLTexture>)target {
    if (!_depthTarget || _depthTarget.width != target.width || _depthTarget.height != target.height) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                     width:target.width height:target.height mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModePrivate;
        _depthTarget = [[AUSceneRenderer device] newTextureWithDescriptor:d];
    }
    return _depthTarget;
}

- (id<MTLTexture>)sceneTargetWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!_sceneTarget || _sceneTarget.width != width || _sceneTarget.height != height) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:width height:height mipmapped:YES];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        _sceneTarget = [[AUSceneRenderer device] newTextureWithDescriptor:d];
    }
    return _sceneTarget;
}

// The scene into `target`; with the Fill's blur, into a mipmapped copy first and then blurred down into `target`.
- (void)encodeInto:(id<MTLTexture>)target buffer:(id<MTLCommandBuffer>)buffer zoom:(float)zoom {
    if (!_blurs) {
        [self encodeSceneInto:target buffer:buffer zoom:zoom];
        return;
    }
    id<MTLTexture> scene = [self sceneTargetWidth:target.width height:target.height];
    [self encodeSceneInto:scene buffer:buffer zoom:zoom];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit generateMipmapsForTexture:scene];
    [blit endEncoding];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:[AUSceneRenderer pipelines][3]];
    AUBlurParams blur = _blur;
    blur.size[0] = (float)target.width;
    blur.size[1] = (float)target.height;
    [encoder setFragmentBytes:&blur length:sizeof(blur) atIndex:0];
    [encoder setFragmentTexture:scene atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

- (void)encodeSceneInto:(id<MTLTexture>)target buffer:(id<MTLCommandBuffer>)buffer zoom:(float)zoom {
    NSArray<id<MTLRenderPipelineState>> *pipelines = [AUSceneRenderer pipelines];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = [self depthTargetFor:target];
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    AUCamera camera = AUSceneCamera(_scene, _tilt, _strength);
    float texTall = (float)_texTall, plateTall = (float)MAX(1.0, _scene.plateHigh / (double)MAX((size_t)1, _scene.plateSide));
    // Picture units from the cover's top: the drawn frame runs from -frameTop to texTall - frameTop.
    float frameTop = (float)_frameTop, plateTop = (float)_scene.tallTop;
    AUCam cam = {{(float)camera.angleX, (float)camera.angleY}, {-0.12f, 1.12f}, {-frameTop - 0.12f, texTall - frameTop + 0.12f},
                 (float)camera.pivot, (float)camera.scale, (float)camera.focal, (float)camera.relief, 0, 0, (float)camera.zFar,
                 (float)camera.zNear, zoom, (float)camera.reliefBack, (float)camera.reliefFront, texTall, plateTall, texTall,
                 (float)_texTop, plateTop, frameTop, 0};
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setDepthStencilState:[AUSceneRenderer depthState:NO]];
    [encoder setVertexBuffer:_grid offset:0 atIndex:1];
    [encoder setRenderPipelineState:pipelines[0]];
    [encoder setVertexBytes:&cam length:sizeof(cam) atIndex:0];
    [encoder setVertexTexture:_plate atIndex:0];
    [encoder setFragmentTexture:_background atIndex:0];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_indexCount indexType:MTLIndexTypeUInt16 indexBuffer:_indices indexBufferOffset:0];
    if (_withObjects && _objects.count) {
        [encoder setRenderPipelineState:pipelines[1]];
        [encoder setVertexTexture:_raw atIndex:0];
        cam.range[0] = cam.rangeY[0] = 0;
        cam.range[1] = cam.rangeY[1] = 1;
        cam.kind = 1;
        for (NSUInteger i = 0; i < _objects.count; i++) {
            cam.median = _medians[i].floatValue;
            cam.relief = (float)(camera.relief * _reliefs[i].doubleValue / MAX(1.0, camera.scale));
            [encoder setVertexBytes:&cam length:sizeof(cam) atIndex:0];
            [encoder setFragmentTexture:_objects[i] atIndex:0];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_indexCount indexType:MTLIndexTypeUInt16 indexBuffer:_indices indexBufferOffset:0];
        }
    }
    if (_front && _frontDepth) {
        // The cover itself over the painted background, as one surface torn at its depth jumps.
        [self buildSheetColumns:(NSUInteger)lround(AUTune(@"surfaceGrid")) span:_sheetSpan];
        AUSheet sheet = {{(float)camera.angleX, (float)camera.angleY}, (float)camera.pivot, (float)camera.scale, (float)camera.focal,
                         (float)camera.zFar, (float)camera.zNear, zoom, (float)_frontTall, (float)_texTall,
                         (float)_scene.tearJump, (float)_sheetSpan, (float)_scene.tallTop, (float)_frameTop};
        [encoder setRenderPipelineState:pipelines[2]];
        [encoder setDepthStencilState:[AUSceneRenderer depthState:YES]];
        [encoder setVertexBuffer:_sheet offset:0 atIndex:1];
        [encoder setVertexBytes:&sheet length:sizeof(sheet) atIndex:0];
        [encoder setVertexTexture:_frontDepth atIndex:0];
        [encoder setFragmentTexture:_front atIndex:0];
        [encoder setFragmentTexture:_frontDepth atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_sheetVertices];
    }
    [encoder endEncoding];
}

- (double)frameTall {
    return _texTall;
}

- (double)frameTop {
    return _frameTop;
}

- (BOOL)ready {
    return [AUSceneRenderer pipelines].count == 4 && _background && _plate;
}

- (void)render {
    if (![self ready] || _layer.drawableSize.width < 1) return;
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) return;
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    [self encodeInto:drawable.texture buffer:buffer zoom:1];
    if (_presentsWithTransaction) {
        [buffer commit];
        [buffer waitUntilScheduled];
        [drawable present];
    } else {
        [buffer presentDrawable:drawable];
        [buffer commit];
    }
    _layer.hidden = NO;
    AUCountFrame();
}

- (CGImageRef)renderImageWidth:(size_t)width height:(size_t)height {
    if (![self ready]) return NULL;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [[AUSceneRenderer device] newTextureWithDescriptor:descriptor];
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    [self encodeInto:target buffer:buffer zoom:(float)_zoom];
    [buffer commit];
    [buffer waitUntilCompleted];
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    [target getBytes:bytes.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

@end
