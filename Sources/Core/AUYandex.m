#import "AUYandex.h"
#import "AUCore.h"
#import "AUTaurus.h"
#import "UI/AUCoverEffects.h"
#import "UI/AUSettings.h"
#import "UI/AUYandexFill.h"
#import "UI/AULyrics.h"
#import <CommonCrypto/CommonDigest.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>

NSNotificationName const AUYandexArtworkDidChangeNotification = @"AUYandexArtworkDidChangeNotification";

BOOL AUHostYandex(void) {
    static BOOL yandex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        yandex = [bundle hasPrefix:@"ru.yandex.mobile.music"] || NSClassFromString(@"_TtC23MusicPlayerLandingMaple17PlayerArtworkView") != nil;
    });
    return yandex;
}

#pragma mark - the now playing info

// What the app last set, and Aura's extras: touched from the hook on any thread, under this lock.
static NSLock *sg_lock;
static NSDictionary *sg_info;               // the app's own info, without Aura's keys
static __weak id sg_center;
static NSDictionary *sg_extras;
static NSString *sg_extrasTitle;
static BOOL sg_seenOwnAnimated;
static double sg_elapsed = NAN, sg_rate, sg_stamp, sg_duration = NAN;

// Read on the main queue from sg_info.
static NSString *sg_uri, *sg_title;
static UIImage *sg_image;
static NSString *sg_key, *sg_keyURI;
static BOOL sg_exact;                       // big enough to need no better copy (the player's own, or 600 px and more)
static NSData *sg_thumb;                    // sg_image small and grey, to know the player's copy of it
static __weak MPMediaItemArtwork *sg_artwork;

static NSString *trackURIOf(NSDictionary *info) {
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    // The content id as the app gives it, with the names: whatever that id stands for (a track or the queue it plays
    // from), another song is another URI.
    id external = info[MPNowPlayingInfoPropertyExternalContentIdentifier];
    NSString *id_ = [external isKindOfClass:NSString.class] ? external : [external isKindOfClass:NSNumber.class] ? [external stringValue] : @"";
    NSString *artist = [info[MPMediaItemPropertyArtist] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyArtist] : @"";
    NSString *album = [info[MPMediaItemPropertyAlbumTitle] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyAlbumTitle] : @"";
    NSString *names = [AUSHA1([NSString stringWithFormat:@"%@\n%@\n%@", title, artist, album]) substringToIndex:12];
    return id_.length ? [NSString stringWithFormat:@"ym:%@:%@", id_, names] : [@"ym:" stringByAppendingString:names];
}

// The picture's own key: its pixels, read small. The same cover handed over again (the next song of an album) gives
// the same key, so all that was made from it carries over.
static NSString *pictureKeyOf(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    enum { side = 32 };
    uint8_t pixels[side * side * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!c) return nil;
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, side, side), cg);
    CGContextRelease(c);
    for (size_t i = 0; i < sizeof(pixels); i++) pixels[i] &= 0xF0;   // what a rescale shifts by a step does not count
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(pixels, (CC_LONG)sizeof(pixels), digest);
    NSMutableString *hex = [NSMutableString stringWithString:@"ym-pic:"];
    for (int i = 0; i < 12; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSData *thumbOf(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:16 * 16];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(data.mutableBytes, 16, 16, 8, 16, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!c) return nil;
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, 16, 16), cg);
    CGContextRelease(c);
    return data;
}

static BOOL samePicture(NSData *a, NSData *b) {
    if (a.length != 256 || b.length != 256) return NO;
    const uint8_t *x = a.bytes, *y = b.bytes;
    int sum = 0;
    for (int i = 0; i < 256; i++) sum += abs((int)x[i] - (int)y[i]);
    return sum / 256.0 < 7;
}

static CGFloat pixelsOf(UIImage *image) {
    return MIN(image.size.width, image.size.height) * image.scale;
}

