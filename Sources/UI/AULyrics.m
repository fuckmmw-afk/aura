#import "AULyrics.h"
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"
#import "Core/AUYandex.h"
#import <Accelerate/Accelerate.h>
#import <malloc/malloc.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - settings

#define AUKeyLyricsSize @"aura.lyr.size"
#define AUKeyLyricsWeight @"aura.lyr.weight"
#define AUKeyLyricsAlign @"aura.lyr.align"
#define AUKeyLyricsBlur @"aura.lyr.blur"
#define AUKeyLyricsDim @"aura.lyr.dim"
#define AUKeyLyricsAnchor @"aura.lyr.anchor"
#define AUKeyLyricsSpacing @"aura.lyr.spacing"
#define AUKeyLyricsKaraoke @"aura.lyr.karaoke"
#define AUKeyLyricsBackground @"aura.lyr.bg"
#define AUKeyLyricsOffset @"aura.lyr.offset"
#define AUKeyLyricsLRCLIB @"aura.lyr.lrclib"
#define AUKeyLyricsTap @"aura.lyr.tap"
#define AUKeyLyricsGlow @"aura.lyr.glow"

static CGFloat fontSize(void) { return AUNumber(AUKeyLyricsSize, 32); }
static CGFloat spacing(void) { return AUNumber(AUKeyLyricsSpacing, 22); }
static CGFloat dimAlpha(void) { return AUNumber(AUKeyLyricsDim, 0.35); }
static CGFloat blurRadius(void) { return AUNumber(AUKeyLyricsBlur, 4); }
static CGFloat anchor(void) { return AUNumber(AUKeyLyricsAnchor, 0.32); }

static UIFont *lyricFont(void) {
    UIFontWeight weights[] = {UIFontWeightBold, UIFontWeightHeavy, UIFontWeightBlack};
    NSInteger w = MAX(0, MIN(2, AUInteger(AUKeyLyricsWeight, 1)));
    return [UIFont systemFontOfSize:fontSize() weight:weights[w]];
}

static NSTextAlignment lyricAlignment(void) {
    return AUInteger(AUKeyLyricsAlign, 0) == 1 ? NSTextAlignmentCenter : NSTextAlignmentLeft;
}

#pragma mark - lyrics

@interface AULyricWord : NSObject
@property (nonatomic) double time;
@property (nonatomic) NSRange range;
@end

@implementation AULyricWord
@end

@interface AULyricLine : NSObject
@property (nonatomic) double time;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<AULyricWord *> *words;
@end

@implementation AULyricLine
@end

@interface AULyricsSet : NSObject
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSArray<AULyricLine *> *lines;
@property (nonatomic) BOOL synced;
@property (nonatomic, copy) NSString *source;
@end

@implementation AULyricsSet
@end

static NSString *const AULyricsDidChangeNotification = @"AULyricsDidChangeNotification";
static NSMutableDictionary<NSString *, AULyricsSet *> *sLyrics;
static NSMutableSet<NSString *> *sAsked;

static double timeOf(NSString *minutes, NSString *seconds) {
    return minutes.doubleValue * 60 + [seconds stringByReplacingOccurrencesOfString:@":" withString:@"."].doubleValue;
}

