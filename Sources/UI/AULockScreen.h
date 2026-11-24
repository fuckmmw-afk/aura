// The lock screen's full-screen artwork (iOS 26: a local 3:4 video through MPMediaItemAnimatedArtwork, the way
// Taurus's Lock Screen styles offer theirs): Aura's cover there too, either still and stretched over the screen, or
// as a looping "3D flight" — the camera circling slowly over the cover's depth map with the subject in front, since
// the lock screen gives no gyroscope. It rides on Spotify's now playing info under Taurus's own owner name
// ("motion", Shared/Player/NowPlayingExtras.h), so it takes the place of Taurus's lock screen artwork rather than
// racing it.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyLockScreen @"aura.lock"   // 0 the 3D flight, 1 stretched, 2 off

typedef struct {
    CGImageRef _Nullable color;     // the cover, or its background with the subject lifted out
    CGImageRef _Nullable depth;     // nil for a still picture
    CGImageRef _Nullable subject;   // the subject over it, the cover's size, or nil
} AULockClipInput;

// One frame of the clip at `phase` (0...1 round the loop). Caller releases.
CGImageRef _Nullable AULockClipFrame(AULockClipInput input, CGSize size, double phase, BOOL moving) CF_RETURNS_RETAINED;
// Writes the clip as H.264 (6 s loop at 30 fps when moving, 1 s still otherwise); NO if it was not written.
BOOL AULockClipWrite(NSURL *file, AULockClipInput input, CGSize size, BOOL moving);

void AULockScreenStart(void);

NS_ASSUME_NONNULL_END
