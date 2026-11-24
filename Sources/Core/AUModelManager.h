// The models Aura runs, fetched on demand from the model server into Application Support, compiled to .mlmodelc once
// and kept. Loaded only while used: dropped after a few idle minutes and on a memory warning.
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import "AUManifest.h"

NS_ASSUME_NONNULL_BEGIN

#define AUModelDepth @"depth-v2s-p8"     // Depth Anything V2 Small, 8-bit palettized (Apple, Apache-2.0)
#define AUModelUpscale @"esrgan-x4v3"    // Real-ESRGAN realesr-general-x4v3, 128px tiles (BSD-3-Clause)
#define AUModelInpaint @"lama-256"       // Big-LaMa inpainting, 256 x 256, fp16 with pre-scaled Fourier matrices, 8-bit palettes, CPU (Apache-2.0)

typedef NS_ENUM(NSInteger, AUModelState) {
    AUModelMissing,
    AUModelDownloading,
    AUModelCompiling,
    AUModelReady,
    AUModelFailed,
};

// Posted on the main queue when a model's state or progress changed; object is the model id.
extern NSNotificationName const AUModelsDidChangeNotification;



@interface AUModelManager : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL serverConfigured;
- (NSString *)titleOf:(NSString *)modelID;
- (NSString *)licenseOf:(NSString *)modelID;
- (AUModelState)stateOf:(NSString *)modelID;
- (double)progressOf:(NSString *)modelID;
- (nullable NSString *)lastErrorOf:(NSString *)modelID;
- (uint64_t)bytesOnDiskOf:(NSString *)modelID;
- (NSString *)statusTextOf:(NSString *)modelID;
// Starts the download and compile when the model is not on the phone; nothing when it is or is on its way.
- (void)ensure:(NSString *)modelID;
// The loaded model, loading it if it is compiled; nil if not on the phone yet (and then it is fetched).
// Call from a background queue: a first load takes a while.
- (nullable MLModel *)modelFor:(NSString *)modelID;
- (void)unloadAll;
- (void)deleteAll;
@end

NS_ASSUME_NONNULL_END
