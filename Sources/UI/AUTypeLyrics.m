#import "AUTypeLyrics.h"
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"
#import "Features/AUPalette.h"
#import "Features/AUPipeline.h"
#import "Features/AUVoice.h"

extern const unsigned char AUGagalinOTF[];
extern const size_t AUGagalinOTF_len;

// The look, matched frame by frame against the reference video: sizes are shares of the view's width, the line pitch
// and the gaps in em. The rest are settings (AUTSettings).
static const CGFloat kMargin = 0.045;    // each side
static const CGFloat kMaxEm = 0.165;     // the largest size, a few words on a line
static const CGFloat kBoxHeight = 0.50;  // the room the text must fit in; past it the text shrinks
static const CGFloat kSpace = 0.26;      // the least gap between two words
static const CGFloat kCapTop = 0.315;    // from the top of the em box down to the capitals (ascent 1.005 − cap 0.70)
static const CGFloat kCapHeight = 0.74;  // the cursor's height
static const CGFloat kLensK = 0.09;      // the reference's lens: letters at 0.6 of the half width ~10 % bigger
static const double kBlink = 1.0;        // s: the idle cursor's period
static const NSUInteger kTogetherMost = 3;   // more letters than this at once (a seek): in without the blur

#pragma mark - settings

typedef struct {
    BOOL on, compact, cursor, ear, earWords, learn;
    NSInteger fps;
    double size, glow, tint, motion, lens, snap, gaps, speed, appear, width, pitch, lift, hold, sensitivity, offset;
} AUTSettings;
static AUTSettings gSet;
static CFTimeInterval gSetRead;

static double clampNumber(NSString *key, double fallback, double low, double high) {
    double value = AUNumber(key, fallback);
    return isfinite(value) ? MIN(high, MAX(low, value)) : fallback;
}

static const AUTSettings *settings(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSetRead < 0.5 && gSetRead > 0) return &gSet;
    gSetRead = now;
    gSet.on = AUEnabled(AUKeyTypeLyrics);
    gSet.compact = AUEnabled(AUKeyTypeLyricsCompact);
    gSet.cursor = AUEnabled(AUKeyTypeLyricsCursor);
    gSet.ear = AUEnabled(AUKeyTypeLyricsEar);
    gSet.earWords = AUFlag(AUKeyTypeLyricsEarWords);
    gSet.learn = AUEnabled(AUKeyTypeLyricsLearn);
    static const NSInteger rates[] = {24, 30, 60, 120};
    NSInteger rate = AUInteger(AUKeyTypeLyricsFPS, 2);
    gSet.fps = rates[rate >= 0 && rate < 4 ? rate : 2];
    gSet.size = clampNumber(AUKeyTypeLyricsSize, 1.0, 0.5, 1.5);
    gSet.glow = clampNumber(AUKeyTypeLyricsGlow, 0.35, 0, 1);
    gSet.tint = clampNumber(AUKeyTypeLyricsTint, 0.5, 0, 1);
    gSet.motion = clampNumber(AUKeyTypeLyricsMotion, 1.0, 0, 2);
    gSet.lens = clampNumber(AUKeyTypeLyricsLens, 1.0, -1, 2);
    gSet.snap = clampNumber(AUKeyTypeLyricsSnap, 0.75, 0, 1);
    gSet.gaps = clampNumber(AUKeyTypeLyricsGaps, 0.8, 0, 2);
    gSet.speed = clampNumber(AUKeyTypeLyricsSpeed, 60, 15, 150);
    gSet.appear = clampNumber(AUKeyTypeLyricsAppear, 0.11, 0, 0.4);
    gSet.width = clampNumber(AUKeyTypeLyricsWidth, 0.80, 0.6, 1.0);
    gSet.pitch = clampNumber(AUKeyTypeLyricsPitch, 0.95, 0.8, 1.3);
    gSet.lift = clampNumber(AUKeyTypeLyricsLift, 0, -0.3, 0.3);
    gSet.hold = clampNumber(AUKeyTypeLyricsHold, 2.5, 0.5, 15);
    gSet.sensitivity = clampNumber(AUKeyTypeLyricsSensitivity, 1.0, 0.5, 2);
    gSet.offset = clampNumber(AUKeyTypeLyricsOffset, 0, -400, 400);
    AUVoiceSetSensitivity(gSet.sensitivity);
    return &gSet;
}

#pragma mark - the typeface

static CGFontRef gagalin(void) {
    static CGFontRef font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, AUGagalinOTF, AUGagalinOTF_len, NULL);
        if (provider) {
            font = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
        }
        if (!font) AULog(@"type: Gagalin did not load (%zu bytes); the system font stands in", AUGagalinOTF_len);
    });
    return font;
}

CTFontRef AUTypeFont(CGFloat size) {
    static NSMutableDictionary<NSString *, id> *fonts;
    if (!fonts) fonts = [NSMutableDictionary dictionary];
    size = MAX(4, round(size * 4) / 4);
    double width = settings()->width;
    NSString *key = [NSString stringWithFormat:@"%.2f|%.3f", size, width];
    id kept = fonts[key];
    if (kept) return (__bridge CTFontRef)kept;
    if (fonts.count > 96) [fonts removeAllObjects];
    CGAffineTransform narrow = CGAffineTransformMakeScale(width, 1);
    CGFontRef graphics = gagalin();
    CTFontRef font = NULL;
    if (graphics) {
        font = CTFontCreateWithGraphicsFont(graphics, size, &narrow, NULL);
    } else {
        CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, size, NULL);
        if (system) {
            font = CTFontCreateCopyWithAttributes(system, size, &narrow, NULL);
            CFRelease(system);
        }
    }
    if (!font) return NULL;
    fonts[key] = (__bridge_transfer id)font;
    return font;
}

#pragma mark - Taurus, read

static Ivar ivarNamed(id object, const char *name) {
    return object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
}