static UIImage *imageOf(MPMediaItemArtwork *artwork) {
    if (![artwork isKindOfClass:MPMediaItemArtwork.class]) return nil;
    CGSize size = artwork.bounds.size;
    if (size.width < 1 || size.height < 1) size = CGSizeMake(1024, 1024);
    UIImage *image = nil;
    @try {
        image = [artwork imageWithSize:size];
    } @catch (NSException *e) {
        AULog(@"yandex: artwork refused its picture: %@", e.reason);
    }
    return image.CGImage ? image : nil;
}

static void processInfo(void) {
    [sg_lock lock];
    NSDictionary *info = sg_info;
    [sg_lock unlock];
    NSString *uri = trackURIOf(info);
    if (!uri.length) return;
    NSString *title = info[MPMediaItemPropertyTitle];
    BOOL newTrack = ![uri isEqualToString:sg_uri];
    sg_uri = uri;
    sg_title = title;
    if (newTrack) {
        static BOOL toldKeys;
        if (!toldKeys) {
            toldKeys = YES;
            AULog(@"yandex: now playing info keys: %@", [[info.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
        }
        [NSNotificationCenter.defaultCenter postNotificationName:AUTrackDidChangeNotification object:nil userInfo:@{@"uri": uri}];
    }
    MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:MPMediaItemArtwork.class]) return;
    if (artwork == sg_artwork && !newTrack) return;
    UIImage *image = imageOf(artwork);
    if (!image) return;
    sg_artwork = artwork;
    NSString *key = pictureKeyOf(image);
    if (!key) return;
    BOOL same = [key isEqualToString:sg_key] && sg_image;
    // A smaller copy of the picture already held adds nothing.
    if (same && image.size.width * image.scale <= sg_image.size.width * sg_image.scale && [sg_keyURI isEqualToString:uri]) return;
    if (!same || image.size.width * image.scale > sg_image.size.width * sg_image.scale) {
        sg_image = image;
        sg_exact = pixelsOf(image) >= 600;
        sg_thumb = thumbOf(image);
    }
    sg_key = key;
    sg_keyURI = uri;
    if (newTrack || !same) {
        AULog(@"yandex: artwork %.0f x %.0f px for \"%@\" (%@)", image.size.width * image.scale, image.size.height * image.scale, title,
              [key substringFromIndex:key.length - 6]);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:AUYandexArtworkDidChangeNotification object:nil];
}

static NSDictionary *merged(NSDictionary *info) {
    if (!info) return nil;
    if (!sg_extras.count || !sg_extrasTitle.length) return info;
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || ![title isEqualToString:sg_extrasTitle]) return info;
    NSMutableDictionary *all = [info mutableCopy];
    [all addEntriesFromDictionary:sg_extras];
    return all;
}

NSDictionary *AUYandexNowPlayingWillSet(id center, NSDictionary *info) {
    if (!sg_lock) return info;
    [sg_lock lock];
    NSMutableDictionary *own = [info mutableCopy];
    for (NSString *key in sg_extras) {
        if (own[key] && own[key] == sg_extras[key]) [own removeObjectForKey:key];   // Aura's own, put back below
    }
    if (!sg_seenOwnAnimated) {
        for (NSString *key in own) {
            if ([key containsString:@"AnimatedArtwork"]) {
                sg_seenOwnAnimated = YES;
                AULog(@"yandex: the app offers its own %@; Aura's lock screen clip takes its place", key);
                break;
            }
        }
    }
    sg_info = own ? [own copy] : nil;
    sg_center = center;
    id elapsed = own[MPNowPlayingInfoPropertyElapsedPlaybackTime], rate = own[MPNowPlayingInfoPropertyPlaybackRate];
    id duration = own[MPMediaItemPropertyPlaybackDuration];
    if ([elapsed respondsToSelector:@selector(doubleValue)]) {
        sg_elapsed = [elapsed doubleValue];
        sg_rate = [rate respondsToSelector:@selector(doubleValue)] ? [rate doubleValue] : 1;
        sg_stamp = CACurrentMediaTime();
    }
    if ([duration respondsToSelector:@selector(doubleValue)]) sg_duration = [duration doubleValue];
    NSDictionary *result = merged(sg_info);
    [sg_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{ processInfo(); });
    return result;
}

