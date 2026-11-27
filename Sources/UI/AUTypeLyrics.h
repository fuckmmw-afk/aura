// «Печатная машинка»: Taurus's lyrics as a lyric video types them. Only the line being sung, in Gagalin (narrowed,
// near white, tinted and glowing in the cover's colour), typed letter by letter in time with the voice behind a thin
// cursor; each new letter comes in blurred and smeared and settles. The text is justified across the width and set as
// big as fits a box: as it grows it wraps and shrinks, the letters snap to their new places with a little overshoot,
// and the gaps of a line that has just become justified open out slowly. The page floats in 3D (a pose of its own for
// each line, drifting while it is sung, cut to the next pose with the next line) and is seen through a lens that makes
// the letters near the edges a little bigger, as in the reference video.
//
// The timing: a source that times every word is followed as it is. A line timed only by its start (most LRC) is typed
// by ear: Features/AUVoice hears the sung syllables in the playing audio and each one types the next syllable of the
// line, held to the line's span (never far ahead, caught up when it falls behind). A line heard through is remembered
// for the track, so the next time it is typed exactly from the start, seeks included; with «Учиться в фоне» the lines
// are heard and remembered while the lyrics are not on screen too.
//
// Laid inside every SGRKaraokeView of Taurus (the full-screen lyrics, the player's lyrics, the small lyrics under the
// cover, the Lyrics page's preview) over its lines, which are hidden while it shows. It reads that view's own lines and
// clock. Plain lyrics with no timing stay Taurus's. Every number of the look is a setting (Aura → Текст песни).
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

NS_ASSUME_NONNULL_BEGIN

#define AUKeyTypeLyrics @"aura.type.on"             // on until switched off
#define AUKeyTypeLyricsCompact @"aura.type.compact"  // the small lyrics under the cover too; on until switched off
#define AUKeyTypeLyricsCursor @"aura.type.cursor"    // on until switched off
#define AUKeyTypeLyricsSize @"aura.type.size"        // ×0.5…1.5 of the largest size
#define AUKeyTypeLyricsGlow @"aura.type.glow"        // 0…1
#define AUKeyTypeLyricsTint @"aura.type.tint"        // 0 white … 1 the cover's colour
#define AUKeyTypeLyricsMotion @"aura.type.motion"    // the 3D float, ×0…2
#define AUKeyTypeLyricsLens @"aura.type.lens"        // −1…2, 1 as the reference
#define AUKeyTypeLyricsSnap @"aura.type.snap"        // 0 soft … 1 hard
#define AUKeyTypeLyricsGaps @"aura.type.gaps"        // s for the gaps to open out
#define AUKeyTypeLyricsSpeed @"aura.type.speed"      // ms a letter at most
#define AUKeyTypeLyricsAppear @"aura.type.appear"    // s of a new letter's blur-in
#define AUKeyTypeLyricsWidth @"aura.type.width"      // the letters' width, 0.6…1
#define AUKeyTypeLyricsPitch @"aura.type.pitch"      // line pitch in em
#define AUKeyTypeLyricsLift @"aura.type.lift"        // the text's height on screen, −0.3 lower … 0.3 higher
#define AUKeyTypeLyricsHold @"aura.type.hold"        // s a sung line stays when the next is far off
#define AUKeyTypeLyricsEar @"aura.type.ear"          // typed by ear; on until switched off
#define AUKeyTypeLyricsEarWords @"aura.type.earWords" // by ear even where the source times every word; off
#define AUKeyTypeLyricsLearn @"aura.type.learn"      // hear and remember in the background; on until switched off
#define AUKeyTypeLyricsSensitivity @"aura.type.sens" // ×0.5…2
#define AUKeyTypeLyricsOffset @"aura.type.offset"    // ms added to what is heard

// The settings and the background ear, once Taurus is found (Hooks/AUHooks.x).
void AUTypeLyricsStart(void);
// A SGRKaraokeView laid out or moved to a window (Hooks/AUHooks.x).
void AUTypeLyricsKaraokeLaidOut(UIView *karaoke);
NSArray *AUTypeLyricsRows(void);   // SGModRow, for Aura's page

// The typeface itself, at a size, narrowed as the lyrics set it.
CTFontRef _Nullable AUTypeFont(CGFloat size) CF_RETURNS_NOT_RETAINED;

NS_ASSUME_NONNULL_END