static id objectIvar(id object, const char *name) {
    Ivar ivar = ivarNamed(object, name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

static BOOL boolIvar(id object, const char *name, BOOL fallback) {
    Ivar ivar = ivarNamed(object, name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || (type[0] != 'B' && type[0] != 'c')) return fallback;
    return *(BOOL *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
}

static BOOL doubleIvar(id object, const char *name, double *value) {
    Ivar ivar = ivarNamed(object, name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || type[0] != 'd') return NO;
    *value = *(double *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
    return YES;
}

static NSInteger integerOf(id object, NSString *key) {
    @try {
        return [[object valueForKey:key] integerValue];
    } @catch (__unused NSException *e) {
        return 0;
    }
}

static void *taurus(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

#pragma mark - the song's lines, as typed

// One letter (a composed character sequence), its word's time from the source and its syllable.
@interface AUTUnit : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double wordStart, wordEnd;   // the source word it came from (estimated where the line is not word timed)
@property (nonatomic) NSUInteger inWord, wordLetters;
@property (nonatomic) NSUInteger word, syllable;
@end
@implementation AUTUnit
@end

@interface AUTLine : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSArray<AUTUnit *> *units;
@property (nonatomic, copy) NSArray<NSNumber *> *syllableStarts;   // the first unit of each syllable
@property (nonatomic) NSInteger timing;                            // Taurus's SGKaraokeTiming: 0 every word timed
@end
@implementation AUTLine
@end

static NSArray<NSString *> *composedUnits(NSString *text) {
    NSMutableArray *units = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *unit, NSRange range, NSRange enclosing, BOOL *stop) {
        if (unit.length) [units addObject:unit];
    }];
    return units;
}

static BOOL isCyrillicVowel(NSString *unit) {
    return unit.length && [@"АЕЁИОУЫЭЮЯІЇЄ" rangeOfString:[unit substringToIndex:1]].location != NSNotFound;
}

static BOOL isLatinVowel(NSString *unit) {
    return unit.length && [@"AEIOUYÀÁÂÄÈÉÊËÌÍÎÏÒÓÔÖÙÚÛÜ" rangeOfString:[unit substringToIndex:1]].location != NSNotFound;
}

static BOOL hasLetter(NSArray<NSString *> *word) {
    for (NSString *unit in word) {
        if ([unit rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL hasVowel(NSArray<NSString *> *word) {
    for (NSString *unit in word) {
        if (isCyrillicVowel(unit) || isLatinVowel(unit)) return YES;
    }
    return NO;
}

// A word's syllables, as the first letter of each: every Cyrillic vowel is one, a run of Latin vowels is one (a Latin
// Y before a vowel is a consonant), and the consonants between two are split down the middle, a soft or hard sign
// staying with the consonant before it. Exact enough for the voice to type by: only where the cuts fall changes.
static NSArray<NSNumber *> *syllablesOfWord(NSArray<NSString *> *w) {
    NSMutableArray<NSValue *> *nuclei = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < w.count) {
        if (isCyrillicVowel(w[i])) {
            [nuclei addObject:[NSValue valueWithRange:NSMakeRange(i, 1)]];
            i++;
            continue;
        }
        BOOL yBeforeVowel = [w[i] isEqualToString:@"Y"] && i + 1 < w.count && isLatinVowel(w[i + 1]);
        if (isLatinVowel(w[i]) && !yBeforeVowel) {
            NSUInteger j = i;
            while (j + 1 < w.count && isLatinVowel(w[j + 1]) && ![w[j + 1] isEqualToString:@"Y"]) j++;
            [nuclei addObject:[NSValue valueWithRange:NSMakeRange(i, j - i + 1)]];
            i = j + 1;
            continue;
        }
        i++;
    }
    NSMutableArray<NSNumber *> *starts = [NSMutableArray arrayWithObject:@0];
    for (NSUInteger k = 0; k + 1 < nuclei.count; k++) {
        NSRange a = nuclei[k].rangeValue, b = nuclei[k + 1].rangeValue;
        NSUInteger consonants = b.location - NSMaxRange(a);
        NSUInteger cut = NSMaxRange(a) + (consonants > 1 ? consonants / 2 : 0);
        while (cut < b.location && ([w[cut] isEqualToString:@"Ь"] || [w[cut] isEqualToString:@"Ъ"])) cut++;
        if (cut > starts.lastObject.unsignedIntegerValue) [starts addObject:@(cut)];
    }
    return starts;
}

// Taurus's SGKaraokeLine objects, read once per array.
static NSArray<AUTLine *> *typedLines(NSArray *lines) {
    NSLocale *locale = NSLocale.currentLocale;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableArray<AUTLine *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (id line in lines) {
        AUTLine *typed = [AUTLine new];
        typed.start = integerOf(line, @"start");
        typed.end = integerOf(line, @"end");
        typed.timing = integerOf(line, @"timing");
        id backing = nil;
        @try { backing = [line valueForKey:@"backing"]; } @catch (__unused NSException *e) {}
        if (backing) typed.end = MAX(typed.end, integerOf(backing, @"end"));
        NSArray *words = nil;
        @try { words = [line valueForKey:@"words"]; } @catch (__unused NSException *e) {}
        NSMutableArray<AUTUnit *> *units = [NSMutableArray array];
        NSMutableArray<NSMutableArray<AUTUnit *> *> *visualWords = [NSMutableArray array];
        NSInteger word = -1;
        for (id source in words) {
            NSString *text = nil;
            BOOL joined = NO;
            @try {
                text = [source valueForKey:@"text"];
                joined = [[source valueForKey:@"joined"] boolValue];
            } @catch (__unused NSException *e) {
                continue;
            }
            if (![text isKindOfClass:NSString.class]) continue;
            double start = integerOf(source, @"start"), end = MAX(start, (double)integerOf(source, @"end"));
            NSMutableArray<NSArray<NSString *> *> *pieces = [NSMutableArray array];
            NSUInteger total = 0;
            for (NSString *piece in [[text uppercaseStringWithLocale:locale] componentsSeparatedByCharactersInSet:space]) {
                if (!piece.length) continue;
                NSArray *letters = composedUnits(piece);
                [pieces addObject:letters];
                total += letters.count;
            }
            if (!total) continue;
            NSUInteger at = 0;
            for (NSUInteger p = 0; p < pieces.count; p++) {
                // A syllable joined to the word before carries it on; a space inside a word's text starts another.
                if (word < 0 || p > 0 || !joined) {
                    word++;
                    [visualWords addObject:[NSMutableArray array]];
                }
                for (NSString *letter in pieces[p]) {
                    AUTUnit *unit = [AUTUnit new];
                    unit.text = letter;
                    unit.wordStart = start;
                    unit.wordEnd = end;
                    unit.inWord = at++;
                    unit.wordLetters = total;
                    unit.word = (NSUInteger)word;
                    [units addObject:unit];
                    [visualWords.lastObject addObject:unit];
                }
            }
        }
        if (!units.count) continue;   // a break (♪) or an empty line: a clean page
        // The syllables over the whole line: punctuation (a dash) goes with the syllable before, a word with no
        // vowel (в, к, с) with the one after.
        NSMutableArray<NSNumber *> *syllableStarts = [NSMutableArray array];
        NSUInteger index = 0, carried = NSNotFound;
        for (NSArray<AUTUnit *> *visual in visualWords) {
            NSMutableArray<NSString *> *letters = [NSMutableArray array];
            for (AUTUnit *unit in visual) [letters addObject:unit.text];
            if (!hasLetter(letters) && syllableStarts.count) {
                index += visual.count;
                continue;
            }
            if (!hasVowel(letters) && hasLetter(letters)) {
                if (carried == NSNotFound) carried = index;
                index += visual.count;
                continue;
            }
            NSArray<NSNumber *> *starts = syllablesOfWord(letters);
            for (NSUInteger s = 0; s < starts.count; s++) {
                NSUInteger at = index + starts[s].unsignedIntegerValue;
                if (s == 0 && carried != NSNotFound) at = carried;
                if (s == 0 && !syllableStarts.count) at = 0;
                [syllableStarts addObject:@(at)];
            }
            carried = NSNotFound;
            index += visual.count;
        }
        if (!syllableStarts.count) [syllableStarts addObject:@0];
        else if (carried != NSNotFound && carried > syllableStarts.lastObject.unsignedIntegerValue) [syllableStarts addObject:@(carried)];
        NSUInteger s = 0;
        for (NSUInteger u = 0; u < units.count; u++) {
            while (s + 1 < syllableStarts.count && syllableStarts[s + 1].unsignedIntegerValue <= u) s++;
            units[u].syllable = s;
        }
        typed.start = MIN(typed.start, units.firstObject.wordStart);
        typed.units = units;
        typed.syllableStarts = syllableStarts;
        [out addObject:typed];
    }
    return out;
}

static NSString *lineKey(AUTLine *line) {
    return [NSString stringWithFormat:@"%.0f", line.start];
}

#pragma mark - the ear's memory: when each syllable was sung

@interface AUTTracker : NSObject
@property (nonatomic) CFTimeInterval lastViewTick;
@property (nonatomic, readonly) NSUInteger rememberedTracks;
+ (instancetype)shared;
// When each syllable of the line was sung, in song ms: remembered, or as far as it has been heard. nil: not heard.
- (nullable NSArray<NSNumber *> *)hitsForTrack:(NSString *)track line:(AUTLine *)line;
- (BOOL)remembers:(NSString *)track line:(AUTLine *)line;
// Syllables of the line now being heard that came from the voice (not from catching up).
- (NSUInteger)heardInTrack:(NSString *)track line:(AUTLine *)line;
- (void)tickTrack:(NSString *)track lines:(NSArray<AUTLine *> *)lines clock:(double)clock now:(CFTimeInterval)now;
- (void)forget;
@end

@implementation AUTTracker {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *> *_memory;
    NSMutableArray<NSString *> *_order;   // tracks, the least recently heard first
    BOOL _dirty;
    NSString *_track, *_lineKey;
    AUTLine *_line;
    NSMutableArray<NSNumber *> *_hits;
    NSUInteger _heard;      // syllables typed by a syllable heard, not by catching up
    BOOL _late;             // joined the line midway (a seek): not remembered
    double _lastClock;
    CFTimeInterval _lastNow;
}

+ (instancetype)shared {
    static AUTTracker *tracker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tracker = [AUTTracker new]; });
    return tracker;
}

static NSURL *memoryURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"Aura" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"type-timings.plist"];
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:memoryURL()];
    _memory = [NSMutableDictionary dictionary];
    _order = [NSMutableArray array];
    NSDictionary *tracks = [saved[@"tracks"] isKindOfClass:NSDictionary.class] ? saved[@"tracks"] : nil;
    for (NSString *track in saved[@"order"]) {
        NSDictionary *lines = tracks[track];
        if (![lines isKindOfClass:NSDictionary.class]) continue;
        _memory[track] = [lines mutableCopy];
        [_order addObject:track];
    }
    return self;
}

- (NSUInteger)rememberedTracks {
    return _memory.count;
}

- (void)forget {
    [_memory removeAllObjects];
    [_order removeAllObjects];
    [NSFileManager.defaultManager removeItemAtURL:memoryURL() error:nil];
    _hits = nil;
    _lineKey = nil;
    _line = nil;
}

- (void)saveSoon {
    if (_dirty) return;
    _dirty = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self->_dirty = NO;
        while (self->_order.count > 400) {
            [self->_memory removeObjectForKey:self->_order.firstObject];
            [self->_order removeObjectAtIndex:0];
        }
        NSDictionary *plist = @{@"order": [self->_order copy], @"tracks": [self->_memory copy]};
        [plist writeToURL:memoryURL() atomically:YES];
    });
}