UIImage *AUYandexArtwork(NSString **trackURI, NSString **pictureKey, BOOL *exact) {
    if (trackURI) *trackURI = sg_keyURI;
    if (pictureKey) *pictureKey = sg_key;
    if (exact) *exact = sg_exact;
    return sg_image;
}

NSString *AUYandexTrackURI(void) { return sg_uri; }

double AUYandexPlaybackTime(void) {
    if (isnan(sg_elapsed)) return NAN;
    return sg_elapsed + (CACurrentMediaTime() - sg_stamp) * sg_rate;
}

BOOL AUYandexPlaying(void) { return sg_rate > 0; }
double AUYandexDuration(void) { return sg_duration; }

static NSString *infoString(NSString *key) {
    [sg_lock lock];
    id value = sg_info[key];
    [sg_lock unlock];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSString *AUYandexTrackArtist(void) { return infoString(MPMediaItemPropertyArtist); }
NSString *AUYandexTrackAlbum(void) { return infoString(MPMediaItemPropertyAlbumTitle); }

#pragma mark - seeking

static id sg_seekHandler, sg_seekTarget;
static SEL sg_seekAction;

void AUYandexRemoteHandlerAdded(id command, id handler, id target, SEL action) {
    if (command != MPRemoteCommandCenter.sharedCommandCenter.changePlaybackPositionCommand) return;
    if (handler) sg_seekHandler = [handler copy];
    else if (target && action) {
        sg_seekTarget = target;
        sg_seekAction = action;
    }
}

BOOL AUYandexSeek(double seconds) {
    Class eventClass = NSClassFromString(@"MPChangePlaybackPositionCommandEvent");
    if (!eventClass || (!sg_seekHandler && !sg_seekTarget)) {
        AULog(@"yandex: no seek handler from the app");
        return NO;
    }
    id event = [eventClass new];
    @try {
        [event setValue:@(seconds) forKey:@"positionTime"];
    } @catch (NSException *e) {
        AULog(@"yandex: the seek event takes no time: %@", e.reason);
        return NO;
    }
    if (sg_seekHandler) {
        MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *) = sg_seekHandler;
        handler(event);
    } else {
        ((void (*)(id, SEL, id))objc_msgSend)(sg_seekTarget, sg_seekAction, event);
    }
    // Shown at once, before the app reports the new position.
    sg_elapsed = seconds;
    sg_stamp = CACurrentMediaTime();
    return YES;
}
NSString *AUYandexTrackTitle(void) { return sg_title; }

NSString *AUYandexTrackPictureKey(void) {
    return [sg_keyURI isEqualToString:sg_uri] ? sg_key : nil;
}

void AUYandexSetExtras(NSDictionary *extras, NSString *title) {
    if (!sg_lock) return;
    [sg_lock lock];
    sg_extras = extras.count ? [extras copy] : nil;
    sg_extrasTitle = [title copy];
    NSDictionary *info = merged(sg_info);
    MPNowPlayingInfoCenter *center = sg_center ?: MPNowPlayingInfoCenter.defaultCenter;
    [sg_lock unlock];
    // Set again at once, through the hook (which keeps the app's own info as it was).
    if (info) center.nowPlayingInfo = info;
}

#pragma mark - the player

static BOOL visibleView(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return view.window != nil;
}

static BOOL squareEnough(CGSize size) {
    return size.width >= 200 && fabs(size.width - size.height) <= size.width * 0.05;
}