// "[01:02.34]words", several stamps for one line allowed; "<01:02.50>" before a word gives its own time.
static NSArray<AULyricLine *> *parseLRC(NSString *text, BOOL *synced) {
    static NSRegularExpression *stamp, *word;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]" options:0 error:nil];
        word = [NSRegularExpression regularExpressionWithPattern:@"<(\\d+):(\\d+(?:[.:]\\d+)?)>" options:0 error:nil];
    });
    NSMutableArray<AULyricLine *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *plain = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *rest = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        while (YES) {
            NSTextCheckingResult *m = [stamp firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
            if (!m) break;
            [times addObject:@(timeOf([rest substringWithRange:[m rangeAtIndex:1]], [rest substringWithRange:[m rangeAtIndex:2]]))];
            rest = [rest substringFromIndex:m.range.length];
        }
        if (!times.count) {
            if ([rest hasPrefix:@"["] && [rest hasSuffix:@"]"]) continue;   // [ar:...] and the like
            if (rest.length) [plain addObject:rest];
            continue;
        }
        // Word stamps out, each word's time kept against its place in the clean text.
        NSMutableString *clean = [NSMutableString string];
        NSMutableArray<AULyricWord *> *words = [NSMutableArray array];
        NSUInteger at = 0;
        for (NSTextCheckingResult *m in [word matchesInString:rest options:0 range:NSMakeRange(0, rest.length)]) {
            [clean appendString:[rest substringWithRange:NSMakeRange(at, m.range.location - at)]];
            AULyricWord *w = [AULyricWord new];
            w.time = timeOf([rest substringWithRange:[m rangeAtIndex:1]], [rest substringWithRange:[m rangeAtIndex:2]]);
            w.range = NSMakeRange(clean.length, 0);
            [words addObject:w];
            at = NSMaxRange(m.range);
        }
        [clean appendString:[rest substringFromIndex:at]];
        for (NSUInteger i = 0; i < words.count; i++) {
            NSUInteger end = i + 1 < words.count ? words[i + 1].range.location : clean.length;
            words[i].range = NSMakeRange(words[i].range.location, end - words[i].range.location);
        }
        NSString *line = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber *time in times) {
            AULyricLine *l = [AULyricLine new];
            l.time = time.doubleValue;
            l.text = line;
            l.words = times.count == 1 ? words : @[];
            [lines addObject:l];
        }
    }
    if (lines.count >= 3) {
        *synced = YES;
        [lines sortUsingComparator:^NSComparisonResult(AULyricLine *a, AULyricLine *b) { return a.time < b.time ? NSOrderedAscending : a.time > b.time ? NSOrderedDescending : NSOrderedSame; }];
        return lines;
    }
    *synced = NO;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *text in plain) {
        AULyricLine *l = [AULyricLine new];
        l.time = -1;
        l.text = text;
        l.words = @[];
        [out addObject:l];
    }
    return out;
}

static void keep(NSString *uri, NSString *text, NSString *source) {
    BOOL synced = NO;
    NSArray *lines = parseLRC(text, &synced);
    if (!lines.count) return;
    AULyricsSet *known = sLyrics[uri];
    if (known.synced && !synced) return;   // a plain text never replaces a timed one
    AULyricsSet *set = [AULyricsSet new];
    set.uri = uri;
    set.lines = lines;
    set.synced = synced;
    set.source = source;
    if (!sLyrics) sLyrics = [NSMutableDictionary dictionary];
    if (sLyrics.count > 30) [sLyrics removeAllObjects];
    sLyrics[uri] = set;
    AULog(@"lyrics: %lu lines (%@) from %@ for \"%@\"", (unsigned long)lines.count, synced ? @"timed" : @"plain", source, AUTaurusTrackTitle());
    [NSNotificationCenter.defaultCenter postNotificationName:AULyricsDidChangeNotification object:nil];
}

void AULyricsSawBody(NSData *data, NSURL *url) {
    if (data.length < 20 || data.length > 300 * 1024) return;
    const char *bytes = data.bytes;
    NSUInteger i = 0;
    while (i < 8 && i < data.length && (bytes[i] == ' ' || bytes[i] == '\n' || bytes[i] == '\r' || (uint8_t)bytes[i] == 0xEF || (uint8_t)bytes[i] == 0xBB || (uint8_t)bytes[i] == 0xBF)) i++;
    if (i >= data.length || bytes[i] != '[') return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![text rangeOfString:@"^\\[\\d+:\\d+" options:NSRegularExpressionSearch].length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *uri = AUTaurusTrackURI();
        if (!uri.length) return;
        BOOL synced = NO;
        NSArray<AULyricLine *> *lines = parseLRC(text, &synced);
        double duration = AUYandexDuration();
        // Lyrics of another song (the next one, fetched ahead) run past this one's end.
        if (!synced || (!isnan(duration) && lines.lastObject.time > duration + 5)) return;
        keep(uri, text, @"Яндекса");
    });
}

static NSString *firstArtist(NSString *artists) {
    for (NSString *separator in @[@", ", @" & ", @" feat. ", @" ft. "]) {
        NSRange r = [artists rangeOfString:separator];
        if (r.location != NSNotFound) artists = [artists substringToIndex:r.location];
    }
    return artists;
}

static NSData *fetch(NSURL *url, NSInteger *code) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:12];
    [request setValue:@"Aura lyrics (iOS tweak)" forHTTPHeaderField:@"User-Agent"];
    __block NSData *body = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        body = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
    if (code) *code = status;
    return body;
}

static NSURL *lrclibURL(NSString *path, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"https://lrclib.net/api/" stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in query) {
        if (query[key].length) [items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
    }
    c.queryItems = items;
    return c.URL;
}

