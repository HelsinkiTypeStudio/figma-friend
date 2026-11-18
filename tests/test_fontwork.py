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

# Glyph lists
path = make(False)
ans = run({"id": 8, "op": "charset", "candidates": [{"path": "/nonexistent.ttf"}, {"path": path}]})
groups = {g["label"]: g["codepoints"] for g in ans.get("groups", [])}
check(ans["ok"] and ans["path"] == path, "charset: skips an unreadable file")
check(groups == {"Uppercase": [65, 66], "Spaces": [32]}, f"charset: groups {groups}")
check(ans["totalGlyphs"] == 5 and ans["unmappedGlyphs"] == 1, "charset: counts the glyph without a Unicode value")

chars = "AÉØaéß0½.€+©˜\u0300\u2028\ue000"
fb = FontBuilder(1000, isTTF=True)
names = [".notdef"] + [f"g{i}" for i in range(len(chars))]
fb.setupGlyphOrder(names)
fb.setupCharacterMap({ord(c): f"g{i}" for i, c in enumerate(chars)})
fb.setupGlyf({n: TTGlyphPen(None).glyph() for n in names})
fb.setupHorizontalMetrics({n: (500, 0) for n in names})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({"familyName": "Many", "styleName": "Bold", "psName": "Many-Bold", "version": "Version 1.002"})
fb.setupOS2(); fb.setupPost()
path = os.path.join(tempfile.mkdtemp(), "many.ttf"); fb.save(path)
ans = run({"id": 9, "op": "charset", "candidates": [{"path": path}]})
groups = {g["label"]: "".join(map(chr, g["codepoints"])) for g in ans["groups"]}
want = {"Uppercase": "A", "Uppercase, other letters": "Ø", "Uppercase, accented": "É", "Lowercase": "a",
        "Lowercase, other letters": "ß", "Lowercase, accented": "é", "Figures": "0", "Fractions and other numbers": "½",
        "Punctuation": ".", "Currency": "€", "Math": "+", "Symbols": "©", "Accents": "˜", "Combining accents": "\u0300"}
for k, v in want.items():
    check(groups.get(k) == v, f"charset: {k} has {v!r} (got {groups.get(k)!r})")
check(ans["skipped"] == [0x2028, 0xE000], f"charset: skips invisible codepoints {ans['skipped']}")
check(ans["version"] == "Version 1.002" and ans["styleName"] == "Bold", "charset: version and style")
check(list(groups) == list(want), f"charset: group order {list(groups)}")

print("\nAll passed." if not failures else f"\n{failures} failed.")
sys.exit(1 if failures else 0)
