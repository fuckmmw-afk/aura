// Taurus, as Aura reaches it: by the C functions and classes its dylib exports, looked up at run time.
// Nothing of Taurus is linked, copied or changed; when a symbol is missing the feature that needs it stays off.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL AUTaurusPresent(void);
BOOL AUTaurusRedesigned(void);
NSString *AUTaurusMissing(void);   // the symbols not found, for the log

// The now playing artwork Taurus publishes, with the picture's own key (Spotify's image id: stable for a cover)
// and whether it is the exact picture the track names rather than one read off a screen.
UIImage *_Nullable AUTaurusArtwork(NSString *_Nullable *_Nullable trackURI, NSString *_Nullable *_Nullable pictureKey, BOOL *_Nullable exact);
NSNotificationName _Nullable AUTaurusArtworkNotification(void);

// The player's accent from the cover (Taurus's Follow the cover paints the buttons, the like and the progress bar).
BOOL AUTaurusFollowsCover(void);
void AUTaurusSetCoverAccent(UIColor *color);
#define AUTaurusKeyFollowsCover @"spotifyglass.redesign.player.followsCover"
void AUTaurusSetSwitch(NSString *key, BOOL on);
void AUTaurusRestart(void);

#pragma mark - the player

// The track playing now, from Taurus's player state: its URI ("spotify:track:…") and title. nil before it reports.
NSString *_Nullable AUTaurusTrackURI(void);
NSString *_Nullable AUTaurusTrackTitle(void);
// Posted on the main queue when the playing track's URI changes; userInfo "uri".
extern NSNotificationName const AUTrackDidChangeNotification;
void AUTaurusFollowTrack(void);

#pragma mark - settings rows (Settings/SGModPage.h)

@interface SGModRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString * (^value)(void);
@property (nonatomic, copy) void (^changed)(BOOL on);
@property (nonatomic, copy) NSString *info;
@property (nonatomic, copy) NSNotificationName refreshOn;
@property (nonatomic, copy) NSString *waitsOn;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) void (^chosen)(NSInteger index);
@end

@interface SGModSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SGModRow *> *rows;
@property (nonatomic, copy) NSString *footer;
@end

@interface SGModPage : UIViewController
- (instancetype)initWithTitle:(NSString *)title intro:(nullable NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(nullable NSString *)footer;
@end

BOOL AUTaurusRowsAvailable(void);
SGModRow *_Nullable AURowSwitch(NSString *title, NSString *_Nullable subtitle, NSString *key);   // on until switched off
SGModRow *_Nullable AURowOption(NSString *title, NSString *_Nullable subtitle, NSString *key);   // off until switched on
SGModRow *_Nullable AURowStat(NSString *title, NSString * (^value)(void));
SGModRow *_Nullable AURowAction(NSString *title, NSString *_Nullable subtitle, void (^action)(void));
SGModRow *_Nullable AURowStatAction(NSString *title, NSString *_Nullable subtitle, NSString * (^value)(void), void (^action)(void));
SGModRow *_Nullable AURowPage(NSString *title, UIViewController * (^page)(void));
SGModRow *_Nullable AURowSlider(NSString *title, NSString *_Nullable subtitle, double minimum, double maximum, double step,
                                double (^get)(void), void (^set)(double value), NSString * (^format)(double value));
SGModRow *_Nullable AURowChoice(NSString *title, NSString *_Nullable subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback);
SGModRow *_Nullable AURowSymbol(SGModRow *_Nullable row, NSString *symbol);
SGModSection *_Nullable AUSection(NSString *_Nullable title, NSArray<SGModRow *> *rows, NSString *_Nullable footer);

NS_ASSUME_NONNULL_END
