#import "AUTypeLyrics.h"
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"

extern const unsigned char AUGagalinOTF[];
extern const size_t AUGagalinOTF_len;

// The look, matched frame by frame against the reference video (a 772 px wide frame): sizes are shares of the view's
// width, the line pitch and the gaps are in em.
static const CGFloat kMargin = 0.045;    // each side
static const CGFloat kMaxEm = 0.19;      // the largest size, a few words on a line
static const CGFloat kBoxHeight = 0.56;  // the room the text must fit in; past it the text shrinks
static const CGFloat kPitch = 0.95;      // from one line to the next
static const CGFloat kSpace = 0.26;      // the least gap between two words
static const CGFloat kNarrow = 0.80;     // the letters' width
static const CGFloat kCapTop = 0.335;    // from the top of the em box down to the capitals (ascent 1.005 − cap 0.70 + a hair)
static const CGFloat kCapHeight = 0.74;  // the cursor's height
static const double kMoveTau = 0.035;    // s: a letter slides to a new place
static const double kSizeTau = 0.05;     // s: the size follows a new fit
static const double kAppear = 0.11;      // s: a new letter's blur-in
static const double kLetterMostMs = 90;  // a word types no slower than this a letter, however long it is held
static const double kBlink = 1.0;        // s: the idle cursor's period
static const double kFadeAfterMs = 2500; // a line stays this long after it is sung, when the next is still far off
static const NSUInteger kTogetherMost = 3;   // more letters than this at once (a seek): they come in without the blur

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
    static NSMutableDictionary<NSNumber *, id> *fonts;
    if (!fonts) fonts = [NSMutableDictionary dictionary];
    size = MAX(4, round(size * 4) / 4);
    id kept = fonts[@(size)];
    if (kept) return (__bridge CTFontRef)kept;
    if (fonts.count > 96) [fonts removeAllObjects];
    CGAffineTransform narrow = CGAffineTransformMakeScale(kNarrow, 1);
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
    fonts[@(size)] = (__bridge_transfer id)font;
    return font;
}

#pragma mark - Taurus's view, read

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

#pragma mark - the song's lines, as typed

// One letter (a composed character sequence) and the song time it is typed at.
@interface AUTUnit : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double time;
@property (nonatomic) NSUInteger word;
@end
@implementation AUTUnit
@end

@interface AUTLine : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSArray<AUTUnit *> *units;
@property (nonatomic) NSUInteger wordCount;
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

// Taurus's SGKaraokeLine objects, each word's letters spread over its own time (a word sung on a long note is typed
// at a typist's pace from its start, not stretched over the note).
static NSArray<AUTLine *> *typedLines(NSArray *lines) {
    NSLocale *locale = NSLocale.currentLocale;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableArray<AUTLine *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (id line in lines) {
        AUTLine *typed = [AUTLine new];
        typed.start = integerOf(line, @"start");
        typed.end = integerOf(line, @"end");
        id backing = nil;
        @try { backing = [line valueForKey:@"backing"]; } @catch (__unused NSException *e) {}
        if (backing) typed.end = MAX(typed.end, integerOf(backing, @"end"));
        NSArray *words = nil;
        @try { words = [line valueForKey:@"words"]; } @catch (__unused NSException *e) {}
        NSMutableArray<AUTUnit *> *units = [NSMutableArray array];
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
            NSArray<NSString *> *pieces = [[text uppercaseStringWithLocale:locale] componentsSeparatedByCharactersInSet:space];
            NSMutableArray<NSArray<NSString *> *> *kept = [NSMutableArray array];
            NSUInteger total = 0;
            for (NSString *piece in pieces) {
                if (!piece.length) continue;
                NSArray *letters = composedUnits(piece);
                [kept addObject:letters];
                total += letters.count;
            }
            if (!total) continue;
            double per = MIN((end - start) / total, kLetterMostMs);
            NSUInteger at = 0;
            for (NSUInteger p = 0; p < kept.count; p++) {
                // A syllable joined to the word before carries it on; a space inside a word's text starts another.
                if (word < 0 || p > 0 || !joined) word++;
                for (NSString *letter in kept[p]) {
                    AUTUnit *unit = [AUTUnit new];
                    unit.text = letter;
                    unit.time = start + per * at++;
                    unit.word = (NSUInteger)word;
                    [units addObject:unit];
                }
            }
        }
        if (!units.count) continue;   // a break (♪) or an empty line: a clean page
        // Times never run back, whatever the source says about one word against the next.
        double last = -INFINITY;
        for (AUTUnit *unit in units) {
            unit.time = MAX(unit.time, last);
            last = unit.time;
        }
        typed.start = MIN(typed.start, units.firstObject.time);
        typed.units = units;
        typed.wordCount = (NSUInteger)word + 1;
        [out addObject:typed];
    }
    return out;
}

