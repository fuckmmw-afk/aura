// Declarations of newer system API for building against an older SDK (the Linux Theos SDK is 16.5).
// Every class here is looked up with NSClassFromString, so nothing links against what an SDK lacks.
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

NS_ASSUME_NONNULL_BEGIN

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 170000
@interface VNInstanceMaskObservation : VNObservation
@property (readonly, copy) NSIndexSet *allInstances;
- (nullable CVPixelBufferRef)generateScaledMaskForImageForInstances:(NSIndexSet *)instances
                                                 fromRequestHandler:(VNImageRequestHandler *)requestHandler
                                                              error:(NSError *_Nullable *_Nullable)error CF_RETURNS_RETAINED;
@end
@interface VNGeneratePersonInstanceMaskRequest : VNImageBasedRequest
@end
@interface VNGenerateForegroundInstanceMaskRequest : VNImageBasedRequest
@end
#endif

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 260000
typedef NS_ENUM(NSInteger, UIGlassEffectStyle) {
    UIGlassEffectStyleRegular,
    UIGlassEffectStyleClear,
};
@interface UIGlassEffect : UIVisualEffect
+ (instancetype)effectWithStyle:(UIGlassEffectStyle)style;
@property (nonatomic, copy, nullable) UIColor *tintColor;
@property (nonatomic, getter=isInteractive) BOOL interactive;
@end
#endif

NS_ASSUME_NONNULL_END