// LRCLIB, when the app's own lyrics did not come: the exact record first, then a search by title and first artist.
static void askLRCLIB(NSString *uri) {
    if (!AUEnabled(AUKeyLyricsLRCLIB) || [sAsked containsObject:uri]) return;
    if (!sAsked) sAsked = [NSMutableSet set];
    [sAsked addObject:uri];
    NSString *title = AUTaurusTrackTitle() ?: @"", *artist = AUYandexTrackArtist() ?: @"", *album = AUYandexTrackAlbum() ?: @"";
    double duration = AUYandexDuration();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *found = nil;
        NSInteger code = 0;
        NSMutableDictionary *query = [@{@"track_name": title, @"artist_name": firstArtist(artist), @"album_name": album} mutableCopy];
        if (!isnan(duration)) query[@"duration"] = [NSString stringWithFormat:@"%.0f", duration];
        NSData *data = fetch(lrclibURL(@"get", query), &code);
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (code == 200 && [json isKindOfClass:NSDictionary.class]) {
            found = [json[@"syncedLyrics"] isKindOfClass:NSString.class] ? json[@"syncedLyrics"] : nil;
            if (!found.length && [json[@"plainLyrics"] isKindOfClass:NSString.class]) found = json[@"plainLyrics"];
        }
        if (!found.length) {
            data = fetch(lrclibURL(@"search", @{@"track_name": title, @"artist_name": firstArtist(artist)}), &code);
            json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            double best = 1e9;
            if ([json isKindOfClass:NSArray.class]) {
                for (NSDictionary *item in json) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *synced = [item[@"syncedLyrics"] isKindOfClass:NSString.class] ? item[@"syncedLyrics"] : nil;
                    double length = [item[@"duration"] respondsToSelector:@selector(doubleValue)] ? [item[@"duration"] doubleValue] : 0;
                    double miss = isnan(duration) ? 0 : fabs(length - duration);
                    if (synced.length && miss <= 4 && miss < best) {
                        best = miss;
                        found = synced;
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (found.length) keep(uri, found, @"LRCLIB");
            else {
                AULog(@"lyrics: LRCLIB has none for \"%@\" (%ld)", title, (long)code);
                [NSNotificationCenter.defaultCenter postNotificationName:AULyricsDidChangeNotification object:nil];
            }
        });
    });
}

#pragma mark - blur

static NSArray *blurFilter(CGFloat radius) {
    if (radius < 0.3) return nil;
    static Class filterClass;
    static NSMutableDictionary<NSNumber *, NSArray *> *cache;
    if (!filterClass) filterClass = NSClassFromString(@"CAFilter");
    if (!filterClass) return nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *key = @(round(radius * 4) / 4);
    NSArray *made = cache[key];
    if (!made) {
        id filter = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
        [filter setValue:key forKey:@"inputRadius"];
        made = filter ? @[filter] : @[];
        cache[key] = made;
    }
    return made;
}

static UIImage *blurredCover(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    const size_t side = 64;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!c) return nil;
    CGContextDrawImage(c, CGRectMake(0, 0, side, side), cg);
    vImage_Buffer a = {CGBitmapContextGetData(c), side, side, CGBitmapContextGetBytesPerRow(c)};
    NSMutableData *scratch = [NSMutableData dataWithLength:a.rowBytes * side];
    vImage_Buffer b = {scratch.mutableBytes, side, side, a.rowBytes};
    for (int i = 0; i < 3; i++) {
        vImageTentConvolve_ARGB8888(&a, &b, NULL, 0, 0, 11, 11, NULL, kvImageEdgeExtend);
        vImageTentConvolve_ARGB8888(&b, &a, NULL, 0, 0, 11, 11, NULL, kvImageEdgeExtend);
    }
    CGImageRef made = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    UIImage *out = made ? [UIImage imageWithCGImage:made] : nil;
    if (made) CGImageRelease(made);
    return out;
}

#pragma mark - the view

@interface AULyricsView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) UIImageView *backdrop;
- (void)sync;
@end