- (BOOL)remembers:(NSString *)track line:(AUTLine *)line {
    return track.length && [_memory[track][lineKey(line)] count] == line.syllableStarts.count;
}

- (NSUInteger)heardInTrack:(NSString *)track line:(AUTLine *)line {
    return [track isEqualToString:_track] && [lineKey(line) isEqualToString:_lineKey] ? _heard : 0;
}

- (NSArray<NSNumber *> *)hitsForTrack:(NSString *)track line:(AUTLine *)line {
    if (!track.length) return nil;
    if ([self remembers:track line:line]) {
        NSArray<NSNumber *> *remembered = _memory[track][lineKey(line)];
        NSMutableArray *hits = [NSMutableArray arrayWithCapacity:remembered.count];
        for (NSNumber *offset in remembered) [hits addObject:@(line.start + offset.doubleValue)];
        return hits;
    }
    if ([track isEqualToString:_track] && [lineKey(line) isEqualToString:_lineKey]) return [_hits copy];
    return nil;
}

- (void)finishLine {
    NSUInteger n = _line.syllableStarts.count;
    if (_line && !_late && n >= 2 && _hits.count == n && _heard * 10 >= n * 6 && _track.length) {
        NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:n];
        for (NSNumber *hit in _hits) [offsets addObject:@(round(hit.doubleValue - _line.start))];
        NSMutableDictionary *lines = _memory[_track];
        if (!lines) _memory[_track] = lines = [NSMutableDictionary dictionary];
        lines[_lineKey] = offsets;
        [_order removeObject:_track];
        [_order addObject:_track];
        [self saveSoon];
    }
    _line = nil;
    _lineKey = nil;
    _hits = nil;
    _heard = 0;
    _late = NO;
}

- (void)hit:(NSUInteger)count at:(double)ms heard:(BOOL)heard {
    NSUInteger n = _line.syllableStarts.count;
    for (NSUInteger i = 0; i < count && _hits.count < n; i++) {
        double last = _hits.lastObject ? _hits.lastObject.doubleValue : -INFINITY;
        [_hits addObject:@(MAX(ms, last))];
        if (heard) _heard++;
    }
}

- (void)tickTrack:(NSString *)track lines:(NSArray<AUTLine *> *)lines clock:(double)clock now:(CFTimeInterval)now {
    CFTimeInterval heard[64];
    NSUInteger count = AUVoiceTakeOnsets(now, heard, 64);
    if (!track.length || !lines.count) return;
    if (![track isEqualToString:_track]) {
        [self finishLine];
        _track = [track copy];
        _lastNow = 0;
    }
    BOOL seeked = _lastNow > 0 && fabs((clock - _lastClock) - (now - _lastNow) * 1000) > 1500;
    _lastClock = clock;
    _lastNow = now;
    NSInteger index = -1;
    for (NSInteger i = 0; i < (NSInteger)lines.count && lines[(NSUInteger)i].start <= clock; i++) index = i;
    AUTLine *line = index >= 0 ? lines[(NSUInteger)index] : nil;
    NSString *key = line ? lineKey(line) : nil;
    if (seeked || !(key == _lineKey || [key isEqualToString:_lineKey])) {
        if (seeked) _late = YES;
        [self finishLine];
        if (!line) return;
        _line = line;
        _lineKey = key;
        _hits = [NSMutableArray array];
        _late = seeked || clock > line.start + 600;
    }
    if (!_line || [self remembers:track line:_line]) return;   // remembered: nothing to hear
    const AUTSettings *set = settings();
    if (!set->earWords && _line.timing == 0) return;   // the source times every word
    AUTLine *next = index + 1 < (NSInteger)lines.count ? lines[(NSUInteger)index + 1] : nil;
    double until = next ? next.start : MAX(_line.end, _line.start + 2000) + 500;
    double span = MAX(800, until - _line.start - 500);
    NSUInteger n = _line.syllableStarts.count;
    for (NSUInteger i = 0; i < count; i++) {
        double ms = clock - (now - heard[i]) * 1000 + set->offset;
        if (ms < _line.start - 250 || ms >= until - 250 || _hits.count >= n) continue;
        double expected = n * (ms - _line.start) / span;
        if (_hits.count + 1 > expected * 1.5 + 2) continue;   // far ahead of the line: an instrument
        NSUInteger step = _hits.count + 1 < expected - 1.5 ? 2 : 1;   // behind: two syllables sung as one rise
        [self hit:step at:MAX(ms, _line.start) heard:YES];
    }
    // Never far behind: two and a half syllables at most, the first one in a third of a second, all by the next line.
    double expected = n * (clock - _line.start) / span;
    NSInteger behind = (NSInteger)floor(expected - 2.5) - (NSInteger)_hits.count;
    if (behind > 0) [self hit:(NSUInteger)behind at:clock heard:NO];
    if (!_hits.count && clock >= _line.start + 350) [self hit:1 at:clock heard:NO];
    if (clock >= until - 250) [self hit:n at:clock heard:NO];
}

@end

#pragma mark - the letters on the page

@interface AUTGlyph : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic) CGPoint position, velocity;   // the em box's top left, in the page, and how it moves
@property (nonatomic) NSUInteger row, slot;         // its line on the page and its word's place in that line
@property (nonatomic) CGFloat base;                 // em from the line's left edge, the gaps before it not counted
@property (nonatomic) CGFloat advance;              // em
@property (nonatomic) CGFloat imageEm;              // the size its picture was drawn at
@property (nonatomic) CFTimeInterval shownAt;       // 0: in without the blur
@property (nonatomic) BOOL placed;
@end
@implementation AUTGlyph
@end

@interface AUTRow : NSObject
@property (nonatomic) NSUInteger first;
@property (nonatomic) CGFloat gap, target;   // em
@property (nonatomic) CGFloat widest;        // the widest gap that keeps the line inside, em
@end
@implementation AUTRow
@end

typedef struct {
    double rx, ry, rz, tx, ty, scale;
} AUTPose;

static double noise(uint64_t seed) {
    seed ^= seed >> 33;
    seed *= 0xff51afd7ed558ccdULL;
    seed ^= seed >> 33;
    seed *= 0xc4ceb9fe1a85ec53ULL;
    seed ^= seed >> 33;
    return (double)(seed >> 11) / (double)(1ULL << 53) * 2 - 1;
}

