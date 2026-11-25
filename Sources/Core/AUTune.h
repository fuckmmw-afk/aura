// Every number Aura's look is made of, in one table: its default, its range, and where a change takes effect.
// Each is a setting (aura.t.<name>); "Тонкая настройка" in Aura's page shows them all.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AUTuneEffect) {
    AUTuneLive,     // the next frame shows it
    AUTuneScene,    // the scenes are made again (objects, painting)
    AUTuneLock,     // the lock-screen clip is made again
};

typedef NS_ENUM(NSInteger, AUTuneFormat) {
    AUTuneTimes,    // ×1.25
    AUTunePercent,  // 56%
    AUTuneDegrees,  // 14°
    AUTuneSeconds,  // 6.0 s
    AUTuneCount,    // 8
    AUTuneSwitch,   // on/off (0/1)
    AUTunePlain,    // 0.42
};

@interface AUTuneItem : NSObject
@property (nonatomic, copy) NSString *name, *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic) double fallback, minimum, maximum, step;
@property (nonatomic) AUTuneFormat format;
@property (nonatomic) AUTuneEffect effect;
@end

@interface AUTuneSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *footer;
@property (nonatomic, copy) NSArray<AUTuneItem *> *items;
@end

NSArray<AUTuneSection *> *AUTuneSections(void);
// The value now (the setting, or the default), kept within its range.
double AUTune(NSString *name);
BOOL AUTuneOn(NSString *name);
void AUTuneSet(NSString *name, double value);
void AUTuneResetAll(void);
// What the values of one kind are now, as a string: a scene or a clip made with others is made again.
NSString *AUTuneSignature(AUTuneEffect effect);
NSString *AUTuneText(AUTuneItem *item, double value);

NS_ASSUME_NONNULL_END
