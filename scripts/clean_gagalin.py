# Gagalin without its rough texture: the small holes inside each glyph dropped, the letters solid as in the reference.
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.areaPen import AreaPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools import subset
src, dst, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
f = TTFont(src)
gs = f.getGlyphSet()
cff = f['CFF '].cff
top = cff[cff.fontNames[0]]
cs = top.CharStrings
dropped = 0
for name in f.getGlyphOrder():
    p = DecomposingRecordingPen(gs); gs[name].draw(p)
    conts, cur = [], []
    for op, args in p.value:
        cur.append((op, args))
        if op in ('closePath', 'endPath'): conts.append(cur); cur = []
    areas = []
    for c in conts:
        ap = AreaPen()
        for op, args in c: getattr(ap, op)(*args)
        areas.append(ap.value)
    outer = max(areas, key=abs) if areas else 0
    keep = []
    for c, a in zip(conts, areas):
        # a hole is wound against the glyph's biggest contour (some glyphs are wound the other way round)
        if a * outer < 0 and abs(a) < limit: dropped += 1; continue
        keep.append(c)
    pen = T2CharStringPen(gs[name].width, gs)
    for c in keep:
        for op, args in c: getattr(pen, op)(*args)
    new = pen.getCharString(private=cs[name].private, globalSubrs=cs[name].globalSubrs)
    cs[name].bytecode = None
    cs[name].program = new.program
print('holes dropped', dropped)
opts = subset.Options(); opts.layout_features = ['kern', 'liga']; opts.name_IDs = ['*']; opts.notdef_outline = True
sub = subset.Subsetter(opts)
text = ''.join(chr(c) for c in range(0x20, 0x7f)) + ''.join(chr(c) for c in range(0x400, 0x460)) + '–—‘’‚“”„«»…•№€¡¿ÀÁÂÄÇÈÉÊËÌÍÎÏÑÒÓÔÖÙÚÛÜàáâäçèéêëìíîïñòóôöùúûüßÆæŒœØøÅåĄąĆćĘęŁłŃńŚśŹźŻżŠšŽžČčŘřĚěŮůÝýĞğİıŞş'
sub.populate(text=text); sub.subset(f)
f.save(dst)
