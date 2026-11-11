"""Font work for Font Helper: fix variable fonts, check glyphs, subset.

Font Helper runs this as a long-lived process. Each request is one JSON line on stdin,
and each answer is one JSON line on stdout. The font file is read fresh for every request.

Request:
  {"id": 1, "op": "prepare",
   "candidates": [{"path": "/Users/.../Font.ttf", "fontNumber": 0}, ...],
   "axes": {"wght": 585, "opsz": 24},
   "glyphs": [{"w": 0.512, "llx": 0.03, "lly": -0.01, "urx": 0.48, "chars": "a"}, ...]}

  Glyph measurements are in em, as in the hidden text layer of Figma's PDF export:
  advance width and the left, bottom and right edges of the bounding box.

Answer:
  {"id": 1, "ok": true, "path": "<the file used>", "format": "TrueType" | "CFF", "font": "<base64>",
   "glyphs": [{"gid": 5, "how": "char"} | {"gid": null, "how": "no match", "diff": 0.004}, ...],
   "postScriptName": ..., "upm": ..., "ascent": ..., "descent": ..., "capHeight": ...,
   "italicAngle": ..., "bbox": [...], "fixedPitch": false, "serif": false}

  Every glyph entry that matched gets its own glyph id in the returned font, in request
  order, so a glyph that Figma used for two characters (s and S under the capitals option)
  can carry each character separately. For TrueType the ids are glyph ids in the subset
  font. For CFF the font is built so that each matched entry has its own glyph, and the
  id is both its glyph id and its CID.
"""
import sys, json, base64, io, traceback, unicodedata

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.boundsPen import ControlBoundsPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.fontBuilder import FontBuilder
from fontTools import subset

# Figma rounds outline coordinates to whole font units, and fixing a variable font can
# round a point differently. Tests 3 and 5 found every difference within one unit.
TOLERANCE_UNITS = 1.0


def load_instance(path, font_number, axes):
    with open(path, "rb") as fh:
        data = fh.read()
    font = TTFont(io.BytesIO(data), fontNumber=font_number, lazy=False)
    if "fvar" in font:
        limits = {}
        for a in font["fvar"].axes:
            v = axes.get(a.axisTag, a.defaultValue)
            limits[a.axisTag] = max(a.minValue, min(a.maxValue, float(v)))
        font = instancer.instantiateVariableFont(font, limits, updateFontNames=False)
        # Re-read so every table is in its plain, compiled-and-parsed form.
        buf = io.BytesIO()
        font.save(buf)
        font = TTFont(io.BytesIO(buf.getvalue()))
    return font


def glyph_metrics(font):
    upm = font["head"].unitsPerEm
    gs = font.getGlyphSet()
    hmtx = font["hmtx"].metrics
    out = {}
    for g in font.getGlyphOrder():
        # Figma's boxes are the box around all points, control points included (test 13).
        bp = ControlBoundsPen(gs)
        gs[g].draw(bp)
        out[g] = (hmtx[g][0] / upm, tuple(v / upm for v in bp.bounds) if bp.bounds else None)
    return out


def match(metrics, cmap, upm, fig):
    """Find the font glyph with the same width and left, bottom and right edges.

    Figma's top edge does not match the glyph's real top (test 3), so it is left out.
    Candidates come from the characters first, then from all glyphs (ligatures, alternates).
    """
    tol = TOLERANCE_UNITS / upm + 1e-6

    def diff(g):
        w, bb = metrics[g]
        if bb is None:
            # A glyph with no outline, like a space. Figma gives it a box from 0 to its
            # width and from the baseline up 1 em, so only the width can be compared.
            return abs(w - fig["w"])
        return max(abs(w - fig["w"]), abs(bb[0] - fig["llx"]), abs(bb[1] - fig["lly"]), abs(bb[2] - fig["urx"]))

    chars = unicodedata.normalize("NFC", fig.get("chars") or "")
    cands = []
    for ch in chars + chars.upper() + chars.lower():
        g = cmap.get(ord(ch))
        if g and g not in cands:
            cands.append(g)
    by_char = sorted(cands, key=diff)
    if by_char and diff(by_char[0]) <= tol:
        return by_char[0], "char", diff(by_char[0])
    close = [g for g in metrics if diff(g) <= tol]
    if len(close) == 1:
        return close[0], "metrics", diff(close[0])
    if len(close) > 1:
        return None, f"ambiguous ({len(close)} glyphs)", diff(close[0])
    best = by_char[0] if by_char else None
    return None, "no match", (diff(best) if best else None)


def font_info(font):
    upm = font["head"].unitsPerEm
    os2 = font["OS/2"] if "OS/2" in font else None
    post = font["post"]
    hhea = font["hhea"]
    head = font["head"]
    name = font["name"]
    ps = name.getDebugName(6) or "Font"
    k = 1000.0 / upm
    fam_class = (getattr(os2, "sFamilyClass", 0) >> 8) if os2 else 0
    return {
        "postScriptName": "".join(c for c in ps if c.isalnum() or c in "-_") or "Font",
        "familyName": name.getDebugName(16) or name.getDebugName(1),
        "upm": upm,
        "ascent": round((os2.sTypoAscender if os2 else hhea.ascent) * k),
        "descent": round((os2.sTypoDescender if os2 else hhea.descent) * k),
        "capHeight": round((getattr(os2, "sCapHeight", 0) or (os2.sTypoAscender if os2 else hhea.ascent)) * k),
        "italicAngle": float(post.italicAngle),
        "bbox": [round(head.xMin * k), round(head.yMin * k), round(head.xMax * k), round(head.yMax * k)],
        "fixedPitch": bool(post.isFixedPitch),
        "serif": fam_class in (1, 2, 3, 4, 5, 7),
    }


