// The ear of «Печатная машинка»: the song as Spotify plays it, read (never changed) from the output unit's render
// notify, and the sung syllables found in it as they come. The voice is taken from the centre of the mix (mid less
// side, what is panned wide goes), 180 Hz – 4 kHz, and a syllable is a rise there that is tonal (a voice's
// harmonics) rather than flat (a drum); a live threshold over the last 0.6 s picks the peaks.
//
// Each syllable is stamped with the moment it will be heard: the render's host time plus the route's output latency
// (AirPods included), so the typing lands with the voice whatever the route. Work is done off the render thread on a
// queue of its own, about 100 small FFTs a second, and only while something wants it.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// From the constructor, before Spotify starts its audio: AudioOutputUnitStart repointed in Spotify's executable.
void AUVoiceInstall(void);
// Whether anything wants syllables now (main thread). Off: the render notify does nothing but return.
void AUVoiceSetWanted(BOOL wanted);
// Sound has come through in the last second and a half (the tap works and something plays).
BOOL AUVoiceHearing(void);
BOOL AUVoiceInstalled(void);
// The syllables heard by `now` (CACurrentMediaTime), oldest first, as the media times they were heard at; they are
// taken off the queue. Returns how many were written.
NSUInteger AUVoiceTakeOnsets(CFTimeInterval now, CFTimeInterval *times, NSUInteger capacity);
void AUVoiceClear(void);
// How readily a rise counts as a syllable: 1 as tuned, more hears more.
void AUVoiceSetSensitivity(double sensitivity);
uint64_t AUVoiceOnsetCount(void);   // since launch, for the settings' stat

NS_ASSUME_NONNULL_END
