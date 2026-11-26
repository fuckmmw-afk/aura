#import "AUTaurus.h"
#import "AUCore.h"
#import "AUManifest.h"
#import "AUYandex.h"
#import "UI/AUOwnPage.h"
#import <dlfcn.h>

// Under Yandex Music there is no Taurus: what it would hand over comes from Core/AUYandex, the rows from UI/AUOwnPage.

static void *sym(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static const char *const kNeeded[] = {
    "SGRNowPlayingArtwork", "SGRNowPlayingArtworkDidChangeNotification", "SGRedesignedUI",
};

BOOL AUTaurusPresent(void) {
    for (size_t i = 0; i < sizeof(kNeeded) / sizeof(*kNeeded); i++) {
        if (!sym(kNeeded[i])) return NO;
    }
    return YES;
}

NSString *AUTaurusMissing(void) {
    NSMutableArray *missing = [NSMutableArray array];
    const char *all[] = {"SGRNowPlayingArtwork", "SGRNowPlayingArtworkDidChangeNotification", "SGRedesignedUI",
                         "SGRPlayerSetCoverAccent", "SGRPlayerFollowsCover", "SGSwitchRow", "SGOptionRow", "SGSection",
                         "SGNotedSection", "SGStatRow", "SGActionRow", "SGStatActionRow", "SGPageRow", "SGSliderRow",
                         "SGChoiceRow", "SGWithSymbol", "SGSetEnabled", "SGRestartSpotify"};
    for (size_t i = 0; i < sizeof(all) / sizeof(*all); i++) {
        if (!sym(all[i])) [missing addObject:@(all[i])];
    }
    if (!NSClassFromString(@"SGModPage")) [missing addObject:@"SGModPage"];
    return missing.count ? [missing componentsJoinedByString:@", "] : @"none";
}

BOOL AUTaurusRedesigned(void) {
    if (AUHostYandex()) return YES;
    BOOL (*redesigned)(void) = (BOOL (*)(void))sym("SGRedesignedUI");
    return redesigned && redesigned();
}

UIImage *AUTaurusArtwork(NSString **trackURI, NSString **pictureKey, BOOL *exact) {
    if (AUHostYandex()) return AUYandexArtwork(trackURI, pictureKey, exact);
    typedef UIImage *(*Artwork)(NSString *__autoreleasing *, NSString *__autoreleasing *);
    Artwork artwork = (Artwork)sym("SGRNowPlayingArtwork");
    if (!artwork) return nil;
    NSString *uri = nil, *identity = nil;
    UIImage *image = artwork(&uri, &identity);
    BOOL isExact = NO;
    NSString *key = identity.length ? AUPictureKeyFromIdentity(identity, &isExact) : nil;
    if (trackURI) *trackURI = uri;
    if (pictureKey) *pictureKey = key;
    if (exact) *exact = isExact;
    return image;
}

NSNotificationName AUTaurusArtworkNotification(void) {
    if (AUHostYandex()) return AUYandexArtworkDidChangeNotification;
    void *slot = sym("SGRNowPlayingArtworkDidChangeNotification");
    return slot ? (__bridge NSString *)(*(void **)slot) : nil;
}

BOOL AUTaurusFollowsCover(void) {
    if (AUHostYandex()) return NO;
    BOOL (*follows)(void) = (BOOL (*)(void))sym("SGRPlayerFollowsCover");
    return follows && follows();
}

void AUTaurusSetCoverAccent(UIColor *color) {
    void (*set)(UIColor *) = (void (*)(UIColor *))sym("SGRPlayerSetCoverAccent");
    if (set) set(color);
}

void AUTaurusSetSwitch(NSString *key, BOOL on) {
    void (*set)(NSString *, BOOL) = (void (*)(NSString *, BOOL))sym("SGSetEnabled");
    if (set) set(key, on);
    else [NSUserDefaults.standardUserDefaults setBool:on forKey:key];
}

void AUTaurusSetExtras(NSString *owner, NSDictionary *extras, NSString *title) {
    if (AUHostYandex()) {
        AUYandexSetExtras(extras, title);
        return;
    }
    void (*setExtras)(NSString *, NSDictionary *, NSString *) = (void (*)(NSString *, NSDictionary *, NSString *))sym("SGNowPlayingSetExtras");
    if (setExtras) setExtras(owner, extras, title);
}

BOOL AUTaurusCanSetExtras(void) {
    return AUHostYandex() || sym("SGNowPlayingSetExtras") != NULL;
}

NSString *AUHostName(void) {
    return AUHostYandex() ? @"Яндекс Музыки" : @"Spotify";
}

UIViewController *AUMakePage(NSString *title, NSString *intro, NSArray *sections, NSString *footer) {
    Class taurus = AUHostYandex() ? Nil : NSClassFromString(@"SGModPage");
    if (taurus) return [[taurus alloc] initWithTitle:title intro:intro sections:sections footer:footer];
    return [[AUOwnPage alloc] initWithTitle:title intro:intro sections:sections footer:footer];
}

void AUTaurusRestart(void) {
    void (*restart)(void) = (void (*)(void))sym("SGRestartSpotify");
    if (restart) restart();
}

#pragma mark - rows

// Taurus's rows when they are there (Spotify), Aura's own otherwise.
static BOOL ownRows(void) {
    return AUHostYandex() || !sym("SGSwitchRow");
}

static SGModRow *own(AUOwnRowKind kind, NSString *title, NSString *subtitle, NSString *key) {
    AUOwnRow *row = [AUOwnRow new];
    row.kind = kind;
    row.title = title;
    row.subtitle = subtitle;
    row.key = key;
    return (SGModRow *)row;
}

BOOL AUTaurusRowsAvailable(void) {
    if (ownRows()) return YES;
    return NSClassFromString(@"SGModPage") && sym("SGSwitchRow") && sym("SGSection") && sym("SGStatRow") && sym("SGActionRow")
        && sym("SGPageRow");
}

typedef SGModRow *(*RowTSK)(NSString *, NSString *, NSString *);

SGModRow *AURowSwitch(NSString *title, NSString *subtitle, NSString *key) {
    if (ownRows()) return own(AUOwnRowSwitch, title, subtitle, key);
    RowTSK f = (RowTSK)sym("SGSwitchRow");
    return f ? f(title, subtitle, key) : nil;
}

SGModRow *AURowOption(NSString *title, NSString *subtitle, NSString *key) {
    if (ownRows()) return own(AUOwnRowOption, title, subtitle, key);
    RowTSK f = (RowTSK)sym("SGOptionRow");
    return f ? f(title, subtitle, key) : nil;
}

SGModRow *AURowStat(NSString *title, NSString * (^value)(void)) {
    if (ownRows()) {
        SGModRow *row = own(AUOwnRowStat, title, nil, nil);
        row.value = value;
        return row;
    }
    SGModRow *(*f)(NSString *, NSString * (^)(void)) = (SGModRow * (*)(NSString *, NSString * (^)(void))) sym("SGStatRow");
    return f ? f(title, value) : nil;
}

SGModRow *AURowAction(NSString *title, NSString *subtitle, void (^action)(void)) {
    if (ownRows()) {
        AUOwnRow *row = (AUOwnRow *)own(AUOwnRowAction, title, subtitle, nil);
        row.action = action;
        return (SGModRow *)row;
    }
    SGModRow *(*f)(NSString *, NSString *, void (^)(void)) = (SGModRow * (*)(NSString *, NSString *, void (^)(void))) sym("SGActionRow");
    return f ? f(title, subtitle, action) : nil;
}

SGModRow *AURowStatAction(NSString *title, NSString *subtitle, NSString * (^value)(void), void (^action)(void)) {
    typedef SGModRow *(*F)(NSString *, NSString *, NSString * (^)(void), void (^)(void));
    F f = ownRows() ? NULL : (F)sym("SGStatActionRow");
    if (f) return f(title, subtitle, value, action);
    SGModRow *row = AURowAction(title, subtitle, action);
    row.value = value;
    return row;
}

SGModRow *AURowPage(NSString *title, UIViewController * (^page)(void)) {
    if (ownRows()) {
        AUOwnRow *row = (AUOwnRow *)own(AUOwnRowPage, title, nil, nil);
        row.page = page;
        return (SGModRow *)row;
    }
    SGModRow *(*f)(NSString *, UIViewController * (^)(void)) = (SGModRow * (*)(NSString *, UIViewController * (^)(void))) sym("SGPageRow");
    return f ? f(title, page) : nil;
}

SGModRow *AURowSlider(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString * (^format)(double value)) {
    if (ownRows()) {
        AUOwnRow *row = (AUOwnRow *)own(AUOwnRowSlider, title, subtitle, nil);
        row.minimum = minimum;
        row.maximum = maximum;
        row.step = step;
        row.number = get;
        row.setNumber = set;
        row.format = format;
        return (SGModRow *)row;
    }
    typedef SGModRow *(*F)(NSString *, NSString *, double, double, double, double (^)(void), void (^)(double), NSString * (^)(double));
    F f = (F)sym("SGSliderRow");
    return f ? f(title, subtitle, minimum, maximum, step, get, set, format) : nil;
}

SGModRow *AURowChoice(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) {
    if (ownRows()) {
        AUOwnRow *row = (AUOwnRow *)own(AUOwnRowChoice, title, subtitle, key);
        row.choices = choices;
        row.fallback = fallback;
        return (SGModRow *)row;
    }
    typedef SGModRow *(*F)(NSString *, NSString *, NSString *, NSArray<NSString *> *, NSInteger);
    F f = (F)sym("SGChoiceRow");
    return f ? f(title, subtitle, key, choices, fallback) : nil;
}

SGModRow *AURowSymbol(SGModRow *row, NSString *symbol) {
    SGModRow *(*f)(SGModRow *, NSString *) = (SGModRow * (*)(SGModRow *, NSString *)) sym("SGWithSymbol");
    if (!row) return nil;
    if (ownRows()) {
        row.symbol = symbol;
        return row;
    }
    return f ? f(row, symbol) : row;
}

SGModSection *AUSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) {
    NSMutableArray *kept = [NSMutableArray array];
    for (id row in rows) {
        if (row != NSNull.null) [kept addObject:row];
    }
    if (ownRows()) {
        AUOwnSection *section = [AUOwnSection new];
        section.title = title;
        section.rows = kept;
        section.footer = footer;
        return (SGModSection *)section;
    }
    if (footer) {
        SGModSection *(*noted)(NSString *, NSArray *, NSString *) = (SGModSection * (*)(NSString *, NSArray *, NSString *)) sym("SGNotedSection");
        if (noted) return noted(title, kept, footer);
    }
    SGModSection *(*f)(NSString *, NSArray *) = (SGModSection * (*)(NSString *, NSArray *)) sym("SGSection");
    return f ? f(title, kept) : nil;
}