def subset_truetype(font, wanted):
    """Subset a glyf font to the wanted glyph names. Returns (bytes, new glyph order)."""
    opts = subset.Options()
    opts.layout_features = []
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = False
    opts.drop_tables += ["GSUB", "GPOS", "GDEF", "BASE", "JSTF", "MATH", "STAT", "DSIG", "meta", "kern"]
    opts.glyph_names = True
    sub = subset.Subsetter(opts)
    sub.populate(glyphs=sorted(set(wanted)))
    sub.subset(font)
    buf = io.BytesIO()
    font.save(buf)
    return buf.getvalue(), font.getGlyphOrder()


def build_cff(font, entries, info):
    """Build a bare CFF font program with one glyph per matched entry, in order.

    The PDF embeds it as CIDFontType0C. It isn't CID-keyed, so a PDF reader uses each
    CID directly as the glyph number.
    """
    gs = font.getGlyphSet()
    hmtx = font["hmtx"].metrics
    order = [".notdef"]
    charstrings = {}
    pen = T2CharStringPen(hmtx[".notdef"][0], gs)
    gs[".notdef"].draw(pen)
    charstrings[".notdef"] = pen.getCharString()
    for i, g in enumerate(entries):
        if g is None:
            continue
        n = f"g{i + 1}"
        pen = T2CharStringPen(hmtx[g][0], gs)
        gs[g].draw(pen)
        charstrings[n] = pen.getCharString()
        order.append(n)
    upm = info["upm"]
    fb = FontBuilder(upm, isTTF=False)
    fb.setupGlyphOrder(order)
    ps = info["postScriptName"]
    fb.setupCFF(ps, {"FullName": ps, "FamilyName": info.get("familyName") or ps, "Weight": "Regular"},
                charstrings, {})
    cff = fb.font["CFF "]
    return cff.compile(fb.font), order


def check(path, font_number, axes, figs):
    font = load_instance(path, font_number, axes)
    upm = font["head"].unitsPerEm
    metrics = glyph_metrics(font)
    cmap = font.getBestCmap() or {}
    results, names = [], []
    for fig in figs:
        g, how, d = match(metrics, cmap, upm, fig)
        names.append(g)
        r = {"how": how}
        if d is not None:
            r["diff"] = round(d * upm, 3)
        results.append(r)
    return font, results, names


def axis_options(path, font_number, style, axes):
    """The axis values to try for a file, best guess first.

    Figma usually reports the axis values it drew with, but not always: text set in a named
    style of a variable font (say Popular Regular) can come with the axes' minimum values
    (wght 100) while Figma draws the named style (wght 400). So the named style whose name
    matches is tried too.
    """
    opts = [dict(axes)]
    try:
        font = TTFont(path, fontNumber=font_number, lazy=True)
        if "fvar" in font:
            name = font["name"]
            for inst in font["fvar"].instances:
                n = name.getDebugName(inst.subfamilyNameID) or ""
                if n.strip().lower() == (style or "").strip().lower():
                    coords = {k: float(v) for k, v in inst.coordinates.items()}
                    if coords != {k: float(v) for k, v in axes.items()}:
                        opts.append(coords)
                    break
    except Exception:
        pass
    return opts


def prepare(req):
    """Check the glyphs against each candidate file and build a font from the best one.

    A family can have several installed files (static styles, a variable font, an older
    build). The file whose glyphs match Figma's most often is the one Figma drew with.
    """
    cands = req.get("candidates") or [{"path": req["path"], "fontNumber": req.get("fontNumber", 0)}]
    axes = req.get("axes") or {}
    best = None
    tried = []
    done = False
    for c in cands:
        fnum = int(c.get("fontNumber", 0))
        for ax in axis_options(c["path"], fnum, req.get("style"), axes):
            try:
                font, results, names = check(c["path"], fnum, ax, req["glyphs"])
            except Exception as e:
                tried.append({"path": c["path"], "axes": ax, "error": f"{type(e).__name__}: {e}"})
                break
            n = sum(1 for g in names if g)
            tried.append({"path": c["path"], "axes": ax, "matched": n})
            if best is None or n > best[0]:
                best = (n, c, font, results, names)
            if n == len(names):
                done = True
                break
        if done:
            break
    if best is None:
        return {"ok": False, "error": "no candidate file could be read", "tried": tried}
    n, cand, font, results, names = best
    info = font_info(font)

    if "CFF " in font or "CFF2" in font:
        data, _ = build_cff(font, names, info)
        fmt = "CFF"
        k = 0
        for r, g in zip(results, names):
            if g is None:
                r["gid"] = None
            else:
                k += 1
                r["gid"] = k
    else:
        data, order = subset_truetype(font, [".notdef"] + [g for g in names if g])
        fmt = "TrueType"
        for r, g in zip(results, names):
            r["gid"] = order.index(g) if g else None
    out = {"ok": True, "path": cand["path"], "tried": tried, "format": fmt,
           "font": base64.b64encode(data).decode("ascii"), "glyphs": results}
    out.update(info)
    return out


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            if req.get("op") == "prepare":
                ans = prepare(req)
            elif req.get("op") == "ping":
                import fontTools
                ans = {"ok": True, "fontTools": fontTools.version, "python": sys.version.split()[0]}
            else:
                ans = {"ok": False, "error": f"unknown op {req.get('op')!r}"}
        except Exception as e:
            ans = {"ok": False, "error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc(limit=3)}
        ans["id"] = rid
        sys.stdout.write(json.dumps(ans) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
