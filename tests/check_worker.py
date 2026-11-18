"""Development check for fontwork.py, run against figma-export-pdf test exports.

For every "-A-as-is.pdf" with its "-texts.json" (made by the test02 plugin), builds the
requests the exporter will send, runs them through fontwork.py and checks that every
returned glyph has the measurements Figma recorded.

Usage: python3 tests/check_worker.py <exports folder> <fonts folder> <path to check_glyphs.py>
"""
import sys, os, glob, json, subprocess, base64, io
from collections import defaultdict
from fontTools.ttLib import TTFont
from fontTools.cffLib import CFFFontSet
from fontTools.pens.boundsPen import ControlBoundsPen
from fontTools.misc.psCharStrings import T2OutlineExtractor
from fontTools.pens.basePen import NullPen

OUT, FONTS, CHECK = sys.argv[1], sys.argv[2], sys.argv[3]
sys.argv = ["x", OUT, FONTS]
exec(open(CHECK).read().split("# ---------- main ----------")[0])

HERE = os.path.dirname(os.path.abspath(__file__))
worker = subprocess.Popen([sys.executable, os.path.join(HERE, "..", "Resources", "fontwork.py")],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def ask(req):
    worker.stdin.write(json.dumps(req) + "\n"); worker.stdin.flush()
    return json.loads(worker.stdout.readline())

print(ask({"id": 0, "op": "ping"}))
groups = defaultdict(dict)   # (family, style, axes) -> {(code-metrics, chars): entry}
for pdf in sorted(glob.glob(os.path.join(OUT, "*-A-as-is.pdf"))):
    js = pdf.replace("-A-as-is.pdf", "-texts.json")
    if not os.path.exists(js): continue
    info = json.load(open(js))
    try: glyphs, uni, runs = read_pdf(pdf)
    except Exception: continue
    for r in runs:
        hit = node_for_run(r, info["texts"])
        if not hit: continue
        seg = segment_for(hit[1], r); fn = seg["fontName"]
        key = (fn["family"], fn["style"], json.dumps(fn.get("variationSettings") or {}, sort_keys=True))
        for code, _ in r["items"]:
            g = glyphs[code]; ch = uni.get(code, "")
            e = {"w": g["w"], "llx": g["bbox"][0], "lly": g["bbox"][1], "urx": g["bbox"][2], "chars": ch}
            groups[key][(g["w"], g["bbox"][:3], ch)] = e

total = matched = bad = 0
for (fam, style, axes), entries in sorted(groups.items()):
    files = [x for x in font_index() if x[0] == fam]
    if not files:
        print(f"{fam} {style}: not installed"); continue
    entries = list(entries.values())
    ans = ask({"id": 1, "op": "prepare", "candidates": [{"path": x[1]} for x in files], "axes": json.loads(axes), "glyphs": entries})
    if not ans.get("ok"):
        print(f"{fam} {style} {axes}: ERROR {ans.get('error')}\n{ans.get('trace')}"); continue
    data = base64.b64decode(ans["font"]); upm = ans["upm"]
    if ans["format"] == "TrueType":
        f = TTFont(io.BytesIO(data)); order = f.getGlyphOrder(); gs = f.getGlyphSet(); pen_gs = gs
        def look(gid): return f["hmtx"][order[gid]][0], gs[order[gid]]
    else:
        pen_gs = None; cs = CFFFontSet(); cs.decompile(io.BytesIO(data), None); td = cs.topDictIndex[0]
        def look(gid):
            c = td.CharStrings[td.charset[gid]]; pv = c.private
            ex = T2OutlineExtractor(NullPen(), [], [], pv.nominalWidthX, pv.defaultWidthX, pv); ex.execute(c)
            return ex.width, c
    ok = 0; misses = []
    for e, r in zip(entries, ans["glyphs"]):
        total += 1
        if r["gid"] is None:
            misses.append(f"{e['chars']!r} {r['how']} ({r.get('diff')} units)"); continue
        w, glyph = look(r["gid"])
        bp = ControlBoundsPen(pen_gs); glyph.draw(bp); bb = bp.bounds
        d = abs(w / upm - e["w"]) * upm
        if bb: d = max(d, abs(bb[0] / upm - e["llx"]) * upm, abs(bb[1] / upm - e["lly"]) * upm, abs(bb[2] / upm - e["urx"]) * upm)
        if d > 1.01: bad += 1; misses.append(f"{e['chars']!r} WRONG GLYPH, {d:.2f} units off")
        else: ok += 1; matched += 1
    print(f"{fam} {style} {axes}: {os.path.basename(ans['path'])} {ans['format']} {len(data)//1024 or 1} KB, {ok}/{len(entries)} glyphs" + ("; " + ", ".join(misses[:8]) if misses else ""))
print(f"\nAll: {matched}/{total} matched, {bad} wrong")