#pragma mark - the player

NSNotificationName const AUTrackDidChangeNotification = @"AUTrackDidChangeNotification";

static id playerTrack(void) {
    id (*state)(void) = (id (*)(void))sym("SGPlayerState");
    id player = state ? state() : nil;
    return [player respondsToSelector:NSSelectorFromString(@"track")] ? [player valueForKey:@"track"] : nil;
}

NSString *AUTaurusTrackURI(void) {
    if (AUHostYandex()) return AUYandexTrackURI();
    id track = playerTrack();
    id uri = [track respondsToSelector:NSSelectorFromString(@"URI")] ? [track valueForKey:@"URI"] : nil;
    NSString *(*string)(id) = (NSString * (*)(id)) sym("SGURIString");
    if (string) return string(uri);
    if ([uri isKindOfClass:NSURL.class]) return [uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

NSString *AUTaurusTrackTitle(void) {
    if (AUHostYandex()) return AUYandexTrackTitle();
    id track = playerTrack();
    id title = [track respondsToSelector:NSSelectorFromString(@"trackTitle")] ? [track valueForKey:@"trackTitle"] : nil;
    return [title isKindOfClass:NSString.class] ? title : nil;
}

// As Taurus's SGRBridges.x pictureOf: the largest image the metadata names; every size of one picture shares the
// id's last 24 digits.
NSString *AUTaurusTrackPictureKey(void) {
    if (AUHostYandex()) return AUYandexTrackPictureKey();
    id track = playerTrack();
    NSDictionary *metadata = [track respondsToSelector:NSSelectorFromString(@"metadata")] ? [track valueForKey:@"metadata"] : nil;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *field in @[@"image_xlarge_url", @"image_large_url", @"image_url", @"image_small_url"]) {
        id value = metadata[field];
        if (![value isKindOfClass:NSString.class] || ![value length]) continue;
        NSString *identifier = nil;
        if ([value hasPrefix:@"spotify:image:"]) identifier = [value substringFromIndex:@"spotify:image:".length];
        else if ([value hasPrefix:@"https://"]) identifier = [value lastPathComponent];
        if (!identifier.length) continue;
        return identifier.length == 40 ? [identifier substringFromIndex:16] : identifier;
    }
    return nil;
}

@interface AUTrackFollower : NSObject
@property (nonatomic, copy) NSString *uri;
@end

@implementation AUTrackFollower
- (void)playerStateDidChange:(id)state {
    NSString *uri = AUTaurusTrackURI();
    if (!uri.length || [uri isEqualToString:self.uri]) return;
    self.uri = uri;
    [NSNotificationCenter.defaultCenter postNotificationName:AUTrackDidChangeNotification object:nil userInfo:@{@"uri": uri}];
}
@end

void AUTaurusFollowTrack(void) {
    static AUTrackFollower *follower;
    if (follower || AUHostYandex()) return;   // (Yandex: Core/AUYandex posts the changes itself)
    void (*add)(id) = (void (*)(id))sym("SGAddPlayerStateObserver");
    if (!add) {
        AULog(@"Taurus has no player state observers: track changes are read from the artwork only");
        return;
    }
    follower = [AUTrackFollower new];
    follower.uri = AUTaurusTrackURI();
    add(follower);
}
