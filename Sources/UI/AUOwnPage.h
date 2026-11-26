// Aura's own settings page, for a host without Taurus (Yandex Music): the same rows Taurus's SGModPage draws
// (switches, sliders, choices, stats, actions, pages), answering to the same properties, so Sources/UI/AUSettings.m
// builds one page for either host.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AUOwnRowKind) {
    AUOwnRowSwitch,     // on until switched off
    AUOwnRowOption,     // off until switched on
    AUOwnRowStat,
    AUOwnRowAction,
    AUOwnRowPage,
    AUOwnRowSlider,
    AUOwnRowChoice,
};

@interface AUOwnRow : NSObject
@property (nonatomic) AUOwnRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, copy, nullable) NSString * (^value)(void);
@property (nonatomic, copy, nullable) void (^changed)(BOOL on);
@property (nonatomic, copy, nullable) void (^action)(void);
@property (nonatomic, copy, nullable) UIViewController * (^page)(void);
@property (nonatomic, copy, nullable) NSString *info;
@property (nonatomic, copy, nullable) NSNotificationName refreshOn;
@property (nonatomic, copy, nullable) NSString *waitsOn;
@property (nonatomic, strong, nullable) UIColor *color;
@property (nonatomic, copy, nullable) NSString *symbol;
@property (nonatomic, copy, nullable) void (^chosen)(NSInteger index);
@property (nonatomic, copy, nullable) NSArray<NSString *> *choices;
@property (nonatomic) NSInteger fallback;
@property (nonatomic) double minimum, maximum, step;
@property (nonatomic, copy, nullable) double (^number)(void);
@property (nonatomic, copy, nullable) void (^setNumber)(double value);
@property (nonatomic, copy, nullable) NSString * (^format)(double value);
@end

@interface AUOwnSection : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSArray<AUOwnRow *> *rows;
@property (nonatomic, copy, nullable) NSString *footer;
@end

@interface AUOwnPage : UITableViewController
- (instancetype)initWithTitle:(NSString *)title intro:(nullable NSString *)intro sections:(NSArray<AUOwnSection *> *)sections footer:(nullable NSString *)footer;
@end

NS_ASSUME_NONNULL_END
