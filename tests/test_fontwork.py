"""Self-contained check of Resources/fontwork.py with two small made-up fonts.

Run: python3 tests/test_fontwork.py
"""
import base64, io, json, os, subprocess, sys, tempfile
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.ttLib import TTFont
from fontTools.cffLib import CFFFontSet

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "Resources", "fontwork.py")

# name: (char, advance, box)
GLYPHS = {"space": (" ", 250, None), "A": ("A", 600, (20, 0, 580, 700)),
          "B": ("B", 580, (60, 0, 540, 700)), "f_f": (None, 700, (30, 0, 690, 720))}


def draw(pen, box):
    if box:
        x0, y0, x1, y1 = box
        pen.moveTo((x0, y0)); pen.lineTo((x1, y0)); pen.lineTo((x1, y1)); pen.lineTo((x0, y1)); pen.closePath()


def make(cff):
    order = [".notdef"] + list(GLYPHS)
    fb = FontBuilder(1000, isTTF=not cff)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({ord(c): g for g, (c, _, _) in GLYPHS.items() if c})
    metrics = {".notdef": (500, 0)}
    metrics.update({g: (w, b[0] if b else 0) for g, (_, w, b) in GLYPHS.items()})
    if cff:
        cs = {}
        for g in order:
            box = None if g == ".notdef" else GLYPHS[g][2]
            p = T2CharStringPen(metrics[g][0], None); draw(p, box); cs[g] = p.getCharString()
        fb.setupCFF("TestCFF", {"FullName": "TestCFF"}, cs, {})
    else:
        gl = {}
        for g in order:
            box = None if g == ".notdef" else GLYPHS[g][2]
            p = TTGlyphPen(None); draw(p, box); gl[g] = p.glyph()
        fb.setupGlyf(gl)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "Test", "styleName": "Regular", "psName": "Test-Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sCapHeight=700)
    fb.setupPost()
    path = os.path.join(tempfile.mkdtemp(), "test.otf" if cff else "test.ttf")
    fb.save(path)
    return path


def fig(g, chars, shift=0.0):
    _, w, b = GLYPHS[g]
    b = b or (0, 0, w, 1000)   # Figma's box for an empty glyph
    return {"w": w / 1000, "llx": b[0] / 1000 + shift, "lly": b[1] / 1000, "urx": b[2] / 1000, "chars": chars}


def run(req):
    p = subprocess.run([sys.executable, WORKER], input=json.dumps(req) + "\n", capture_output=True, text=True, check=True)
    return json.loads(p.stdout)


failures = 0
def check(cond, what):
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    failures += not cond


for cff in (False, True):
    kind = "CFF" if cff else "TrueType"
    path = make(cff)
    figs = [fig("A", "A"), fig("A", "a"), fig("space", " "), fig("f_f", "ff"), fig("B", "B", shift=0.01), fig("B", "B", shift=0.0008)]
    ans = run({"id": 7, "op": "prepare", "candidates": [{"path": "/nonexistent.ttf"}, {"path": path}], "axes": {}, "glyphs": figs})
    check(ans["ok"] and ans["id"] == 7, f"{kind}: answered")
    check(ans["format"] == kind, f"{kind}: format {ans['format']}")
    got = [g["gid"] for g in ans["glyphs"]]
    hows = [g["how"] for g in ans["glyphs"]]
    check(hows[:4] == ["char", "char", "char", "metrics"], f"{kind}: A, a (same glyph), space, ligature found: {hows[:4]}")
    check(got[4] is None and hows[4] == "no match", f"{kind}: B moved by 10 units is refused")
    check(got[5] is not None, f"{kind}: B within 1 unit is accepted")
    check(ans["tried"][0].get("error") and ans["tried"][1].get("matched") == 5, f"{kind}: unreadable candidate skipped, real file used")
    check(ans["ascent"] == 800 and ans["descent"] == -200 and ans["capHeight"] == 700, f"{kind}: font metrics")
    data = base64.b64decode(ans["font"])
    if cff:
        cs = CFFFontSet(); cs.decompile(io.BytesIO(data), None); td = cs.topDictIndex[0]
        check(got[:4] == [1, 2, 3, 4] and len(td.charset) == 6, f"{kind}: one glyph per matched entry, in order: {got}")
    else:
        f = TTFont(io.BytesIO(data)); order = f.getGlyphOrder()
        check(order[got[0]] == "A" and got[0] == got[1] and order[got[3]] == "f_f", f"{kind}: glyph ids point at the right glyphs: {got}")
        check("GSUB" not in f and len(order) == 5, f"{kind}: subset to 5 glyphs without layout tables")

print("\nAll passed." if not failures else f"\n{failures} failed.")
sys.exit(1 if failures else 0)