static AUTPose poseFor(uint64_t seed) {
    return (AUTPose){noise(seed * 7 + 1), noise(seed * 7 + 2), noise(seed * 7 + 3), noise(seed * 7 + 4),
                     noise(seed * 7 + 5), noise(seed * 7 + 6)};
}

static CGFloat screenScale(void) {
    return MAX(1, UIScreen.mainScreen.scale);
}

static const CGFloat kMeasureEm = 100;

@interface AUTypeView : UIView
@property (nonatomic, weak) UIView *karaoke;
- (void)wake;
- (void)tick:(CADisplayLink *)link;
@end

// A weak target for the display link, so the view can go when its window does.
@interface AUTTicker : NSObject
@property (nonatomic, weak) AUTypeView *owner;
@end
@implementation AUTTicker
- (void)tick:(CADisplayLink *)link {
    [self.owner tick:link];
}
@end

@implementation AUTypeView {
    CADisplayLink *_link;
    __weak NSArray *_sourceLines;
    NSArray<AUTLine *> *_lines;
    NSInteger _lineIndex;
    NSMutableArray<AUTGlyph *> *_glyphs;
    NSMutableArray<AUTRow *> *_rows;
    NSUInteger _revealed;
    CGSize _laidFor;
    double _laidSettings;
    CGFloat _em, _emVelocity, _targetEm, _side, _boxTop, _boxHeight;
    CALayer *_page, *_cursor;
    CFTimeInterval _lastTick, _lastReveal;
    BOOL _hidLines, _active;
    NSMutableDictionary<NSString *, NSArray *> *_measures;   // a word so far: its letters' offsets and width at 100 pt
    NSCache<NSString *, id> *_images;
    CGFloat _pageAlpha;
    UIColor *_textColor, *_glowColor;
    NSString *_colorKey;
    double _times[512];
    NSInteger _appliedFps;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    _lineIndex = -1;
    _glyphs = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _measures = [NSMutableDictionary dictionary];
    _images = [NSCache new];
    _images.countLimit = 400;
    _page = [CALayer layer];
    [self.layer addSublayer:_page];
    _cursor = [CALayer layer];
    _cursor.shadowOffset = CGSizeZero;
    _cursor.hidden = YES;
    [_page addSublayer:_cursor];
    _pageAlpha = 1;
    _textColor = _glowColor = UIColor.whiteColor;
    _colorKey = @"white";
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self wake];
}

