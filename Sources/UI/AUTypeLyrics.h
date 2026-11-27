// «Печатная машинка»: Taurus's lyrics as a lyric video types them. Only the line being sung, in Gagalin (narrowed, solid
// white with a soft glow), typed letter by letter in time with its words behind a thin cursor; each new letter comes in
// blurred and smeared and settles. The text is justified across the width and set as big as fits a box: as it grows it
// wraps and shrinks, and every letter already there slides to its new place. A new line cuts to a clean page; after the
// last word the cursor blinks.
//
// Laid inside every SGRKaraokeView of Taurus (the full-screen lyrics, the player's lyrics, the small lyrics under the
// cover, the Lyrics page's preview) over its lines, which are hidden while it shows. It reads that view's own lines and
// clock, so it follows the same source, delay and seeks as Taurus. Plain lyrics with no timing stay Taurus's.
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyTypeLyrics @"aura.type.on"            // on until switched off
#define AUKeyTypeLyricsCompact @"aura.type.compact" // the small lyrics under the cover too; on until switched off
#define AUKeyTypeLyricsSize @"aura.type.size"       // ×0.6…1.4 of the largest size
#define AUKeyTypeLyricsGlow @"aura.type.glow"       // 0…1, 0.35 unset
#define AUKeyTypeLyricsCursor @"aura.type.cursor"   // on until switched off

// A SGRKaraokeView laid out or moved to a window (Hooks/AUHooks.x).
void AUTypeLyricsKaraokeLaidOut(UIView *karaoke);
NSArray *AUTypeLyricsRows(void);   // SGModRow, for Aura's page

// The typeface itself, at a size, narrowed as the lyrics set it.
CTFontRef _Nullable AUTypeFont(CGFloat size) CF_RETURNS_NOT_RETAINED;

NS_ASSUME_NONNULL_END
