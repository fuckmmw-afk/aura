// Aura: on-device AI effects for the Taurus (spotifyglass) redesigned player.
// Everything here is Aura's own code; Taurus is only called through the symbols its dylib exports.
#import <UIKit/UIKit.h>

#ifndef AURA_VERSION
#define AURA_VERSION "dev"
#endif
// Where the models live ("https://host/aura/models"), given at build time from a GitHub secret.
#ifndef AURA_MODELS_URL
#define AURA_MODELS_URL ""
#endif

NS_ASSUME_NONNULL_BEGIN

#pragma mark - log

// One line to the device log ("[aura] ...") and to Documents/Aura/aura.log, which the Files app shows.
void AULog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSURL *AULogURL(void);

#pragma mark - settings

#define AUKeyTheme @"aura.theme"                 // on until switched off
#define AUKeyThemeScope @"aura.theme.scope"      // 0 everywhere, 1 the player only
#define AUKeyThemeStrength @"aura.theme.strength"
#define AUKeyDepth @"aura.depth"
#define AUKeyDepthStrength @"aura.depth.strength"
#define AUKeyCutout @"aura.cutout"                // (retired)
#define AUKeyPopOut @"aura.popout"                // off until switched on: the objects step out of the cover's frame
#define AUKeyCutoutObjects @"aura.cutout.objects" // (retired)
#define AUKeyScenePeopleOnly @"aura.scene.peopleOnly" // off: every subject on the cover gets a layer
#define AUKeyUpscale @"aura.upscale"

BOOL AUEnabled(NSString *key);   // unset is on
BOOL AUFlag(NSString *key);      // unset is off
double AUNumber(NSString *key, double fallback);
void AUSetNumber(NSString *key, double value);
NSInteger AUInteger(NSString *key, NSInteger fallback);
// Posted on the main queue when one of Aura's settings changed.
extern NSNotificationName const AUSettingsDidChangeNotification;
void AUSettingsChanged(void);

#pragma mark - system

void AUSystemStart(void);
// Only when "Пауза при перегреве" is on (off by default) and the thermal state is serious or critical: then no
// parallax and no background work but the palette.
#define AUKeyThermalPause @"aura.thermalPause"
BOOL AUThrottled(void);
extern NSNotificationName const AUThrottleDidChangeNotification;
uint64_t AUFootprint(void);       // the process's physical footprint, bytes
uint64_t AUPeakFootprint(void);   // the highest seen since launch
NSString *AUBytes(uint64_t bytes);
NSString *AUThermalName(void);

#pragma mark - stats

double AUNowMs(void);
void AUStatRecord(NSString *name, double ms);
NSString *AUStatText(NSString *name);   // "31 мс (ср. 28, n=12)" or "—"
// Frames the parallax drew, counted for the minute's telemetry line.
void AUCountFrame(void);

#pragma mark - helpers

NSString *AUSHA1(NSString *string);
UIViewController *_Nullable AUTopViewController(void);
void AUShareFile(NSURL *url);

NS_ASSUME_NONNULL_END