- (void)wake {
    if (self.window && !_link) {
        AUTTicker *ticker = [AUTTicker new];
        ticker.owner = self;
        _link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(10, 60, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!self.window && _link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)dealloc {
    [_link invalidate];
}

// Taurus's own lines back, and this view out of the way.
- (void)standDown {
    if (_hidLines) {
        UIView *scroll = objectIvar(self.karaoke, "_scroll");
        scroll.alpha = 1;
        _hidLines = NO;
    }
    if (_active) {
        _active = NO;
        self.hidden = YES;
        [self clearPage];
        _lineIndex = -1;
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(4, 10, 10);
        _appliedFps = 0;
    }
}

- (void)clearPage {
    for (AUTGlyph *glyph in _glyphs) [glyph.layer removeFromSuperlayer];
    [_glyphs removeAllObjects];
    [_rows removeAllObjects];
    _revealed = 0;
    _cursor.hidden = YES;
    _em = _targetEm = 0;
    _emVelocity = 0;
}

// The cover's colour, lifted to a light tint: the letters a breath of it, the glow more.
- (void)followCover:(const AUTSettings *)set {
    AUPalette *palette = AUPipeline.shared.current.palette;
    NSString *key = [NSString stringWithFormat:@"%p|%.2f|%.2f", (__bridge void *)palette, set->tint, set->glow];
    if ([key isEqualToString:_colorKey]) return;
    _colorKey = key;
    UIColor *text = UIColor.whiteColor, *glow = UIColor.whiteColor;
    if (palette && !palette.gray && set->tint > 0.01) {
        AURGB accent = palette.accent;
        float h, s, v;
        AURGBToHSV(accent, &h, &s, &v);
        AURGB light = AUHSVToRGB(h, MIN(s, 0.55f), 1);
        AURGB white = {1, 1, 1};
        AURGB t = AURGBMix(white, light, (float)(set->tint * 0.30));
        AURGB g = AURGBMix(white, light, (float)set->tint);
        text = [UIColor colorWithRed:t.r green:t.g blue:t.b alpha:1];
        glow = [UIColor colorWithRed:g.r green:g.g blue:g.b alpha:1];
    }
    _textColor = text;
    _glowColor = glow;
    for (AUTGlyph *glyph in _glyphs) glyph.imageEm = 0;   // drawn again in the new colour
}

- (void)tick:(CADisplayLink *)link {
    const AUTSettings *set = settings();
    UIView *karaoke = self.karaoke;
    if (!karaoke || !set->on) return [self standDown];
    BOOL compact = boolIvar(karaoke, "_compact", NO), sample = boolIvar(karaoke, "_sample", NO);
    if (compact && !set->compact) return [self standDown];
    NSArray *source = objectIvar(karaoke, "_lines");
    double clock = 0;
    if (![source isKindOfClass:NSArray.class] || !source.count || boolIvar(karaoke, "_plain", YES) ||
        !boolIvar(karaoke, "_showing", NO) || !doubleIvar(karaoke, "_clock", &clock)) {
        return [self standDown];
    }
    if (source != _sourceLines) {
        _sourceLines = source;
        _lines = typedLines(source);
        [self clearPage];
        _lineIndex = -1;
        AULog(@"type: %lu lines of %lu typed (%@)", (unsigned long)_lines.count, (unsigned long)source.count,
              sample ? @"the Lyrics page's preview" : compact ? @"under the cover" : @"lyrics");
    }
    if (!_lines.count) return [self standDown];

    if (!_active) {
        _active = YES;
        self.hidden = NO;
        _appliedFps = 0;
    }
    if (_appliedFps != set->fps) {   // «Частота кадров»; 120 only where the app allows ProMotion
        _appliedFps = set->fps;
        float fps = (float)set->fps;
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
        else _link.preferredFramesPerSecond = set->fps;
    }
    UIView *scroll = objectIvar(karaoke, "_scroll");
    if (scroll) {
        if (scroll.alpha > 0) scroll.alpha = 0;
        [scroll.layer removeAnimationForKey:@"restyle"];   // Taurus's fade back in after a change of look
        _hidLines = YES;
    }

    CFTimeInterval now = CACurrentMediaTime();
    double dt = _lastTick > 0 ? MIN(0.1, MAX(0.001, now - _lastTick)) : 1.0 / 60;
    _lastTick = now;

    // The ear: this view is what it hears for while it shows (the background timer stands aside).
    NSString *track = sample ? nil : objectIvar(karaoke, "_track");
    if (![track isKindOfClass:NSString.class]) track = nil;
    BOOL ear = set->ear && track.length;
    AUTTracker *tracker = AUTTracker.shared;
    if (ear) {
        AUVoiceSetWanted(YES);
        tracker.lastViewTick = now;
        [tracker tickTrack:track lines:_lines clock:clock now:now];
    }

    // The line on the page: the last one begun.
    NSInteger index = -1;
    for (NSInteger i = 0; i < (NSInteger)_lines.count && _lines[(NSUInteger)i].start <= clock; i++) index = i;
    if (index != _lineIndex) {
        [self clearPage];
        _lineIndex = index;
    }
    if (index < 0) return;
    AUTLine *line = _lines[(NSUInteger)index];
    AUTLine *next = index + 1 < (NSInteger)_lines.count ? _lines[(NSUInteger)index + 1] : nil;
    BOOL fading = clock > line.end + set->hold * 1000 && (!next || next.start - clock > 1500);
    _pageAlpha += ((fading ? 0 : 1) - _pageAlpha) * (1 - exp(-dt / 0.25));
    [self followCover:set];

    // When each letter is typed: by the voice where it is heard (or remembered), else by the source's words.
    NSUInteger count = MIN(line.units.count, (NSUInteger)512);
    NSArray<NSNumber *> *hits = nil;
    // By ear where the line is remembered, or the voice is heard now, or was heard in this line (a pause keeps it).
    if (ear && (set->earWords || line.timing != 0) &&
        ([tracker remembers:track line:line] || AUVoiceHearing() || [tracker heardInTrack:track line:line] > 0)) {
        hits = [tracker hitsForTrack:track line:line];
    }
    for (NSUInteger u = 0; u < count; u++) {
        AUTUnit *unit = line.units[u];
        if (hits) {
            NSUInteger s = unit.syllable;
            if (s >= hits.count) {
                _times[u] = INFINITY;
                continue;
            }
            NSUInteger first = line.syllableStarts[s].unsignedIntegerValue;
            NSUInteger last = s + 1 < line.syllableStarts.count ? line.syllableStarts[s + 1].unsignedIntegerValue : count;
            double per = MIN(set->speed, 220.0 / MAX(1, last - first));
            _times[u] = hits[s].doubleValue + per * (u - first);
        } else {
            double per = MIN((unit.wordEnd - unit.wordStart) / MAX(1, unit.wordLetters), set->speed);
            _times[u] = unit.wordStart + per * unit.inWord;
        }
        if (u > 0) _times[u] = MAX(_times[u], _times[u - 1]);
    }
    NSUInteger revealed = 0;
    while (revealed < count && _times[revealed] <= clock) revealed++;
    double signature = set->size * 7 + set->width * 13 + set->pitch * 17 + set->lift * 19;
    BOOL relayout = !CGSizeEqualToSize(_laidFor, self.bounds.size) || signature != _laidSettings;
    if (revealed != _revealed || relayout) {
        NSUInteger added = revealed > _revealed ? revealed - _revealed : 0;
        if (signature != _laidSettings) {
            [_measures removeAllObjects];
            for (AUTGlyph *glyph in _glyphs) glyph.imageEm = 0;
        }
        _laidSettings = signature;
        [self reveal:revealed of:line together:added];
        if (added) _lastReveal = now;
    }
    [self animate:dt now:now line:line next:next clock:clock];
}

// The letters typed so far laid out again: the size that fits, the words wrapped; the gaps open out in -animate.
- (void)reveal:(NSUInteger)count of:(AUTLine *)line together:(NSUInteger)added {
    const AUTSettings *set = settings();
    while (_glyphs.count > count) {
        [_glyphs.lastObject.layer removeFromSuperlayer];
        [_glyphs removeLastObject];
    }
    _revealed = count;
    _laidFor = self.bounds.size;
    if (!count) {
        _cursor.hidden = YES;
        [_rows removeAllObjects];
        return;
    }
    NSMutableArray<NSMutableString *> *words = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber *> *> *members = [NSMutableArray array];
    NSUInteger lastWord = NSUIntegerMax;
    for (NSUInteger i = 0; i < count; i++) {
        AUTUnit *unit = line.units[i];
        if (unit.word != lastWord) {
            [words addObject:[NSMutableString string]];
            [members addObject:[NSMutableArray array]];
            lastWord = unit.word;
        }
        [words.lastObject appendString:unit.text];
        [members.lastObject addObject:@(i)];
    }
    NSMutableArray<NSArray *> *measured = [NSMutableArray arrayWithCapacity:words.count];
    for (NSUInteger w = 0; w < words.count; w++) [measured addObject:[self measure:words[w] units:members[w].count]];

    // The room: Taurus's band for its lines, a box centred in it.
    CGRect bounds = self.bounds;
    UIEdgeInsets insets = UIEdgeInsetsZero;
    UIView *karaoke = self.karaoke;
    if ([karaoke respondsToSelector:@selector(lineInsets)]) {
        insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(karaoke, @selector(lineInsets));
    }
    CGFloat side = MAX(bounds.size.width * kMargin, MAX(insets.left, insets.right));
    CGFloat width = MAX(40, bounds.size.width - 2 * side);
    CGFloat bandTop = insets.top, bandHeight = MAX(40, bounds.size.height - insets.top - insets.bottom);
    CGFloat boxHeight = MIN(bounds.size.width * kBoxHeight * set->size, bandHeight * 0.92);
    CGFloat boxTop = bandTop + (bandHeight - boxHeight) / 2 - set->lift * bandHeight;
    boxTop = MAX(bandTop, MIN(boxTop, bandTop + bandHeight - boxHeight));
    CGFloat em = MIN(bounds.size.width * kMaxEm * set->size, boxHeight / set->pitch);

    NSArray<NSArray<NSNumber *> *> *rows = nil;
    for (int tries = 0; tries < 80; tries++, em *= 0.97) {
        rows = [self wrap:measured em:em width:width];
        CGFloat widest = 0;
        for (NSArray *m in measured) widest = MAX(widest, [m[1] doubleValue] * em / kMeasureEm);
        if (rows.count * set->pitch * em <= boxHeight + 0.5 && widest <= width + 0.5) break;
        if (em < 9) break;
    }
    _targetEm = em;
    if (_em <= 0) _em = em;
    _side = side;
    _boxTop = boxTop;
    _boxHeight = boxHeight;

    NSMutableArray<AUTRow *> *newRows = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray<NSNumber *> *row = rows[r];
        CGFloat total = 0;
        for (NSNumber *w in row) total += [measured[w.unsignedIntegerValue][1] doubleValue] / kMeasureEm;
        BOOL last = r + 1 == rows.count;
        AUTRow *state = [AUTRow new];
        state.first = members[row.firstObject.unsignedIntegerValue].firstObject.unsignedIntegerValue;
        state.widest = row.count < 2 ? kSpace : MAX(0, (width / em - total) / (row.count - 1));
        state.target = last || row.count < 2 ? MIN(kSpace, state.widest) : MAX(MIN(kSpace, state.widest), state.widest);
        AUTRow *old = r < _rows.count ? _rows[r] : nil;
        // A line just formed starts tight; gaps open out slowly but close at once (a word moved up must fit).
        state.gap = MIN(old && old.first == state.first ? old.gap : kSpace, state.widest);
        [newRows addObject:state];
        CGFloat base = 0;
        for (NSUInteger slot = 0; slot < row.count; slot++) {
            NSUInteger wi = row[slot].unsignedIntegerValue;
            NSArray<NSNumber *> *offsets = measured[wi][0];
            CGFloat wordWidth = [measured[wi][1] doubleValue];
            NSArray<NSNumber *> *ids = members[wi];
            for (NSUInteger k = 0; k < ids.count; k++) {
                NSUInteger i = ids[k].unsignedIntegerValue;
                AUTGlyph *glyph = i < _glyphs.count ? _glyphs[i] : nil;
                if (!glyph) {
                    glyph = [AUTGlyph new];
                    glyph.layer = [CALayer layer];
                    glyph.layer.contentsGravity = kCAGravityResize;
                    glyph.layer.contentsScale = screenScale();
                    [_page insertSublayer:glyph.layer below:_cursor];
                    glyph.shownAt = added <= kTogetherMost && set->appear > 0.005 ? CACurrentMediaTime() : 0;
                    [_glyphs addObject:glyph];
                }
                CGFloat offset = offsets[k].doubleValue;
                CGFloat after = k + 1 < offsets.count ? offsets[k + 1].doubleValue : wordWidth;
                glyph.advance = (after - offset) / kMeasureEm;
                glyph.row = r;
                glyph.slot = slot;
                glyph.base = base + offset / kMeasureEm;
            }
            base += wordWidth / kMeasureEm;
        }
    }
    _rows = newRows;
    for (AUTGlyph *glyph in _glyphs) {
        if (glyph.placed) continue;
        glyph.position = [self targetOf:glyph em:_em];   // a new letter is typed where it belongs; only the others move
        glyph.velocity = CGPointZero;
        glyph.placed = YES;
    }
}

- (CGPoint)targetOf:(AUTGlyph *)glyph em:(CGFloat)em {
    AUTRow *row = glyph.row < _rows.count ? _rows[glyph.row] : nil;
    CGFloat gap = row ? row.gap : kSpace;
    return CGPointMake(_side + em * (glyph.base + glyph.slot * gap), _boxTop + glyph.row * settings()->pitch * em);
}

// A word's letters' offsets and its width at 100 pt, with the font's kerning.
- (NSArray *)measure:(NSString *)word units:(NSUInteger)units {
    NSArray *kept = _measures[word];
    if (kept) return kept;
    if (_measures.count > 512) [_measures removeAllObjects];
    CTFontRef font = AUTypeFont(kMeasureEm);
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray arrayWithCapacity:units];
    CGFloat width = 0;
    if (font) {
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:word attributes:@{(id)kCTFontAttributeName: (__bridge id)font}];
        CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)string);
        [word enumerateSubstringsInRange:NSMakeRange(0, word.length) options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *unit, NSRange range, NSRange enclosing, BOOL *stop) {
            [offsets addObject:@(CTLineGetOffsetForStringIndex(ctLine, (CFIndex)range.location, NULL))];
        }];
        width = CTLineGetTypographicBounds(ctLine, NULL, NULL, NULL);
        CFRelease(ctLine);
    }
    while (offsets.count < units) [offsets addObject:@(width)];
    NSArray *measure = @[offsets, @(width)];
    _measures[word] = measure;
    return measure;
}

