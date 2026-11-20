#import "AUTaurus.h"
#import "AUCore.h"
#import "AUManifest.h"
#import <dlfcn.h>

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
    BOOL (*redesigned)(void) = (BOOL (*)(void))sym("SGRedesignedUI");
    return redesigned && redesigned();
}

UIImage *AUTaurusArtwork(NSString **trackURI, NSString **pictureKey, BOOL *exact) {
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
    void *slot = sym("SGRNowPlayingArtworkDidChangeNotification");
    return slot ? (__bridge NSString *)(*(void **)slot) : nil;
}

BOOL AUTaurusFollowsCover(void) {
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

void AUTaurusRestart(void) {
    void (*restart)(void) = (void (*)(void))sym("SGRestartSpotify");
    if (restart) restart();
}

#pragma mark - rows

BOOL AUTaurusRowsAvailable(void) {
    return NSClassFromString(@"SGModPage") && sym("SGSwitchRow") && sym("SGSection") && sym("SGStatRow") && sym("SGActionRow")
        && sym("SGPageRow");
}

typedef SGModRow *(*RowTSK)(NSString *, NSString *, NSString *);

SGModRow *AURowSwitch(NSString *title, NSString *subtitle, NSString *key) {
    RowTSK f = (RowTSK)sym("SGSwitchRow");
    return f ? f(title, subtitle, key) : nil;
}

SGModRow *AURowOption(NSString *title, NSString *subtitle, NSString *key) {
    RowTSK f = (RowTSK)sym("SGOptionRow");
    return f ? f(title, subtitle, key) : nil;
}

SGModRow *AURowStat(NSString *title, NSString * (^value)(void)) {
    SGModRow *(*f)(NSString *, NSString * (^)(void)) = (SGModRow * (*)(NSString *, NSString * (^)(void))) sym("SGStatRow");
    return f ? f(title, value) : nil;
}

SGModRow *AURowAction(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *(*f)(NSString *, NSString *, void (^)(void)) = (SGModRow * (*)(NSString *, NSString *, void (^)(void))) sym("SGActionRow");
    return f ? f(title, subtitle, action) : nil;
}

SGModRow *AURowStatAction(NSString *title, NSString *subtitle, NSString * (^value)(void), void (^action)(void)) {
    typedef SGModRow *(*F)(NSString *, NSString *, NSString * (^)(void), void (^)(void));
    F f = (F)sym("SGStatActionRow");
    if (f) return f(title, subtitle, value, action);
    SGModRow *row = AURowAction(title, subtitle, action);
    row.value = value;
    return row;
}

SGModRow *AURowPage(NSString *title, UIViewController * (^page)(void)) {
    SGModRow *(*f)(NSString *, UIViewController * (^)(void)) = (SGModRow * (*)(NSString *, UIViewController * (^)(void))) sym("SGPageRow");
    return f ? f(title, page) : nil;
}

SGModRow *AURowSlider(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString * (^format)(double value)) {
    typedef SGModRow *(*F)(NSString *, NSString *, double, double, double, double (^)(void), void (^)(double), NSString * (^)(double));
    F f = (F)sym("SGSliderRow");
    return f ? f(title, subtitle, minimum, maximum, step, get, set, format) : nil;
}

SGModRow *AURowChoice(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) {
    typedef SGModRow *(*F)(NSString *, NSString *, NSString *, NSArray<NSString *> *, NSInteger);
    F f = (F)sym("SGChoiceRow");
    return f ? f(title, subtitle, key, choices, fallback) : nil;
}

SGModRow *AURowSymbol(SGModRow *row, NSString *symbol) {
    SGModRow *(*f)(SGModRow *, NSString *) = (SGModRow * (*)(SGModRow *, NSString *)) sym("SGWithSymbol");
    if (!row) return nil;
    return f ? f(row, symbol) : row;
}

SGModSection *AUSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) {
    NSMutableArray *kept = [NSMutableArray array];
    for (id row in rows) {
        if (row != NSNull.null) [kept addObject:row];
    }
    if (footer) {
        SGModSection *(*noted)(NSString *, NSArray *, NSString *) = (SGModSection * (*)(NSString *, NSArray *, NSString *)) sym("SGNotedSection");
        if (noted) return noted(title, kept, footer);
    }
    SGModSection *(*f)(NSString *, NSArray *) = (SGModSection * (*)(NSString *, NSArray *)) sym("SGSection");
    return f ? f(title, kept) : nil;
}
