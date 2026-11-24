// The lock screen's full-screen artwork (iOS 26: a local 3:4 video through MPMediaItemAnimatedArtwork, the way
// Taurus's Lock Screen styles offer theirs): the cover's scene there too — its 3:4 painted background with the
// objects on their layers — either still, or as a looping "3D flight" with the layers sliding as the camera circles,
// since the lock screen gives no gyroscope. It rides on Spotify's now playing info under Taurus's own owner name
// ("motion", Shared/Player/NowPlayingExtras.h), so it takes the place of Taurus's lock screen artwork rather than
// racing it.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "Features/AUScene.h"

NS_ASSUME_NONNULL_BEGIN

#define AUKeyLockScreen @"aura.lock"   // 0 the 3D flight, 1 stretched, 2 off

// One frame of the clip at `phase` (0...1 round the loop). Caller releases.
CGImageRef _Nullable AULockClipFrame(AUScene *scene, CGSize size, double phase, BOOL moving) CF_RETURNS_RETAINED;
// Writes the clip as H.264 (6 s loop at 30 fps when moving, 1 s still otherwise); NO if it was not written.
BOOL AULockClipWrite(NSURL *file, AUScene *scene, CGSize size, BOOL moving);

void AULockScreenStart(void);

NS_ASSUME_NONNULL_END