- (NSArray<NSArray<NSNumber *> *> *)wrap:(NSArray<NSArray *> *)measured em:(CGFloat)em width:(CGFloat)width {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *row = [NSMutableArray array];
    CGFloat used = 0;
    for (NSUInteger w = 0; w < measured.count; w++) {
        CGFloat wordWidth = [measured[w][1] doubleValue] * em / kMeasureEm;
        CGFloat need = row.count ? used + kSpace * em + wordWidth : wordWidth;
        if (row.count && need > width + 0.5) {
            [rows addObject:row];
            row = [NSMutableArray arrayWithObject:@(w)];
            used = wordWidth;
        } else {
            [row addObject:@(w)];
            used = need;
        }
    }
    if (row.count) [rows addObject:row];
    return rows;
}

// The letter's picture: its colour, the glow drawn in, room around it for the glow.
- (UIImage *)imageFor:(NSString *)text em:(CGFloat)em {
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%.2f|%@", text, em, settings()->width, _colorKey];
    UIImage *kept = [_images objectForKey:key];
    if (kept) return kept;
    CTFontRef font = AUTypeFont(em);
    if (!font) return nil;
    NSDictionary *attributes = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorFromContextAttributeName: @YES};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)string);
    CGFloat ascent = 0;
    CGFloat advance = CTLineGetTypographicBounds(ctLine, &ascent, NULL, NULL);
    CGFloat pad = ceil(em * 0.3);
    CGSize size = CGSizeMake(ceil(advance + 2 * pad), ceil(em * 1.25 + 2 * pad));
    CGFloat glow = settings()->glow;
    UIColor *textColor = _textColor, *glowColor = _glowColor;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextTranslateCTM(cg, 0, size.height);
        CGContextScaleCTM(cg, 1, -1);
        CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
        CGContextSetFillColorWithColor(cg, textColor.CGColor);
        if (glow > 0.01) CGContextSetShadowWithColor(cg, CGSizeZero, em * 0.12, [glowColor colorWithAlphaComponent:glow].CGColor);
        CGContextSetTextPosition(cg, pad, size.height - pad - ascent);
        CTLineDraw(ctLine, cg);
    }];
    CFRelease(ctLine);
    [_images setObject:image forKey:key];
    return image;
}

static NSArray *blurFilter(CGFloat radius) {
    static Class filterClass;
    if (!filterClass) filterClass = NSClassFromString(@"CAFilter");
    if (!filterClass || radius < 0.3) return nil;
    id filter = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
    if (!filter) return nil;
    [filter setValue:@(round(radius * 2) / 2) forKey:@"inputRadius"];
    return @[filter];
}

// A stiff spring with a little overshoot: the reference's hard, quick moves.
static void spring(CGFloat *value, CGFloat *velocity, CGFloat target, double dt, double omega, double zeta) {
    const double h = 1.0 / 240;
    for (double done = 0; done < dt - 1e-6; done += h) {
        double step = MIN(h, dt - done);
        double a = omega * omega * (target - *value) - 2 * zeta * omega * *velocity;
        *velocity += a * step;
        *value += *velocity * step;
    }
}

// The lens: further from the middle, a little further out and a little bigger (the reference's letters at the edges).
static CGPoint lens(CGPoint point, CGPoint centre, double radius, double k, double *scale) {
    double dx = (point.x - centre.x) / radius, dy = (point.y - centre.y) / radius, r2 = dx * dx + dy * dy;
    double grow = 1 + k * r2;
    *scale = MIN(1.6, MAX(0.6, 1 + 2 * k * r2));
    return CGPointMake(centre.x + (point.x - centre.x) * grow, centre.y + (point.y - centre.y) * grow);
}