@implementation AULyricsView {
    AULyricsSet *_set;
    NSMutableArray<UILabel *> *_labels;
    NSMutableArray<NSValue *> *_sizes;
    NSMutableArray<NSArray<NSValue *> *> *_rows;      // each label's rows: {x, y, w, h} and char range packed in two values
    NSMutableArray<NSArray<NSValue *> *> *_rowRanges;
    NSInteger _current;
    BOOL _active;
    CADisplayLink *_link;
    CGFloat _userOffset, _laidWidth;
    CFTimeInterval _userTouched;
    UILabel *_empty;
    CAGradientLayer *_edges;
    NSString *_settingsStamp;
    __weak UIImage *_backdropOf;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    _labels = [NSMutableArray array];
    _current = -2;
    _empty = [UILabel new];
    _empty.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    _empty.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _empty.numberOfLines = 0;
    _empty.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_empty];
    _edges = [CAGradientLayer layer];
    _edges.colors = @[(id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    _edges.locations = @[@0, @0.06, @0.88, @1];
    self.layer.mask = _edges;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [self addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    [self addGestureRecognizer:pan];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(reload) name:AULyricsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(reload) name:AUTrackDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(settingsChanged) name:AUSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateBackdrop) name:AUYandexArtworkDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_link invalidate];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (![gesture isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint v = [(UIPanGestureRecognizer *)gesture velocityInView:self];
    return fabs(v.y) > fabs(v.x);   // sideways swipes stay the app's
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        _link.preferredFramesPerSecond = 30;
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [self reload];
    } else if (!self.window) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)settingsChanged {
    _laidWidth = 0;
    [self reload];
}

- (void)updateBackdrop {
    UIImageView *backdrop = self.backdrop;
    if (!backdrop) return;
    UIImage *image = AUYandexArtwork(NULL, NULL, NULL);
    if (image && image != _backdropOf) {
        _backdropOf = image;
        backdrop.image = blurredCover(image);
    }
}

- (void)reload {
    NSString *uri = AUTaurusTrackURI();
    AULyricsSet *set = uri ? sLyrics[uri] : nil;
    if (!set && uri && self.window) {
        // The app's own lyrics have a moment to come; then LRCLIB.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([AUTaurusTrackURI() isEqualToString:uri] && !sLyrics[uri]) askLRCLIB(uri);
        });
    }
    if (set != _set || _laidWidth != self.bounds.size.width) {
        _set = set;
        [self rebuild];
    }
    [self updateBackdrop];
}

- (void)rebuild {
    for (UILabel *label in _labels) [label removeFromSuperview];
    [_labels removeAllObjects];
    _sizes = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _rowRanges = [NSMutableArray array];
    _current = -2;
    _userOffset = 0;
    _laidWidth = self.bounds.size.width;
    NSString *uri = AUTaurusTrackURI();
    _empty.hidden = _set.lines.count > 0;
    _empty.text = [sAsked containsObject:uri ?: @""] ? @"Текста нет ни у Яндекса, ни в LRCLIB" : @"Ищу текст…";
    if (!_set.lines.count) {
        [self setNeedsLayout];
        return;
    }
    UIFont *font = lyricFont();
    CGFloat width = MAX(40, self.bounds.size.width - 48);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = lyricAlignment();
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    for (AULyricLine *line in _set.lines) {
        UILabel *label = [UILabel new];
        label.numberOfLines = 0;
        NSString *text = line.text.length ? line.text : @"• • •";
        label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: paragraph}];
        if (AUEnabled(AUKeyLyricsGlow)) {
            label.layer.shadowColor = UIColor.whiteColor.CGColor;
            label.layer.shadowRadius = 8;
            label.layer.shadowOpacity = 0;
            label.layer.shadowOffset = CGSizeZero;
        }
        CGSize size = [label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        size.width = width;
        label.frame = (CGRect){CGPointMake(24, 0), size};
        [self addSubview:label];
        [_labels addObject:label];
        [_sizes addObject:[NSValue valueWithCGSize:size]];
        // Its rows, as TextKit lays them out at this width, for the sweep through the line.
        NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:label.attributedText];
        NSLayoutManager *layout = [NSLayoutManager new];
        NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
        container.lineFragmentPadding = 0;
        [layout addTextContainer:container];
        [storage addLayoutManager:layout];
        NSMutableArray *rows = [NSMutableArray array], *ranges = [NSMutableArray array];
        [layout enumerateLineFragmentsForGlyphRange:NSMakeRange(0, layout.numberOfGlyphs)
                                         usingBlock:^(CGRect rect, CGRect used, NSTextContainer *c, NSRange glyphs, BOOL *stop) {
            NSRange chars = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
            [rows addObject:[NSValue valueWithCGRect:CGRectMake(used.origin.x, rect.origin.y, used.size.width, rect.size.height)]];
            [ranges addObject:[NSValue valueWithRange:chars]];
        }];
        // Character offsets inside each row (for the sweep's edge), measured once.
        NSMutableArray *packed = [NSMutableArray array];
        for (NSUInteger r = 0; r < rows.count; r++) {
            NSRange chars = [ranges[r] rangeValue];
            NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithCapacity:chars.length + 1];
            for (NSUInteger k = 0; k <= chars.length; k++) {
                NSRange glyphs = [layout glyphRangeForCharacterRange:NSMakeRange(chars.location, k) actualCharacterRange:NULL];
                CGRect box = k ? [layout boundingRectForGlyphRange:glyphs inTextContainer:container] : CGRectMake([rows[r] CGRectValue].origin.x, 0, 0, 0);
                [xs addObject:@(CGRectGetMaxX(box))];
            }
            [packed addObject:@{@"rect": rows[r], @"range": ranges[r], @"xs": xs}];
        }
        [_rows addObject:packed];
    }
    [self tick];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _edges.frame = self.bounds;
    _empty.frame = CGRectInset(self.bounds, 32, 0);
    if (fabs(_laidWidth - self.bounds.size.width) > 0.5) [self rebuild];
}

