"""Check of hidden codes in Resources/fontwork.py: a test build from Export Test Font gives every
glyph without a Unicode value a code in plane 15, and proof-pages type /six.lf as that code and
save it back as /six.lf.

Run: python3 tests/test_proofbook_hidden.py
"""
import json, os, subprocess, sys, tempfile
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "Resources", "fontwork.py")
TRASH = tempfile.mkdtemp()
SIX_LF, ZERO_DNOM, A_SS01 = 0xF1234, 0xF0001, 0xF00A0


def make_font(path):
    names = [".notdef", "six", "zero", "a", "six.lf", "zero.dnom", "a.ss01", "f_f"]
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(names)
    # f_f has no code here: as in a test build exported before hidden codes.
    fb.setupCharacterMap({0x36: "six", 0x30: "zero", 0x61: "a", SIX_LF: "six.lf", ZERO_DNOM: "zero.dnom",
                          A_SS01: "a.ss01"})
    pen = TTGlyphPen(None)
    fb.setupGlyf({n: pen.glyph() for n in names})
    fb.setupHorizontalMetrics({n: (500, 0) for n in names})
    fb.setupHorizontalHeader()
    fb.setupNameTable({"familyName": "Maamme TEST0016", "styleName": "Regular"})
    fb.setupOS2()
    fb.setupPost()   # keeps glyph names
    fb.save(path)


def write(folder, rel, text):
    path = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def read(folder, rel):
    with open(os.path.join(folder, rel), encoding="utf-8", newline="") as fh:
        return fh.read()


def ask(req):
    out = subprocess.run([sys.executable, WORKER], input=json.dumps(req) + "\n", capture_output=True,
                         text=True, check=True, env=dict(os.environ, PROOFBOOK_TRASH=TRASH)).stdout
    return json.loads(out)


font = os.path.join(tempfile.mkdtemp(), "MaammeTEST0016.ttf")
make_font(font)
fonts = [font, font + "-missing.otf"]   # a file that can't be read is passed over
six, zero, ss01 = chr(SIX_LF), chr(ZERO_DNOM), chr(A_SS01)

book = tempfile.mkdtemp()
write(book, "figures.txt", "---\nstatus: wip\n---\nH/six.lf/zero.dnom H\n/a.ss01 b /f_f\nplain 60\n")
write(book, "other.txt", "/six.lf\n")

# Reading: names in the font become their hidden codes; others are untypable as before.
a = ask({"op": "proofbook", "folder": book, "fonts": fonts})
assert a["ok"] and a["hiddenCodes"] == 3, a
pages = {p["path"]: p for p in a["pages"]}
fig = pages["figures.txt"]
assert fig["text"] == f"H{six}{zero}H\n{ss01}b  \nplain 60\n", repr(fig["text"])
assert fig["untypable"] == ["f_f"], fig["untypable"]
# Without the fonts nothing changes.
plain = {p["path"]: p for p in ask({"op": "proofbook", "folder": book})["pages"]}
assert plain["figures.txt"]["text"] == "H  H\n b  \nplain 60\n"
assert ask({"op": "proofbook", "folder": book})["hiddenCodes"] == 0

laid = fig["text"].rstrip()

# Saving: an untouched line keeps its glyph names exactly; an edited one gets them back from the codes.
edited = laid.replace("plain 60", f"plain {six}0 {zero}{six}x")
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "figures.txt", "from": "figures.txt", "laid": laid, "text": edited}]})
assert r["files"] == [{"ok": True}], r
assert read(book, "figures.txt") == "---\nstatus: wip\n---\nH/six.lf/zero.dnom H\n/a.ss01 b /f_f\nplain /six.lf 0 /zero.dnom/six.lf x\n", repr(read(book, "figures.txt"))

# A line typed at the end of a name: no space after the last name on a line.
laid = pages["other.txt"]["text"].rstrip()
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "other.txt", "from": "other.txt", "laid": laid, "text": f"{six}\n12{six}"}]})
assert r["files"] == [{"ok": True}], r
assert read(book, "other.txt") == "/six.lf\n12/six.lf\n", repr(read(book, "other.txt"))

# A new page made in Figma gets glyph names too.
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "new.txt", "from": None, "laid": None, "text": f"{ss01}{ss01}a"}]})
assert r["files"] == [{"ok": True}] and read(book, "new.txt") == "/a.ss01/a.ss01 a\n", read(book, "new.txt")

# A frame laid out before the font had hidden codes (spaces for alternates) still saves.
write(book, "old.txt", "x/six.lf y\nkeep /a.ss01\n")
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "old.txt", "from": "old.txt", "laid": "x y\nkeep", "text": "x y\nkeep\nmore"}]})
assert r["files"] == [{"ok": True}], r
assert read(book, "old.txt") == "x/six.lf y\nkeep /a.ss01\nmore\n", repr(read(book, "old.txt"))

# Editing a line whose glyph has no hidden code still refuses, as before.
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "figures.txt", "from": "figures.txt",
                    "laid": ask({"op": "proofbook", "folder": book, "fonts": fonts})["pages"][0]["text"].rstrip(),
                    "text": f"H{six}{zero}H\nchanged\nplain {six}0 {zero}{six}x"}]})
assert not r["files"][0]["ok"] and "/f_f" in r["files"][0]["reason"], r
print("hidden codes: all checks passed")

# A page ending in a glyph shown as a space: the trimmed last line still counts as unchanged.
write(book, "end.txt", "keep /f_f\n")
r = ask({"op": "proofbook-apply", "folder": book, "fonts": fonts,
         "files": [{"path": "end.txt", "from": "end.txt", "laid": "keep", "text": "first\nkeep"}]})
assert r["files"] == [{"ok": True}] and read(book, "end.txt") == "first\nkeep /f_f\n", (r, read(book, "end.txt"))
print("trimmed last line: passed")