- (void)animate:(double)dt now:(CFTimeInterval)now line:(AUTLine *)line next:(AUTLine *)next clock:(double)clock {
    const AUTSettings *set = settings();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect bounds = self.bounds;
    CGFloat W = MAX(1, bounds.size.width);
    _page.bounds = bounds;
    _page.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    _page.opacity = (float)_pageAlpha;

    // The page's float: a pose of its own for each line, drifting to another over the line, cut with the next.
    double until = next ? next.start : line.end + 2000;
    double u = MIN(1, MAX(0, (clock - line.start) / MAX(500, until - line.start)));
    u = u * u * (3 - 2 * u);
    uint64_t seed = (uint64_t)MAX(0, _lineIndex) * 2;
    AUTPose a = poseFor(seed + 11), b = poseFor(seed + 12);
    double m = set->motion;
    double rx = (a.rx + (b.rx - a.rx) * u) * 5 * M_PI / 180 * m, ry = (a.ry + (b.ry - a.ry) * u) * 7 * M_PI / 180 * m;
    double rz = (a.rz + (b.rz - a.rz) * u) * 1.8 * M_PI / 180 * m;
    double tx = (a.tx + (b.tx - a.tx) * u) * 0.012 * W * m, ty = (a.ty + (b.ty - a.ty) * u) * 0.01 * W * m;
    double sc = 1 + (a.scale + (b.scale - a.scale) * u) * 0.02 * m;
    CATransform3D pose = CATransform3DIdentity;
    pose.m34 = -1.0 / (2.2 * W);
    pose = CATransform3DTranslate(pose, tx, ty, 0);
    pose = CATransform3DRotate(pose, rz, 0, 0, 1);
    pose = CATransform3DRotate(pose, ry, 0, 1, 0);
    pose = CATransform3DRotate(pose, rx, 1, 0, 0);
    pose = CATransform3DScale(pose, sc, sc, 1);
    _page.transform = pose;

    // Hard moves: the spring's speed and damping from «Резкость».
    double omega = 2 * M_PI * (3.5 + 13 * set->snap), zeta = 0.95 - 0.4 * set->snap;
    if (_targetEm > 0) {
        spring(&_em, &_emVelocity, _targetEm, dt, omega, MIN(1, zeta + 0.2));
        if (fabs(_targetEm - _em) < 0.05 && fabs(_emVelocity) < 1) {
            _em = _targetEm;
            _emVelocity = 0;
        }
        _em = MAX(_em, 4);
    }
    // The gaps of a justified line open out slowly.
    double gapStep = set->gaps > 0.01 ? 1 - exp(-dt / (set->gaps / 2.3)) : 1;
    for (AUTRow *row in _rows) {
        if (row.target < row.gap) row.gap = row.target;
        row.gap += (row.target - row.gap) * gapStep;
        row.gap = MIN(row.gap, row.widest);
        if (fabs(row.target - row.gap) < 0.002) row.gap = row.target;
    }
    BOOL sizeSettled = _targetEm > 0 && fabs(_em - _targetEm) / _targetEm < 0.01;
    CGFloat scale = screenScale();
    CGPoint centre = CGPointMake(CGRectGetMidX(bounds), _boxTop + _boxHeight / 2);
    double k = kLensK * set->lens, radius = W / 2;
    for (NSUInteger i = 0; i < _glyphs.count; i++) {
        AUTGlyph *glyph = _glyphs[i];
        CALayer *layer = glyph.layer;
        if (!glyph.imageEm || (sizeSettled && fabs(glyph.imageEm - _targetEm) / _targetEm > 0.03)) {
            UIImage *image = [self imageFor:line.units[i].text em:_targetEm];
            layer.contents = (id)image.CGImage;
            layer.contentsScale = image.scale ?: scale;
            glyph.imageEm = _targetEm;
        }
        CGPoint p = glyph.position, v = glyph.velocity, t = [self targetOf:glyph em:_em];
        spring(&p.x, &v.x, t.x, dt, omega, zeta);
        spring(&p.y, &v.y, t.y, dt, omega, zeta);
        if (fabs(t.x - p.x) < 0.2 && fabs(t.y - p.y) < 0.2 && fabs(v.x) + fabs(v.y) < 4) {
            p = t;
            v = CGPointZero;
        }
        glyph.position = p;
        glyph.velocity = v;
        CGFloat s = _em / MAX(1, glyph.imageEm);
        CGFloat pad = ceil(glyph.imageEm * 0.3);
        id contents = layer.contents;
        CGSize picture = contents ? CGSizeMake(CGImageGetWidth((CGImageRef)contents) / layer.contentsScale,
                                               CGImageGetHeight((CGImageRef)contents) / layer.contentsScale) : CGSizeZero;
        CGSize size = CGSizeMake(picture.width * s, picture.height * s);
        double lensScale = 1;
        CGPoint middle = lens(CGPointMake(p.x - pad * s + size.width / 2, p.y - pad * s + size.height / 2), centre, radius, k, &lensScale);
        // The blur-in: faint, wide and soft, then sharp in its place.
        double e = 1;
        if (glyph.shownAt > 0) {
            double progress = MIN(1, MAX(0, (now - glyph.shownAt) / MAX(0.01, set->appear)));
            e = 1 - (1 - progress) * (1 - progress);
            if (progress >= 1) glyph.shownAt = 0;
        }
        double smear = 0.25 * (1 - e);
        layer.bounds = CGRectMake(0, 0, size.width, size.height);
        layer.position = CGPointMake(round((middle.x + size.width * lensScale * smear / 2) * scale) / scale, round(middle.y * scale) / scale);
        layer.transform = CATransform3DMakeScale(lensScale * (1 + smear), lensScale, 1);
        if (e < 1) {
            layer.opacity = (float)(0.45 + 0.55 * e);
            layer.filters = blurFilter((1 - e) * 0.10 * _em);
        } else if (layer.filters || layer.opacity < 1) {
            layer.opacity = 1;
            layer.filters = nil;
        }
    }
    // The cursor, a hair after the last letter typed; it blinks once the typing stops.
    AUTGlyph *last = _glyphs.lastObject;
    if (last && set->cursor) {
        double idle = now - _lastReveal;
        BOOL on = idle < 0.35 || fmod(idle - 0.35, kBlink) < kBlink * 0.55;
        CGFloat width = MAX(1.5, _em * 0.035), height = _em * kCapHeight;
        double lensScale = 1;
        CGPoint middle = lens(CGPointMake(last.position.x + (last.advance + 0.05) * _em + width / 2,
                                          last.position.y + (kCapTop - 0.02) * _em + height / 2), centre, radius, k, &lensScale);
        _cursor.hidden = !on;
        _cursor.bounds = CGRectMake(0, 0, width, height * lensScale);
        _cursor.position = middle;
        _cursor.cornerRadius = width / 2;
        _cursor.backgroundColor = _textColor.CGColor;
        _cursor.shadowColor = _glowColor.CGColor;
        _cursor.shadowRadius = _em * 0.08;
        _cursor.shadowOpacity = (float)set->glow;
        _cursor.shadowPath = [UIBezierPath bezierPathWithRect:_cursor.bounds].CGPath;
    } else {
        _cursor.hidden = YES;
    }
    [CATransaction commit];
}

@end

#pragma mark - into Taurus

static char kTypeKey;

void AUTypeLyricsKaraokeLaidOut(UIView *karaoke) {
    AUTypeView *view = objc_getAssociatedObject(karaoke, &kTypeKey);
    if (!view) {
        if (!settings()->on) return;
        view = [[AUTypeView alloc] initWithFrame:karaoke.bounds];
        view.karaoke = karaoke;
        objc_setAssociatedObject(karaoke, &kTypeKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AULog(@"type: joined a lyrics view %@ (%.0f×%.0f)", NSStringFromClass(karaoke.class), karaoke.bounds.size.width, karaoke.bounds.size.height);
    }
    UIView *scroll = objectIvar(karaoke, "_scroll");
    if (view.superview != karaoke) {
        if (scroll.superview == karaoke) [karaoke insertSubview:view aboveSubview:scroll];
        else [karaoke addSubview:view];
    } else if (scroll.superview == karaoke) {
        NSUInteger mine = [karaoke.subviews indexOfObjectIdenticalTo:view], theirs = [karaoke.subviews indexOfObjectIdenticalTo:scroll];
        if (mine < theirs) [karaoke insertSubview:view aboveSubview:scroll];
    }
    if (!CGRectEqualToRect(view.frame, karaoke.bounds)) view.frame = karaoke.bounds;
    [view wake];
}

void AUTypeLyricsWriteOutSwitches(void);

#pragma mark - the background ear

// While no lyrics are on screen the playing song is still heard and its lines remembered, from Taurus's own lines.
static void listenInBackground(void) {
    const AUTSettings *set = settings();
    AUTTracker *tracker = AUTTracker.shared;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL viewing = now - tracker.lastViewTick < 0.3;
    BOOL wanted = set->on && set->ear && (set->learn || viewing);
    if (!wanted || viewing) {
        if (!viewing) AUVoiceSetWanted(NO);
        return;
    }
    NSString *(*playing)(void) = (NSString *(*)(void))taurus("SGKaraokePlayingTrack");
    NSArray *(*linesFor)(NSString *) = (NSArray *(*)(NSString *))taurus("SGKaraokeLinesForTrack");
    NSInteger (*position)(void) = (NSInteger (*)(void))taurus("SGKaraokePositionMs");
    if (!playing || !linesFor || !position) {
        AUVoiceSetWanted(NO);
        return;
    }
    NSString *track = playing();
    NSArray *lines = track ? linesFor(track) : nil;
    NSInteger ms = position();
    static __weak NSArray *typedFrom;
    static NSArray<AUTLine *> *typed;
    if (lines != typedFrom) {
        typedFrom = lines;
        typed = lines.count ? typedLines(lines) : nil;
    }
    BOOL listening = typed.count > 0 && ms >= 0;
    AUVoiceSetWanted(listening);
    if (listening) [tracker tickTrack:track lines:typed clock:(double)ms now:now];
}

void AUTypeLyricsStart(void) {
    static NSTimer *timer;
    if (timer) return;
    AUTypeLyricsWriteOutSwitches();
    timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { listenInBackground(); }];
    timer.tolerance = 0.01;
}

#pragma mark - settings

static void addRow(NSMutableArray *rows, id row) {
    if (row) [rows addObject:row];
}

static void addSlider(NSMutableArray *rows, NSString *title, NSString *subtitle, NSString *key, double low, double high,
                      double step, double fallback, NSString *format, double multiplier, NSString *waitsOn) {
    SGModRow *slider = AURowSlider(title, subtitle, low, high, step, ^double { return AUNumber(key, fallback); },
                                   ^(double value) { AUSetNumber(key, value); },
                                   ^NSString *(double value) { return [NSString stringWithFormat:format, value * multiplier]; });
    slider.waitsOn = waitsOn;
    addRow(rows, slider);
}