- (double)now {
    double t = AUYandexPlaybackTime();
    return isnan(t) ? t : t + AUNumber(AUKeyLyricsOffset, 0);
}

- (NSInteger)indexAt:(double)t {
    NSInteger index = -1;
    for (NSInteger i = 0; i < (NSInteger)_set.lines.count; i++) {
        if (_set.lines[(NSUInteger)i].time <= t) index = i;
        else break;
    }
    return index;
}

- (void)tick {
    [self sync];
    // Hidden (the app shows no lyrics now): a look a few times a second whether it does again.
    NSInteger fps = self.hidden ? 4 : 30;
    if (_link.preferredFramesPerSecond != fps) _link.preferredFramesPerSecond = fps;
    if (self.hidden || !_labels.count) return;
    double t = [self now];
    NSInteger index = _set.synced && !isnan(t) ? [self indexAt:t] : -1;
    BOOL active = index >= 0;
    NSInteger shown = MAX(0, index);
    BOOL user = CACurrentMediaTime() - _userTouched < 2.5;
    if (!user && _userOffset != 0 && _userTouched > 0) {
        _userOffset = 0;
        _current = -2;   // spring back
    }
    if (shown != _current || active != _active) {
        BOOL first = _current == -2;
        _current = shown;
        _active = active;
        [self place:!first];
    }
    if (_set.synced && AUEnabled(AUKeyLyricsKaraoke) && active) [self sweep:t];
}

// Every line where it goes for the current one, and dimmed, blurred and lit by how far it is from it.
- (void)place:(BOOL)animated {
    CGFloat H = self.bounds.size.height, gap = spacing();
    NSInteger count = (NSInteger)_labels.count;
    CGFloat y0 = H * anchor() + _userOffset;
    // The current line's top at the anchor, the rest stacked above and below it.
    CGFloat ys[count];
    CGFloat y = y0;
    for (NSInteger i = _current; i < count; i++) {
        ys[i] = y;
        y += [_sizes[(NSUInteger)i] CGSizeValue].height + gap;
    }
    y = y0;
    for (NSInteger i = _current - 1; i >= 0; i--) {
        y -= [_sizes[(NSUInteger)i] CGSizeValue].height + gap;
        ys[i] = y;
    }
    BOOL user = CACurrentMediaTime() - _userTouched < 2.5;
    CGFloat dim = dimAlpha(), blur = blurRadius();
    for (NSInteger i = 0; i < count; i++) {
        UILabel *label = _labels[(NSUInteger)i];
        CGSize size = [_sizes[(NSUInteger)i] CGSizeValue];
        CGFloat x = 24;
        BOOL near = ys[i] > -H && ys[i] < 2 * H;
        label.hidden = !near;
        if (!near) {
            label.transform = CGAffineTransformIdentity;
            label.frame = (CGRect){CGPointMake(x, ys[i]), size};
            continue;
        }
        NSInteger d = i - _current;
        BOOL lit = d == 0 && (_active || !_set.synced);
        CGFloat alpha = !_set.synced ? 0.9 : lit ? 1 : user ? MIN(0.85, dim * 1.8) : dim;
        CGFloat radius = lit || user || !_set.synced ? 0 : blur * (0.6 + 0.3 * MIN(labs(d) - 1, 4));
        // Bounds and centre, not frame: the line is scaled down a touch when it is not the current one.
        CGPoint anchorPoint = lyricAlignment() == NSTextAlignmentCenter ? CGPointMake(0.5, 0.5) : CGPointMake(0, 0.5);
        if (!CGPointEqualToPoint(label.layer.anchorPoint, anchorPoint)) label.layer.anchorPoint = anchorPoint;
        CGPoint center = CGPointMake(x + anchorPoint.x * size.width, ys[i] + anchorPoint.y * size.height);
        BOOL plain = lit || !_set.synced;
        void (^apply)(void) = ^{
            label.bounds = (CGRect){CGPointZero, size};
            label.center = center;
            label.alpha = alpha;
            label.transform = plain ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.97, 0.97);
        };
        if (animated) {
            // Lines below the new one follow a beat later, like a spring through the list.
            NSTimeInterval delay = MAX(0, MIN(0.24, 0.04 * (d + 1)));
            [UIView animateWithDuration:0.7 delay:delay usingSpringWithDamping:0.86 initialSpringVelocity:0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
        } else {
            [UIView performWithoutAnimation:apply];
        }
        label.layer.filters = blurFilter(radius);
        label.layer.shadowOpacity = lit && AUEnabled(AUKeyLyricsGlow) ? 0.35 : 0;
        if (!lit) label.layer.mask = nil;
    }
}

