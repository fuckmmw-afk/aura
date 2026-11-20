// What Aura works out for a cover, keyed by the picture's own id, computed off the main queue when the track
// changes, kept on disk (Caches/Aura/Artwork) and the last few in memory. Nothing is worked out twice.
#import <UIKit/UIKit.h>
#import "AUPalette.h"

NS_ASSUME_NONNULL_BEGIN

@interface AUArtwork : NSObject
@property (nonatomic, copy, readonly) NSString *key;
@property (nonatomic, readonly) BOOL exact;
@property (nonatomic, copy, nullable) NSString *trackURI;     // the track it was published for (an album's songs share an artwork)
@property (nonatomic, strong, nullable) AUPalette *palette;
@property (nonatomic, strong, nullable) UIImage *source;      // the cover as drawn: upscaled when it was small
@property (nonatomic) BOOL upscaled;
@property (nonatomic) BOOL upscaleChecked;                    // upscaling was on when the source was made
@property (nonatomic, strong, nullable) UIImage *depth;       // gray, near bright
@property (nonatomic, strong, nullable) UIImage *softDepth;   // the same softened, under a lifted subject
@property (nonatomic, strong, nullable) UIImage *cutout;      // the subject, RGBA, the source's size
@property (nonatomic, strong, nullable) UIImage *background;  // the cover blurred, under the subject
@property (nonatomic) CGRect subjectBounds;                   // 0...1, origin top left
@property (nonatomic) BOOL noSubject;                         // looked for, none that reads
@property (nonatomic) BOOL cutoutObjects;                     // looked for any subject, not only people
@property (nonatomic) CFTimeInterval arrived;                 // when the track's cover came, for the latency stat
@end

// Posted on the main queue each time a stage of the current artwork lands; object is the AUArtwork.
extern NSNotificationName const AUArtworkDidChangeNotification;

@interface AUPipeline : NSObject
+ (instancetype)shared;
- (void)start;
@property (nonatomic, readonly, nullable) AUArtwork *current;
- (uint64_t)cacheBytes;
- (void)clearCache;
@end

NS_ASSUME_NONNULL_END