#pragma mark - the letters on the page

@interface AUTGlyph : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic) CGPoint position, target;   // the em box's top left, in the view
@property (nonatomic) CGFloat advance;            // at 100 pt
@property (nonatomic) CGFloat imageEm;            // the size its picture was drawn at
@property (nonatomic) CFTimeInterval shownAt;     // 0: in without the blur
@property (nonatomic) BOOL placed, settled;
@end
@implementation AUTGlyph
@end

static const CGFloat kMeasureEm = 100;

static CGFloat screenScale(void) {
    return MAX(1, UIScreen.mainScreen.scale);
}

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
    NSUInteger _revealed;
    CGSize _laidFor;
    CGFloat _em, _targetEm;
    CALayer *_page, *_cursor;
    CFTimeInterval _lastTick, _lastReveal;
    BOOL _hidLines, _active;
    double _glow;
    NSMutableDictionary<NSString *, NSArray *> *_measures;   // a word so far: its letters' offsets and its width at 100 pt
    NSCache<NSString *, id> *_images;
    CGFloat _pageAlpha;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    _lineIndex = -1;
    _glyphs = [NSMutableArray array];
    _measures = [NSMutableDictionary dictionary];
    _images = [NSCache new];
    _images.countLimit = 400;
    _page = [CALayer layer];
    [self.layer addSublayer:_page];
    _cursor = [CALayer layer];
    _cursor.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95].CGColor;
    _cursor.shadowColor = UIColor.whiteColor.CGColor;
    _cursor.shadowOffset = CGSizeZero;
    _cursor.hidden = YES;
    [_page addSublayer:_cursor];
    _pageAlpha = 1;
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
    }
}

- (void)clearPage {
    for (AUTGlyph *glyph in _glyphs) [glyph.layer removeFromSuperlayer];
    [_glyphs removeAllObjects];
    _revealed = 0;
    _cursor.hidden = YES;
    _em = _targetEm = 0;
}

- (void)tick:(CADisplayLink *)link {
    UIView *karaoke = self.karaoke;
    if (!karaoke || !AUEnabled(AUKeyTypeLyrics)) return [self standDown];
    BOOL compact = boolIvar(karaoke, "_compact", NO);
    if (compact && !AUEnabled(AUKeyTypeLyricsCompact)) return [self standDown];
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
              boolIvar(karaoke, "_sample", NO) ? @"the Lyrics page's preview" : compact ? @"under the cover" : @"lyrics");
    }
    if (!_lines.count) return [self standDown];

    if (!_active) {
        _active = YES;
        self.hidden = NO;
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
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
    BOOL fading = clock > line.end + kFadeAfterMs && (!next || next.start - clock > 1500);
    _pageAlpha += ((fading ? 0 : 1) - _pageAlpha) * (1 - exp(-dt / 0.25));

    NSUInteger revealed = 0;
    while (revealed < line.units.count && line.units[revealed].time <= clock) revealed++;
    BOOL boundsChanged = !CGSizeEqualToSize(_laidFor, self.bounds.size);
    double glow = MIN(1, MAX(0, AUNumber(AUKeyTypeLyricsGlow, 0.35)));
    if (glow != _glow) {
        _glow = glow;
        [_images removeAllObjects];
        for (AUTGlyph *glyph in _glyphs) glyph.imageEm = 0;
    }
    if (revealed != _revealed || boundsChanged) {
        NSUInteger added = revealed > _revealed ? revealed - _revealed : 0;
        [self reveal:revealed of:line together:added];
        if (added) _lastReveal = now;
    }
    [self animate:dt now:now line:line];
}