static UIViewController *typePage(void) {
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *where = [NSMutableArray array];
    SGModRow *compact = AURowSwitch(@"В тексте под обложкой", @"Маленькое превью текста в плеере тоже печатается", AUKeyTypeLyricsCompact);
    compact.waitsOn = AUKeyTypeLyrics;
    addRow(where, compact);
    SGModRow *cursor = AURowSwitch(@"Курсор", @"Тонкая черта за последней буквой, мигает в паузах", AUKeyTypeLyricsCursor);
    cursor.waitsOn = AUKeyTypeLyrics;
    addRow(where, cursor);
    addRow(sections, AUSection(@"Где", where, nil));

    NSMutableArray *look = [NSMutableArray array];
    addSlider(look, @"Размер", nil, AUKeyTypeLyricsSize, 0.5, 1.5, 0.05, 1.0, @"×%.2f", 1, AUKeyTypeLyrics);
    addSlider(look, @"Ширина букв", @"Как в видео — 80%", AUKeyTypeLyricsWidth, 0.6, 1.0, 0.02, 0.80, @"%.0f%%", 100, AUKeyTypeLyrics);
    addSlider(look, @"Межстрочный интервал", nil, AUKeyTypeLyricsPitch, 0.8, 1.3, 0.01, 0.95, @"%.2f em", 1, AUKeyTypeLyrics);
    addSlider(look, @"Высота на экране", @"Выше или ниже середины", AUKeyTypeLyricsLift, -0.3, 0.3, 0.01, 0, @"%+.0f%%", 100, AUKeyTypeLyrics);
    addSlider(look, @"Свечение", nil, AUKeyTypeLyricsGlow, 0, 1, 0.05, 0.35, @"%.0f%%", 100, AUKeyTypeLyrics);
    addSlider(look, @"Цвет под обложку", @"0 — чисто белый; свечение красится сильнее букв", AUKeyTypeLyricsTint, 0, 1, 0.05, 0.5, @"%.0f%%", 100, AUKeyTypeLyrics);
    addRow(sections, AUSection(@"Вид", look, nil));

    NSMutableArray *motion = [NSMutableArray array];
    SGModRow *fps = AURowChoice(@"Частота кадров", @"Анимации текста; 120 — только на ProMotion и если Spotify её разрешает", AUKeyTypeLyricsFPS, @[@"24", @"30", @"60", @"120"], 2);
    fps.waitsOn = AUKeyTypeLyrics;
    addRow(motion, AURowSymbol(fps, @"speedometer"));
    addSlider(motion, @"Резкость", @"Как быстро и жёстко буквы прыгают на новое место", AUKeyTypeLyricsSnap, 0, 1, 0.05, 0.75, @"%.0f%%", 100, AUKeyTypeLyrics);
    addSlider(motion, @"Растяжка пробелов", @"За сколько раздвигаются пробелы строки, ставшей по ширине", AUKeyTypeLyricsGaps, 0, 2, 0.05, 0.8, @"%.2f с", 1, AUKeyTypeLyrics);
    addSlider(motion, @"Проявление буквы", @"Сколько новая буква выходит из размытия", AUKeyTypeLyricsAppear, 0, 0.4, 0.01, 0.11, @"%.0f мс", 1000, AUKeyTypeLyrics);
    addSlider(motion, @"Скорость печати", @"Не медленнее стольких мс на букву", AUKeyTypeLyricsSpeed, 15, 150, 5, 60, @"%.0f мс", 1, AUKeyTypeLyrics);
    addSlider(motion, @"Плавание в 3D", @"Наклон и дрейф страницы, у каждой строки свой", AUKeyTypeLyricsMotion, 0, 2, 0.05, 1.0, @"×%.2f", 1, AUKeyTypeLyrics);
    addSlider(motion, @"Линза", @"Буквы у краёв крупнее, строки выгнуты (минус — наоборот)", AUKeyTypeLyricsLens, -1, 2, 0.05, 1.0, @"×%.2f", 1, AUKeyTypeLyrics);
    addSlider(motion, @"Держать строку", @"Сколько спетая строка стоит, если следующая не скоро", AUKeyTypeLyricsHold, 0.5, 15, 0.5, 2.5, @"%.1f с", 1, AUKeyTypeLyrics);
    addRow(sections, AUSection(@"Движение", motion, nil));

    NSMutableArray *ear = [NSMutableArray array];
    SGModRow *byEar = AURowSwitch(@"Тайминг на слух", @"Слоги слышатся в самом треке, каждый печатает следующий слог строки", AUKeyTypeLyricsEar);
    byEar.waitsOn = AUKeyTypeLyrics;
    addRow(ear, AURowSymbol(byEar, @"waveform"));
    SGModRow *learn = AURowSwitch(@"Учиться в фоне", @"Слушать и запоминать строки, даже когда текст не открыт", AUKeyTypeLyricsLearn);
    learn.waitsOn = AUKeyTypeLyricsEar;
    addRow(ear, learn);
    SGModRow *words = AURowOption(@"Даже при пословном тайминге", @"Обычно, если источник сам знает время каждого слова, берётся оно", AUKeyTypeLyricsEarWords);
    words.waitsOn = AUKeyTypeLyricsEar;
    addRow(ear, words);
    addSlider(ear, @"Чувствительность", @"Больше — слышит больше слогов (и шума)", AUKeyTypeLyricsSensitivity, 0.5, 2, 0.05, 1.0, @"×%.2f", 1, AUKeyTypeLyricsEar);
    addSlider(ear, @"Сдвиг", @"Если буквы стабильно спешат (минус) или опаздывают", AUKeyTypeLyricsOffset, -400, 400, 10, 0, @"%+.0f мс", 1, AUKeyTypeLyricsEar);
    addRow(ear, AURowStat(@"Услышано", ^NSString *{
        return [NSString stringWithFormat:@"%llu слогов · %@ · запомнено треков: %lu", AUVoiceOnsetCount(),
                AUVoiceHearing() ? @"слушает" : AUVoiceInstalled() ? @"тишина" : @"звук не подключён",
                (unsigned long)AUTTracker.shared.rememberedTracks];
    }));
    SGModRow *forget = AURowAction(@"Забыть тайминги", @"Все запомненные строки услышатся заново", ^{ [AUTTracker.shared forget]; });
    forget.color = UIColor.systemRedColor;
    addRow(ear, forget);
    addRow(sections, AUSection(@"На слух", ear, @"Звук только читается для анализа, в нём ничего не меняется. Анализ — около 100 маленьких FFT в секунду на отдельной очереди, пока открыт текст или включено «Учиться в фоне». Строка, прослушанная целиком, запоминается для трека: в следующий раз печатается точно, и с перемоткой тоже."));
    return AUMakePage(@"Печатная машинка", @"Текст песни как в лирик-видео.", sections,
                      @"Шрифт Gagalin © Iordanis Passas (бесплатный), очищен от текстуры.");
}

// Taurus dims and locks a row whose waitsOn key is unset (SGFlag reads unset as off), while Aura's switches are on
// until switched off: the keys rows wait on are written out as they stand.
static void writeOut(NSString *key) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if (![store objectForKey:key]) [store setBool:YES forKey:key];
}

void AUTypeLyricsWriteOutSwitches(void) {
    writeOut(AUKeyTypeLyrics);
    writeOut(AUKeyTypeLyricsEar);
    writeOut(AUKeyTheme);
}

NSArray *AUTypeLyricsRows(void) {
    AUTypeLyricsWriteOutSwitches();
    NSMutableArray *rows = [NSMutableArray array];
    SGModRow *on = AURowSwitch(@"Печатная машинка", @"Строка печатается по буквам в такт голосу: Gagalin, курсор, буквы из размытия, текст по ширине", AUKeyTypeLyrics);
    on.changed = ^(BOOL value) { AUSettingsChanged(); };
    addRow(rows, AURowSymbol(on, @"character.cursor.ibeam"));
    SGModRow *page = AURowPage(@"Настройки машинки", ^UIViewController *{ return typePage(); });
    page.waitsOn = AUKeyTypeLyrics;
    addRow(rows, AURowSymbol(page, @"slider.horizontal.3"));
    return rows;
}
