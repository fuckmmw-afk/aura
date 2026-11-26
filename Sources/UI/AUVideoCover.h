// Yandex Music's video covers on the lock screen.
//
// Some tracks have a short looping video instead of a still cover (the track's backgroundVideoUri), which the app
// plays with AVFoundation in its player. The video that starts playing while a track is current is that track's; it is
// taken as it is, cropped to the lock screen's 3:4 (aspect fill) and handed over as the animated artwork in place of
// Aura's 3D flight. Made on the CPU (AVAssetReader → vImage → AVAssetWriter), since a locked phone gives no GPU.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyLockVideo @"aura.lock.video"   // on until switched off

// Posted on the main queue when a track's video became known; userInfo "uri".
extern NSNotificationName const AUVideoCoverDidChangeNotification;

// From the AVPlayer hooks: `player` started playing.
void AUVideoCoverPlayerStarted(AVPlayer *player);
// The video known for the track `uri`, or nil.
AVURLAsset *_Nullable AUVideoCoverFor(NSString *uri);
// The video as a 3:4 clip at `size` in `file`; `poster` gets its first frame. NO when it could not be made.
BOOL AUVideoCoverWrite(AVURLAsset *asset, NSURL *file, CGSize size, UIImage *_Nullable *_Nullable poster);

NS_ASSUME_NONNULL_END