// The letters typed so far laid out again: the size that fits, the words wrapped and justified.
- (void)reveal:(NSUInteger)count of:(AUTLine *)line together:(NSUInteger)added {
    while (_glyphs.count > count) {
        [_glyphs.lastObject.layer removeFromSuperlayer];
        [_glyphs removeLastObject];
    }
    _revealed = count;
    _laidFor = self.bounds.size;
    if (!count) {
        _cursor.hidden = YES;
        return;
    }
    // The words so far, each as the string typed of it.
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
    CGFloat size = MIN(1.4, MAX(0.6, AUNumber(AUKeyTypeLyricsSize, 1.0)));
    CGFloat boxHeight = MIN(bounds.size.width * kBoxHeight * size, bandHeight * 0.92);
    CGFloat boxTop = bandTop + (bandHeight - boxHeight) / 2;
    CGFloat em = MIN(bounds.size.width * kMaxEm * size, boxHeight / kPitch);

    NSArray<NSArray<NSNumber *> *> *rows = nil;
    for (int tries = 0; tries < 80; tries++, em *= 0.97) {
        rows = [self wrap:measured em:em width:width];
        CGFloat widest = 0;
        for (NSArray *m in measured) widest = MAX(widest, [m[1] doubleValue] * em / kMeasureEm);
        if (rows.count * kPitch * em <= boxHeight + 0.5 && widest <= width + 0.5) break;
        if (em < 9) break;
    }
    _targetEm = em;
    if (_em <= 0) _em = em;

    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray<NSNumber *> *row = rows[r];
        CGFloat total = 0;
        for (NSNumber *w in row) total += [measured[w.unsignedIntegerValue][1] doubleValue] * em / kMeasureEm;
        BOOL last = r + 1 == rows.count;
        CGFloat gap = last || row.count < 2 ? kSpace * em : (width - total) / (row.count - 1);
        CGFloat x = side, y = boxTop + r * kPitch * em;
        for (NSNumber *w in row) {
            NSUInteger wi = w.unsignedIntegerValue;
            NSArray<NSNumber *> *offsets = measured[wi][0];
            CGFloat wordWidth = [measured[wi][1] doubleValue];
            NSArray<NSNumber *> *ids = members[wi];
            for (NSUInteger k = 0; k < ids.count; k++) {
                NSUInteger i = ids[k].unsignedIntegerValue;
                AUTGlyph *glyph = i < _glyphs.count ? _glyphs[i] : nil;
                if (!glyph) {
                    glyph = [AUTGlyph new];
                    glyph.layer = [CALayer layer];
                    glyph.layer.anchorPoint = CGPointZero;
                    glyph.layer.contentsGravity = kCAGravityResize;
                    glyph.layer.contentsScale = screenScale();
                    [_page insertSublayer:glyph.layer below:_cursor];
                    glyph.shownAt = added <= kTogetherMost ? CACurrentMediaTime() : 0;
                    [_glyphs addObject:glyph];
                }
                CGFloat offset = offsets[k].doubleValue;
                CGFloat after = k + 1 < offsets.count ? offsets[k + 1].doubleValue : wordWidth;
                glyph.advance = after - offset;
                glyph.target = CGPointMake(x + offset * em / kMeasureEm, y);
                if (!glyph.placed) {
                    glyph.position = glyph.target;   // a new letter is typed where it belongs; only the others slide
                    glyph.placed = YES;
                }
                glyph.settled = NO;
            }
            x += wordWidth * em / kMeasureEm + gap;
        }
    }
}

// A word's letters' offsets and its width at 100 pt, with the font's kerning (as typed so far: a word half typed may
// set its last letters differently once whole).
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