// The cover in one carousel cell: its largest square picture.
static UIView *coverInCell(UIView *cell) {
    UIView *best = nil, *layered = nil;
    CGFloat bestWidth = 0, layeredWidth = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    for (NSUInteger seen = 0; queue.count && seen < 120; seen++) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass(v.class);
        if ([name hasPrefix:@"AU"]) continue;
        if (v != cell && squareEnough(v.bounds.size) && !v.hidden && v.alpha > 0.01) {
            if ([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image && v.bounds.size.width > bestWidth) {
                best = v;
                bestWidth = v.bounds.size.width;
            } else if (v.layer.contents && v.bounds.size.width > layeredWidth) {
                layered = v;
                layeredWidth = v.bounds.size.width;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return best ?: layered;
}

static NSString *treeOf(UIView *root, int depth, int maxDepth, NSUInteger *lines) {
    if (depth > maxDepth || *lines > 90) return @"";
    (*lines)++;
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@%@ %.0fx%.0f%@%@%@%@\n", [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
                      NSStringFromClass(root.class), root.bounds.size.width, root.bounds.size.height,
                      root.hidden ? @" hidden" : @"", root.layer.cornerRadius > 0 ? [NSString stringWithFormat:@" r%.0f", root.layer.cornerRadius] : @"",
                      root.layer.mask ? @" masked" : @"", [root isKindOfClass:UIImageView.class] && ((UIImageView *)root).image ? @" image" : @""];
    for (UIView *sub in root.subviews) [out appendString:treeOf(sub, depth + 1, maxDepth, lines)];
    return out;
}

static void installGesture(UIView *view);
static BOOL miniLyricsVisible(void);

// The player's own copy of the playing cover, when it is the same picture bigger than the one in the now playing
// info: it takes that one's place.
static void offerPlayerCopy(UIView *cover, UIScrollView *list) {
    if (!sg_image || sg_exact || ![cover isKindOfClass:UIImageView.class]) return;
    if (list.isDragging || list.isDecelerating) return;
    UIImage *image = ((UIImageView *)cover).image;
    static __weak UIImage *checked;
    if (!image.CGImage || image == checked) return;
    checked = image;
    if (pixelsOf(image) < pixelsOf(sg_image) * 1.2) return;
    if (!samePicture(thumbOf(image), sg_thumb)) return;
    AULog(@"yandex: the player's copy of the cover is bigger (%.0f px over %.0f): taken", pixelsOf(image), pixelsOf(sg_image));
    sg_image = image;
    sg_exact = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:AUYandexArtworkDidChangeNotification object:nil];
}

void AUYandexArtworkViewLaidOut(UIView *view) {
    if (!visibleView(view)) return;
    static BOOL dumped;
    if (!dumped && view.bounds.size.width >= 200) {
        dumped = YES;
        NSUInteger lines = 0;
        AULog(@"yandex: the player's artwork view:\n%@", treeOf(view, 0, 9, &lines));
    }
    installGesture(view);
    Ivar ivar = class_getInstanceVariable(object_getClass(view), "carousel");
    id carousel = ivar ? object_getIvar(view, ivar) : nil;
    // 8.22: `carousel` is a PlayerCoversCarouselView holding the collection view.
    if ([carousel isKindOfClass:UIView.class] && ![carousel isKindOfClass:UICollectionView.class]) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:carousel];
        id found = nil;
        for (NSUInteger seen = 0; queue.count && seen < 30 && !found; seen++) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:UICollectionView.class]) found = v;
            else [queue addObjectsFromArray:v.subviews];
        }
        if (found) carousel = found;
    }
    static BOOL toldPlace;
    if (!toldPlace && view.bounds.size.width >= 200) {
        toldPlace = YES;
        NSMutableString *chain = [NSMutableString string];
        for (UIView *v = view; v; v = v.superview) {
            CGRect r = [v convertRect:v.bounds toView:nil];
            [chain appendFormat:@"\n  %@ %.0f,%.0f %.0fx%.0f%@", NSStringFromClass(v.class), r.origin.x, r.origin.y, r.size.width, r.size.height,
                                v.clipsToBounds ? @" clips" : @""];
        }
        AULog(@"yandex: the artwork view lies in:%@", chain);
    }
    NSArray<UIView *> *cells = nil;
    if ([carousel isKindOfClass:UICollectionView.class]) cells = [(UICollectionView *)carousel visibleCells];
    else cells = @[view];
    UIView *middle = nil;
    CGFloat nearest = CGFLOAT_MAX;
    for (UIView *cell in cells) {
        UIView *cover = coverInCell(cell);
        if (!cover.superview) continue;
        AUCoverEffectsCoverFound(cover.superview, cover);
        CGPoint center = [cover convertPoint:CGPointMake(CGRectGetMidX(cover.bounds), CGRectGetMidY(cover.bounds)) toView:nil];
        CGFloat distance = fabs(center.x - CGRectGetMidX(cover.window.bounds));
        if (distance < nearest) {
            nearest = distance;
            middle = cover;
        }
    }
    if (middle && nearest < 20) offerPlayerCopy(middle, [carousel isKindOfClass:UIScrollView.class] ? carousel : nil);
    AUYandexFillUpdate(view, [carousel isKindOfClass:UICollectionView.class] ? carousel : nil);
    // The cell in the middle: where the app folds its lyrics into the card.
    UIView *centred = nil;
    CGFloat best = CGFLOAT_MAX;
    if ([carousel isKindOfClass:UICollectionView.class]) {
        for (UICollectionViewCell *cell in [(UICollectionView *)carousel visibleCells]) {
            CGPoint c = [cell convertPoint:CGPointMake(CGRectGetMidX(cell.bounds), CGRectGetMidY(cell.bounds)) toView:nil];
            CGFloat d = fabs(c.x - CGRectGetMidX(cell.window.bounds));
            if (d < best) {
                best = d;
                centred = cell;
            }
        }
    }
    AULyricsMiniUpdate(view, centred, ^BOOL { return miniLyricsVisible(); });
}