// The sung part of the current line lit, the rest still dim: by its words' own times when the lyrics have them,
// else evenly through the time until the next line (at most as long as it takes to say).
- (void)sweep:(double)t {
    if (_current < 0 || _current >= (NSInteger)_labels.count) return;
    AULyricLine *line = _set.lines[(NSUInteger)_current];
    UILabel *label = _labels[(NSUInteger)_current];
    NSUInteger length = label.attributedText.length;
    if (!length) return;
    double position;
    if (line.words.count) {
        position = 0;
        for (NSUInteger i = 0; i < line.words.count; i++) {
            AULyricWord *w = line.words[i];
            if (w.time > t) break;
            double next = i + 1 < line.words.count ? line.words[i + 1].time : w.time + MAX(0.3, w.range.length * 0.07);
            double f = MAX(0, MIN(1, (t - w.time) / MAX(0.05, next - w.time)));
            position = w.range.location + f * w.range.length;
        }
    } else {
        double next = _current + 1 < (NSInteger)_set.lines.count ? _set.lines[(NSUInteger)_current + 1].time : line.time + 4;
        double span = MAX(0.6, MIN(next - line.time, 0.9 + length * 0.075));
        position = MAX(0, MIN(1, (t - line.time) / span)) * length;
    }
    CGFloat dim = dimAlpha();
    CALayer *mask = [CALayer layer];
    mask.frame = label.bounds;
    NSArray *rows = _rows[(NSUInteger)_current];
    for (NSDictionary *row in rows) {
        CGRect rect = [row[@"rect"] CGRectValue];
        NSRange range = [row[@"range"] rangeValue];
        CGRect band = CGRectMake(0, rect.origin.y, label.bounds.size.width, rect.size.height);
        if (position >= NSMaxRange(range)) {
            CALayer *full = [CALayer layer];
            full.frame = band;
            full.backgroundColor = UIColor.whiteColor.CGColor;
            [mask addSublayer:full];
        } else if (position <= range.location) {
            CALayer *off = [CALayer layer];
            off.frame = band;
            off.backgroundColor = [UIColor colorWithWhite:1 alpha:dim].CGColor;
            [mask addSublayer:off];
        } else {
            NSArray<NSNumber *> *xs = row[@"xs"];
            double inRow = position - range.location;
            NSUInteger k = (NSUInteger)floor(inRow);
            double f = inRow - k;
            CGFloat a = xs[MIN(k, xs.count - 1)].doubleValue, b = xs[MIN(k + 1, xs.count - 1)].doubleValue;
            CGFloat edge = a + (b - a) * f;
            CGFloat soft = 14, w = MAX(1, band.size.width);
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = band;
            g.startPoint = CGPointMake(0, 0.5);
            g.endPoint = CGPointMake(1, 0.5);
            g.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:dim].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:dim].CGColor];
            g.locations = @[@0, @(MAX(0, (edge - soft) / w)), @(MIN(1, (edge + soft) / w)), @1];
            [mask addSublayer:g];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    label.layer.mask = mask;
    [CATransaction commit];
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    if (!_set.synced || !AUEnabled(AUKeyLyricsTap)) return;
    CGPoint p = [tap locationInView:self];
    for (NSUInteger i = 0; i < _labels.count; i++) {
        UILabel *label = _labels[i];
        if (!label.hidden && CGRectContainsPoint(CGRectInset(label.frame, 0, -spacing() / 2), p)) {
            double target = MAX(0, _set.lines[i].time - AUNumber(AUKeyLyricsOffset, 0) + 0.05);
            if (AUYandexSeek(target)) {
                _userTouched = 0;
                _userOffset = 0;
                _current = -2;
            }
            return;
        }
    }
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:self].y;
    [pan setTranslation:CGPointZero inView:self];
    _userOffset += dy;
    _userTouched = CACurrentMediaTime();
    [self place:NO];
}

