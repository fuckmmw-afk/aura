#import "AUSceneRenderer.h"
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import "Features/AUScene3D.h"
#import <Metal/Metal.h>

// The same arithmetic as AUScene3D's project(), per vertex.
static NSString *const kShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Cam { float2 angles; float2 range; float pivot; float scale; float focal; float relief; float median; float kind;\n\
             float zFar; float zNear; float zoom; float reliefBack; float reliefFront; float pad; };\n\
struct VOut { float4 position [[position]]; float2 uv; };\n\
vertex VOut au_mesh(uint vid [[vertex_id]], const device float2 *grid [[buffer(1)]], constant Cam &c [[buffer(0)]],\n\
                    texture2d<float> depth [[texture(0)]]) {\n\
    constexpr sampler sd(address::mirrored_repeat, filter::linear);\n\
    float2 uv = mix(float2(c.range.x), float2(c.range.y), grid[vid]);\n\
    float d = depth.sample(sd, uv, level(0)).r;\n\
    float z = c.kind < 0.5 ? (d - c.pivot) * c.scale\n\
        : (c.median + clamp(d - c.median, -c.reliefBack, c.reliefFront) * c.relief - c.pivot) * c.scale;\n\
    z = clamp(z, -c.zFar, c.zNear);\n\
    float2 q = uv - 0.5;\n\
    float k = (c.focal - z) / c.focal;\n\
    float x = q.x * k, y = q.y * k;\n\
    float ca = cos(c.angles.x), sa = sin(c.angles.x), cb = cos(c.angles.y), sb = sin(c.angles.y);\n\
    float x1 = x * ca + z * sa, z1 = -x * sa + z * ca;\n\
    float y2 = y * cb + z1 * sb, z2 = -y * sb + z1 * cb;\n\
    float w = c.focal / (c.focal - z2);\n\
    VOut o;\n\
    o.position = float4(x1 * w * 2 * c.zoom, -y2 * w * 2 * c.zoom, 0.5, 1);\n\
    o.uv = uv;\n\
    return o;\n\
}\n\
fragment half4 au_back(VOut in [[stage_in]], texture2d<half> color [[texture(0)]]) {\n\
    constexpr sampler s(address::mirrored_repeat, filter::linear);\n\
    return half4(color.sample(s, in.uv).rgb, 1);\n\
}\n\
fragment half4 au_object(VOut in [[stage_in]], texture2d<half> color [[texture(0)]]) {\n\
    constexpr sampler s(address::clamp_to_zero, filter::linear);\n\
    return color.sample(s, in.uv);\n\
}\n";

typedef struct {
    float angles[2], range[2];
    float pivot, scale, focal, relief, median, kind, zFar, zNear, zoom, reliefBack, reliefFront, pad;
} AUCam;

enum { kGrid = 96 };

@implementation AUSceneRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLBuffer> _grid, _indices;
    NSUInteger _indexCount;
    id<MTLTexture> _background, _plate, _raw;
    NSArray<id<MTLTexture>> *_objects;
    NSArray<NSNumber *> *_medians;
    AUScene *_scene;
}

+ (id<MTLDevice>)device {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
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
        for (int object = 0; object < 2; object++) {
            MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = [library newFunctionWithName:@"au_mesh"];
            descriptor.fragmentFunction = [library newFunctionWithName:object ? @"au_object" : @"au_back"];
            MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
            color.pixelFormat = MTLPixelFormatBGRA8Unorm;
            if (object) {
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

- (void)setScene:(AUScene *)scene {
    // Until it is drawn again, the last cover must not show over the new one.
    _layer.hidden = YES;
    _scene = scene;
    _background = colorTexture(scene.background.CGImage, NO);
    uint8_t flat = (uint8_t)lround(MAX(0.0, MIN(1.0, scene.backgroundDepth)) * 255);
    NSData *flatBytes = [NSData dataWithBytes:(uint8_t[4]){flat, flat, flat, flat} length:4];
    _plate = grayTexture(scene.plateBytes, scene.plateSide) ?: grayTexture(flatBytes, 2);
    _raw = grayTexture(scene.rawBytes, scene.rawSide) ?: _plate;
    NSMutableArray *objects = [NSMutableArray array], *medians = [NSMutableArray array];
    for (AUSceneLayer *layer in scene.layers) {
        id<MTLTexture> texture = colorTexture(layer.image.CGImage, YES);
        if (!texture) continue;
        [objects addObject:texture];
        [medians addObject:@(layer.depth)];
    }
    _objects = objects;
    _medians = medians;
}

- (void)layoutForScale:(CGFloat)scale {
    CGSize size = _layer.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    CGFloat pixels = MIN(scale, 2048 / MAX(size.width, size.height));
    _layer.contentsScale = pixels;
    CGSize drawable = CGSizeMake(round(size.width * pixels), round(size.height * pixels));
    if (!CGSizeEqualToSize(_layer.drawableSize, drawable)) _layer.drawableSize = drawable;
}

- (void)encodeInto:(id<MTLTexture>)target buffer:(id<MTLCommandBuffer>)buffer zoom:(float)zoom {
    NSArray<id<MTLRenderPipelineState>> *pipelines = [AUSceneRenderer pipelines];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    AUCamera camera = AUSceneCamera(_scene, _tilt, _strength);
    AUCam cam = {{(float)camera.angleX, (float)camera.angleY}, {-0.12f, 1.12f}, (float)camera.pivot, (float)camera.scale,
                 (float)camera.focal, (float)camera.relief, 0, 0, (float)camera.zFar, (float)camera.zNear, zoom,
                 (float)camera.reliefBack, (float)camera.reliefFront, 0};
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setVertexBuffer:_grid offset:0 atIndex:1];
    [encoder setRenderPipelineState:pipelines[0]];
    [encoder setVertexBytes:&cam length:sizeof(cam) atIndex:0];
    [encoder setVertexTexture:_plate atIndex:0];
    [encoder setFragmentTexture:_background atIndex:0];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_indexCount indexType:MTLIndexTypeUInt16 indexBuffer:_indices indexBufferOffset:0];
    if (_withObjects && _objects.count) {
        [encoder setRenderPipelineState:pipelines[1]];
        [encoder setVertexTexture:_raw atIndex:0];
        cam.range[0] = 0;
        cam.range[1] = 1;
        cam.kind = 1;
        for (NSUInteger i = 0; i < _objects.count; i++) {
            cam.median = _medians[i].floatValue;
            [encoder setVertexBytes:&cam length:sizeof(cam) atIndex:0];
            [encoder setFragmentTexture:_objects[i] atIndex:0];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_indexCount indexType:MTLIndexTypeUInt16 indexBuffer:_indices indexBufferOffset:0];
        }
    }
    [encoder endEncoding];
}

- (BOOL)ready {
    return [AUSceneRenderer pipelines].count == 2 && _background && _plate;
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