void AUYandexArtworkCellLaidOut(UIView *cell) {
    static Class artworkView;
    if (!artworkView) artworkView = NSClassFromString(@"_TtC23MusicPlayerLandingMaple17PlayerArtworkView");
    // Coalesced: a scroll lays out several cells a frame.
    static BOOL scheduled;
    if (scheduled) return;
    for (UIView *v = cell.superview; v; v = v.superview) {
        if (![v isKindOfClass:artworkView]) continue;
        scheduled = YES;
        __weak UIView *weakView = v;
        dispatch_async(dispatch_get_main_queue(), ^{
            scheduled = NO;
            UIView *view = weakView;
            if (view) AUYandexArtworkViewLaidOut(view);
        });
        return;
    }
}

static __weak UIViewController *sPlayer;

// A Swift object's field read raw, by the offset its ObjC metadata gives; the pointer checked to be a heap object.
static void *swiftObjectField(id object, const char *name) {
    if (!object) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NULL;
    void *raw = *(void **)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
    if (!raw || ((uintptr_t)raw & 7) || !malloc_zone_from_ptr(raw)) return NULL;
    return raw;
}

// TrackLyricsViewModel.isMiniLyricsVisible: the app's lyrics folded into the cover's card.
static BOOL miniLyricsVisible(void) {
    static int told;
    UIViewController *player = sPlayer;
    void *model = swiftObjectField(player, "trackLyricsViewModel");
    if (!model) {
        if (player && told++ < 2) AULog(@"lyrics: no trackLyricsViewModel in %@", NSStringFromClass(player.class));
        return NO;
    }
    id object = (__bridge id)model;
    Ivar flag = class_getInstanceVariable(object_getClass(object), "isMiniLyricsVisible");
    if (!flag) {
        if (told++ < 2) AULog(@"lyrics: %@ has no isMiniLyricsVisible", NSStringFromClass(object_getClass(object)));
        return NO;
    }
    BOOL on = *((uint8_t *)model + ivar_getOffset(flag)) != 0;
    static int last = -1;
    if (on != last) {
        last = on;
        AULog(@"lyrics: the app's folded lyrics %@", on ? @"shown" : @"hidden");
    }
    return on;
}