// The letter's picture: white, the glow drawn in, room around it for the glow.
- (UIImage *)imageFor:(NSString *)text em:(CGFloat)em {
    NSString *key = [NSString stringWithFormat:@"%@|%.1f", text, em];
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
    CGFloat glow = _glow;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextTranslateCTM(cg, 0, size.height);
        CGContextScaleCTM(cg, 1, -1);
        CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
        CGContextSetFillColorWithColor(cg, UIColor.whiteColor.CGColor);
        if (glow > 0.01) CGContextSetShadowWithColor(cg, CGSizeZero, em * 0.12, [UIColor colorWithWhite:1 alpha:glow].CGColor);
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

- (void)animate:(double)dt now:(CFTimeInterval)now line:(AUTLine *)line {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _page.frame = self.bounds;
    _page.opacity = (float)_pageAlpha;
    double sizeStep = 1 - exp(-dt / kSizeTau), moveStep = 1 - exp(-dt / kMoveTau);
    _em += (_targetEm - _em) * sizeStep;
    if (fabs(_targetEm - _em) < 0.05) _em = _targetEm;
    BOOL sizeSettled = _targetEm > 0 && fabs(_em - _targetEm) / _targetEm < 0.01;
    CGFloat scale = screenScale();
    for (NSUInteger i = 0; i < _glyphs.count; i++) {
        AUTGlyph *glyph = _glyphs[i];
        CALayer *layer = glyph.layer;
        // A new picture once the size has settled away from the one it was drawn at (until then it is scaled).
        if (!glyph.imageEm || (sizeSettled && fabs(glyph.imageEm - _targetEm) / _targetEm > 0.03)) {
            UIImage *image = [self imageFor:line.units[i].text em:_targetEm];
            layer.contents = (id)image.CGImage;
            layer.contentsScale = image.scale ?: scale;
            glyph.imageEm = _targetEm;
        }
        CGPoint p = glyph.position, t = glyph.target;
        p.x += (t.x - p.x) * moveStep;
        p.y += (t.y - p.y) * moveStep;
        if (fabs(t.x - p.x) < 0.2 && fabs(t.y - p.y) < 0.2) p = t;
        glyph.position = p;
        CGFloat s = _em / glyph.imageEm;
        CGFloat pad = ceil(glyph.imageEm * 0.3);
        id contents = layer.contents;
        CGSize picture = contents ? CGSizeMake(CGImageGetWidth((CGImageRef)contents) / layer.contentsScale,
                                               CGImageGetHeight((CGImageRef)contents) / layer.contentsScale) : CGSizeZero;
        layer.bounds = CGRectMake(0, 0, picture.width * s, picture.height * s);
        layer.position = CGPointMake(round((p.x - pad * s) * scale) / scale, round((p.y - pad * s) * scale) / scale);
        // The blur-in: faint, wide and soft, then sharp in its place.
        double e = 1;
        if (glyph.shownAt > 0) {
            double k = MIN(1, MAX(0, (now - glyph.shownAt) / kAppear));
            e = 1 - (1 - k) * (1 - k);
            if (k >= 1) glyph.shownAt = 0;
        }
        if (e < 1) {
            layer.opacity = (float)(0.45 + 0.55 * e);
            layer.transform = CATransform3DMakeScale(1 + 0.25 * (1 - e), 1, 1);
            layer.filters = blurFilter((1 - e) * 0.10 * _em);
            glyph.settled = NO;
        } else if (!glyph.settled) {
            layer.opacity = 1;
            layer.transform = CATransform3DIdentity;
            layer.filters = nil;
            glyph.settled = CGPointEqualToPoint(p, t);
        }
    }
    // The cursor, a hair after the last letter typed; it blinks once the typing stops.
    AUTGlyph *last = _glyphs.lastObject;
    BOOL wanted = last && AUEnabled(AUKeyTypeLyricsCursor);
    if (wanted) {
        double idle = now - _lastReveal;
        BOOL on = idle < 0.35 || fmod(idle - 0.35, kBlink) < kBlink * 0.55;
        CGFloat width = MAX(1.5, _em * 0.035), height = _em * kCapHeight;
        CGFloat x = last.position.x + last.advance * _em / kMeasureEm + _em * 0.05;
        CGFloat y = last.position.y + _em * kCapTop - _em * 0.02;
        _cursor.hidden = !on;
        _cursor.frame = CGRectMake(round(x * scale) / scale, y, width, height);
        _cursor.cornerRadius = width / 2;
        _cursor.shadowRadius = _em * 0.08;
        _cursor.shadowOpacity = (float)_glow;
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
        if (!AUEnabled(AUKeyTypeLyrics)) return;
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

NSArray *AUTypeLyricsRows(void) {
    NSMutableArray *rows = [NSMutableArray array];
#define ADD(row) do { id added = (row); if (added) [rows addObject:added]; } while (0)
    SGModRow *on = AURowSwitch(@"Печатная машинка", @"Строка печатается по буквам в такт словам: шрифт Gagalin, курсор, буквы проявляются из размытия, текст по ширине и ужимается по мере роста", AUKeyTypeLyrics);
    on.changed = ^(BOOL value) { AUSettingsChanged(); };
    ADD(AURowSymbol(on, @"character.cursor.ibeam"));
    SGModRow *compact = AURowSwitch(@"И в тексте под обложкой", @"В маленьком превью текста в плеере тоже", AUKeyTypeLyricsCompact);
    compact.waitsOn = AUKeyTypeLyrics;
    ADD(compact);
    SGModRow *cursor = AURowSwitch(@"Курсор", @"Тонкая черта за последней буквой, мигает в паузах", AUKeyTypeLyricsCursor);
    cursor.waitsOn = AUKeyTypeLyrics;
    ADD(cursor);
    SGModRow *size = AURowSlider(@"Размер", nil, 0.6, 1.4, 0.05, ^double { return AUNumber(AUKeyTypeLyricsSize, 1.0); },
                                 ^(double value) { AUSetNumber(AUKeyTypeLyricsSize, value); },
                                 ^NSString *(double value) { return [NSString stringWithFormat:@"×%.2f", value]; });
    size.waitsOn = AUKeyTypeLyrics;
    ADD(size);
    SGModRow *glow = AURowSlider(@"Свечение", nil, 0, 1, 0.05, ^double { return AUNumber(AUKeyTypeLyricsGlow, 0.35); },
                                 ^(double value) { AUSetNumber(AUKeyTypeLyricsGlow, value); },
                                 ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value * 100]; });
    glow.waitsOn = AUKeyTypeLyrics;
    ADD(glow);
#undef ADD
    return rows;
}
