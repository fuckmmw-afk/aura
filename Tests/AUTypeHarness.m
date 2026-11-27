// «Печатная машинка» (UI/AUTypeLyrics) run on its own, for Mac Catalyst in CI: a stand-in for Taurus's SGRKaraokeView
// with the same ivars, four lines of its own timed like the reference video, the view ticked in real time at 30 fps and every
// frame written as a PNG (layer tree rendered; the blur filter does not show there). Usage: aura-type-harness <out dir>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#import "UI/AUTypeLyrics.h"

// The rows of Aura's page come from Taurus, the cover's colours from the pipeline; neither is here.
SGModRow *AURowSwitch(NSString *title, NSString *subtitle, NSString *key) { return nil; }
SGModRow *AURowChoice(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) { return nil; }
SGModRow *AURowOption(NSString *title, NSString *subtitle, NSString *key) { return nil; }
SGModRow *AURowSlider(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString * (^format)(double value)) { return nil; }
SGModRow *AURowSymbol(SGModRow *row, NSString *symbol) { return row; }
SGModRow *AURowPage(NSString *title, UIViewController * (^page)(void)) { return nil; }
SGModRow *AURowStat(NSString *title, NSString * (^value)(void)) { return nil; }
SGModRow *AURowAction(NSString *title, NSString *subtitle, void (^action)(void)) { return nil; }
SGModSection *AUSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) { return nil; }
UIViewController *AUMakePage(NSString *title, NSString *intro, NSArray *sections, NSString *footer) { return nil; }
@implementation AUPipeline
+ (instancetype)shared { return nil; }
@end

@interface SGKaraokeWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSInteger start, end;
@property (nonatomic) BOOL joined;
@end
@implementation SGKaraokeWord
@end

@interface SGKaraokeLine : NSObject
@property (nonatomic, copy) NSArray<SGKaraokeWord *> *words;
@property (nonatomic) NSInteger start, end;
@property (nonatomic, strong) SGKaraokeLine *backing;
@end
@implementation SGKaraokeLine
@end

@interface FakeKaraoke : UIView {
  @public
    UIScrollView *_scroll;
    NSArray *_lines;
    BOOL _showing, _plain, _sample, _compact;
    double _clock;
}
@end
@implementation FakeKaraoke
- (UIEdgeInsets)lineInsets {
    return UIEdgeInsetsMake(70, 0, 90, 0);
}
@end

static SGKaraokeLine *line(double start, NSString *text) {
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSUInteger letters = 0;
    for (NSString *w in words) letters += w.length;
    double at = start * 1000, span = 2450;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *w in words) {
        SGKaraokeWord *word = [SGKaraokeWord new];
        double d = span * w.length / letters;
        word.text = w;
        word.start = (NSInteger)at;
        word.end = (NSInteger)(at + d * 0.9);
        [out addObject:word];
        at += d;
    }
    SGKaraokeLine *l = [SGKaraokeLine new];
    l.words = out;
    l.start = (NSInteger)(start * 1000);
    l.end = (NSInteger)at;
    return l;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *outDir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        CGRect frame = CGRectMake(0, 0, 390, 844);
        FakeKaraoke *karaoke = [[FakeKaraoke alloc] initWithFrame:frame];
        karaoke->_scroll = [[UIScrollView alloc] initWithFrame:frame];
        [karaoke addSubview:karaoke->_scroll];
        karaoke->_lines = @[line(0.517, @"Мой город — это бетон, мне всё равно, где дом"),
                            line(3.550, @"Я танцую, как вчера, я слышу ритм, да, я в нём"),
                            line(6.617, @"И на мне Yves Saint Laurent, ты рядом, слышишь, сорян"),
                            line(9.750, @"Я пишу этот текст, я ставлю две точки в конце")];
        karaoke->_showing = YES;
        AUTypeLyricsKaraokeLaidOut(karaoke);
        UIView *type = karaoke.subviews.lastObject;
        if (type == karaoke->_scroll) {
            printf("the typewriter did not join the view\n");
            return 1;
        }
        const double fps = 30, length = 12.6, scale = 2;
        size_t width = (size_t)(frame.size.width * scale), height = (size_t)(frame.size.height * scale);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CFTimeInterval began = CACurrentMediaTime();
        double worst = 0;
        for (int f = 0; f < (int)(length * fps); f++) {
            double t = f / fps;
            while (CACurrentMediaTime() - began < t) usleep(1000);
            karaoke->_clock = t * 1000;
            double ticked = CACurrentMediaTime();
            AUTypeLyricsKaraokeLaidOut(karaoke);
            ((void (*)(id, SEL, id))objc_msgSend)(type, NSSelectorFromString(@"tick:"), nil);
            worst = MAX(worst, (CACurrentMediaTime() - ticked) * 1000);
            CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
            CGContextSetRGBFillColor(context, 44 / 255.0, 22 / 255.0, 32 / 255.0, 1);
            CGContextFillRect(context, CGRectMake(0, 0, width, height));
            CGContextTranslateCTM(context, 0, height);
            CGContextScaleCTM(context, scale, -scale);
            [karaoke.layer renderInContext:context];
            CGImageRef image = CGBitmapContextCreateImage(context);
            NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
            [png writeToFile:[outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%04d.png", f]] atomically:NO];
            CGImageRelease(image);
            CGContextRelease(context);
        }
        CGColorSpaceRelease(space);
        printf("frames written; the slowest tick %.2f ms; Taurus's lines hidden: %s\n", worst, karaoke->_scroll.alpha == 0 ? "yes" : "no");
        // The lock screen's clip of the third line (no background: a dark field).
        double clipStarted = CACurrentMediaTime();
        BOOL clip = AUTypeLockTestClip([NSURL fileURLWithPath:[outDir stringByAppendingPathComponent:@"lock-line3.mp4"]], nil, karaoke->_lines, 2);
        printf("lock clip %s in %.0f ms\n", clip ? "written" : "NOT written", (CACurrentMediaTime() - clipStarted) * 1000);
        if (!clip) return 1;
        return 0;
    }
}