UIViewController *AUYandexPlayerController(void) {
    return sPlayer;
}

UIView *AUYandexPlayerLayerOf(UIView *view) {
    UIView *root = sPlayer.viewIfLoaded;
    if (!root) return nil;
    for (UIView *v = view; v; v = v.superview) {
        if (v.superview == root) return v;
    }
    return nil;
}

void AUYandexPlayerLaidOut(UIViewController *controller) {
    sPlayer = controller;
    AULyricsPlayerLaidOut(controller);
}

#pragma mark - settings

@interface AUYandexOpener : NSObject
@end

@implementation AUYandexOpener
+ (void)open:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) AUYandexPresentSettings();
}
+ (void)push:(UIButton *)button {
    UIViewController *page = AUSettingsPage();
    if (!page) return;
    UIResponder *r = button;
    while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
    UINavigationController *nav = ((UIViewController *)r).navigationController;
    if (nav) [nav pushViewController:page animated:YES];
    else AUYandexPresentSettings();
}
@end

static char kGestureKey, kButtonKey;

// Two fingers held on the cover open Aura's page from the player.
static void installGesture(UIView *view) {
    if (objc_getAssociatedObject(view, &kGestureKey)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:AUYandexOpener.class action:@selector(open:)];
    press.numberOfTouchesRequired = 2;
    press.minimumPressDuration = 0.6;
    press.cancelsTouchesInView = NO;
    [view addGestureRecognizer:press];
    objc_setAssociatedObject(view, &kGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void AUYandexPresentSettings(void) {
    UIViewController *page = AUSettingsPage();
    UIViewController *top = AUTopViewController();
    if (!page || !top) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose primaryAction:
        [UIAction actionWithHandler:^(UIAction *action) { [nav dismissViewControllerAnimated:YES completion:nil]; }] menu:nil];
    [top presentViewController:nav animated:YES completion:nil];
}

static UITableView *tableIn(UIView *root) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger seen = 0; queue.count && seen < 60; seen++) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static UIView *auraFooter(CGFloat width) {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 84)];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"Aura · ИИ-эффекты";
    config.subtitle = @"живые обложки, экран блокировки";
    config.image = [UIImage systemImageNamed:@"sparkles"];
    config.imagePadding = 10;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.baseBackgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    config.baseForegroundColor = UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    button.configuration = config;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.frame = CGRectMake(16, 16, width - 32, 60);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [button addTarget:AUYandexOpener.class action:@selector(push:) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:button];
    return footer;
}

void AUYandexSettingsAppeared(UIViewController *controller) {
    UITableView *table = tableIn(controller.view);
    if (table && !objc_getAssociatedObject(table, &kButtonKey)) {
        if (!table.tableFooterView || table.tableFooterView.bounds.size.height < 2) {
            UIView *footer = auraFooter(MAX(table.bounds.size.width, 320));
            table.tableFooterView = footer;
            objc_setAssociatedObject(table, &kButtonKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            AULog(@"yandex: Aura's button under %@", NSStringFromClass(controller.class));
            return;
        }
    }
    if (objc_getAssociatedObject(controller, &kButtonKey) || objc_getAssociatedObject(table, &kButtonKey)) return;
    // The table has a footer of its own: a button in the bar instead.
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"] style:UIBarButtonItemStylePlain
                                                            target:AUYandexOpener.class action:@selector(openFromBar)];
    NSMutableArray *items = [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:item];
    controller.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(controller, &kButtonKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    AULog(@"yandex: Aura's button in the bar of %@", NSStringFromClass(controller.class));
}

@implementation AUYandexOpener (Bar)
+ (void)openFromBar {
    AUYandexPresentSettings();
}
@end

#pragma mark - start

void AUYandexStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_lock = [NSLock new];
        // What the app set before Aura's hook was in.
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (info) {
            [sg_lock lock];
            sg_info = [info copy];
            sg_center = MPNowPlayingInfoCenter.defaultCenter;
            [sg_lock unlock];
            processInfo();
        }
    });
}