// Where the app's lyrics view is, and whether it shows: this view takes its frame and its alpha.
- (void)sync {
    UIView *host = self.host;
    if (!host || !host.window || !self.superview) {
        self.hidden = YES;
        self.backdrop.hidden = YES;
        return;
    }
    BOOL showing = !host.hidden;
    for (UIView *v = host.superview; v && showing; v = v.superview) showing = !v.hidden && v.alpha > 0.01;
    self.hidden = !showing;
    self.backdrop.hidden = !showing;
    if (self.superview != host.superview) return;
    if (!CGRectEqualToRect(self.frame, host.frame)) self.frame = host.frame;
    if (fabs(self.alpha - host.alpha) > 0.001) self.alpha = host.alpha;
    UIImageView *backdrop = self.backdrop;
    if (backdrop) {
        CGRect window = [host.superview convertRect:host.window.bounds fromView:nil];
        if (!CGRectEqualToRect(backdrop.frame, window)) backdrop.frame = window;
        backdrop.alpha = host.alpha;
    }
}

@end

#pragma mark - placing it

static CALayer *emptyMask(void) {
    static CALayer *mask;
    if (!mask) mask = [CALayer layer];
    return mask;
}

// PlayerViewController's lazy trackLyricsHostingView: a Swift optional reference, read as the pointer it is.
static UIView *lyricsHost(UIViewController *controller) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "$__lazy_storage_$_trackLyricsHostingView");
    if (!ivar) return nil;
    void *raw = *(void **)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
    if (!raw || ((uintptr_t)raw & 7) || !malloc_zone_from_ptr(raw)) return nil;
    id object = (__bridge id)raw;
    if ([object isKindOfClass:UIView.class]) return object;
    if ([object isKindOfClass:UIViewController.class]) return [(UIViewController *)object viewIfLoaded];
    return nil;
}

static NSString *treeOf(UIView *root, UIView *mark, int depth, int maxDepth, NSUInteger *lines) {
    if (depth > maxDepth || *lines > 160) return @"";
    (*lines)++;
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@%@ %.0f,%.0f %.0fx%.0f%@%@%@\n", [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
                      NSStringFromClass(root.class), root.frame.origin.x, root.frame.origin.y, root.bounds.size.width, root.bounds.size.height,
                      root.hidden ? @" hidden" : @"", root.alpha < 0.99 ? [NSString stringWithFormat:@" a%.2f", root.alpha] : @"",
                      root == mark ? @"  <== lyrics" : @""];
    for (UIView *sub in root.subviews) [out appendString:treeOf(sub, mark, depth + 1, maxDepth, lines)];
    return out;
}

void AULyricsPlayerLaidOut(UIViewController *controller) {
    static char kOverlayKey;
    UIView *host = lyricsHost(controller);
    if (!host) return;
    AULyricsView *overlay = objc_getAssociatedObject(host, &kOverlayKey);
    if (!AUEnabled(AUKeyLyrics)) {
        if (overlay) {
            [overlay.backdrop removeFromSuperview];
            [overlay removeFromSuperview];
            objc_setAssociatedObject(host, &kOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (host.layer.mask == emptyMask()) host.layer.mask = nil;
        }
        return;
    }
    if (!host.superview) return;
    if (!overlay) {
        overlay = [[AULyricsView alloc] initWithFrame:host.frame];
        overlay.host = host;
        objc_setAssociatedObject(host, &kOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSUInteger lines = 0;
        AULog(@"lyrics: Aura's screen over %@ (%.0f x %.0f); the player:\n%@", NSStringFromClass(host.class), host.bounds.size.width,
              host.bounds.size.height, treeOf(controller.view, host, 0, 7, &lines));
    }
    BOOL wantBackdrop = AUEnabled(AUKeyLyricsBackground);
    if (wantBackdrop && !overlay.backdrop) {
        UIImageView *backdrop = [UIImageView new];
        backdrop.contentMode = UIViewContentModeScaleAspectFill;
        backdrop.clipsToBounds = YES;
        backdrop.userInteractionEnabled = NO;
        UIView *shade = [UIView new];
        shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
        shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [backdrop addSubview:shade];
        overlay.backdrop = backdrop;
        [overlay updateBackdrop];
    } else if (!wantBackdrop && overlay.backdrop) {
        [overlay.backdrop removeFromSuperview];
        overlay.backdrop = nil;
    }
    if (overlay.superview != host.superview || host.superview.subviews.count < 2
        || [host.superview.subviews indexOfObject:overlay] < [host.superview.subviews indexOfObject:host]) {
        [host.superview insertSubview:overlay aboveSubview:host];
    }
    if (overlay.backdrop && overlay.backdrop.superview != host.superview) [host.superview insertSubview:overlay.backdrop aboveSubview:host];
    // The app's own lyrics stay where they are (their state, their gestures underneath) but draw nothing.
    if (host.layer.mask != emptyMask()) host.layer.mask = emptyMask();
    [overlay sync];
}

void AULyricsStart(void) {
}

#pragma mark - settings

UIViewController *AULyricsSettingsPage(void) {
    NSMutableArray *sections = [NSMutableArray array];
    void (^changed)(BOOL) = ^(BOOL on) { AUSettingsChanged(); };
    NSMutableArray *main = [NSMutableArray array];
    SGModRow *on = AURowSwitch(@"Свой экран текста", @"Вместо текста Яндекса — экран в стиле Apple Music", AUKeyLyrics);
    on.changed = changed;
    if (on) [main addObject:AURowSymbol(on, @"quote.bubble.fill")];
    SGModRow *backdrop = AURowSwitch(@"Фон — размытая обложка", nil, AUKeyLyricsBackground);
    backdrop.changed = changed;
    if (backdrop) [main addObject:backdrop];
    SGModRow *lrclib = AURowSwitch(@"Искать в LRCLIB", @"Если у Яндекса нет синхронизированного текста — lrclib.net по названию, артисту и длине", AUKeyLyricsLRCLIB);
    lrclib.changed = changed;
    if (lrclib) [main addObject:lrclib];
    SGModRow *tap = AURowSwitch(@"Тап по строке — перемотка", nil, AUKeyLyricsTap);
    tap.changed = changed;
    if (tap) [main addObject:tap];
    id first = AUSection(nil, main, @"Текст берётся у Яндекса, когда приложение его скачивает, иначе из LRCLIB. Время — из «Сейчас играет».");
    if (first) [sections addObject:first];

    NSMutableArray *look = [NSMutableArray array];
    void (^num)(NSString *, NSString *, double, double, double, double, NSString *) =
        ^(NSString *title, NSString *key, double minimum, double maximum, double step, double fallback, NSString *format) {
            SGModRow *row = AURowSlider(title, nil, minimum, maximum, step, ^double { return AUNumber(key, fallback); },
                                        ^(double value) { AUSetNumber(key, value); },
                                        ^NSString *(double value) { return [NSString stringWithFormat:format, value]; });
            if (row) [look addObject:row];
        };
    num(@"Размер шрифта", AUKeyLyricsSize, 20, 48, 1, 32, @"%.0f pt");
    SGModRow *weight = AURowChoice(@"Насыщенность", nil, AUKeyLyricsWeight, @[@"Жирный", @"Очень жирный", @"Чёрный"], 1);
    weight.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    if (weight) [look addObject:weight];
    SGModRow *align = AURowChoice(@"Выравнивание", nil, AUKeyLyricsAlign, @[@"Слева", @"По центру"], 0);
    align.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    if (align) [look addObject:align];
    num(@"Размытие соседних строк", AUKeyLyricsBlur, 0, 12, 0.5, 4, @"%.1f");
    num(@"Яркость соседних строк", AUKeyLyricsDim, 0.1, 0.8, 0.05, 0.35, @"%.2f");
    num(@"Высота текущей строки", AUKeyLyricsAnchor, 0.15, 0.6, 0.01, 0.32, @"%.2f");
    num(@"Расстояние между строками", AUKeyLyricsSpacing, 6, 48, 1, 22, @"%.0f pt");
    SGModRow *karaoke = AURowSwitch(@"Заливка по ходу строки", @"Строка загорается слева направо, как поётся (по словам, если у текста есть их время)", AUKeyLyricsKaraoke);
    karaoke.changed = changed;
    if (karaoke) [look addObject:karaoke];
    SGModRow *glow = AURowSwitch(@"Свечение текущей строки", nil, AUKeyLyricsGlow);
    glow.changed = changed;
    if (glow) [look addObject:glow];
    num(@"Сдвиг текста по времени", AUKeyLyricsOffset, -2, 2, 0.05, 0, @"%+.2f с");
    id second = AUSection(@"Вид", look, nil);
    if (second) [sections addObject:second];
    return AUMakePage(@"Текст песни", nil, sections, nil);
}
