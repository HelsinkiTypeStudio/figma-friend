"""Font work for Figma Friend: fix variable fonts, check glyphs, subset.

Figma Friend runs this as a long-lived process. Each request is one JSON line on stdin,
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
   "glyphs": [{"gid": 5, "how": "char", "box": [xMin, yMin, xMax, yMax] in em} |
              {"gid": null, "how": "no match", "diff": 4.2 (font units)}, ...],
   "postScriptName": ..., "upm": ..., "ascent": ..., "descent": ..., "capHeight": ...,
   "italicAngle": ..., "bbox": [...], "fixedPitch": false, "serif": false}

  Every glyph entry that matched gets its own glyph id in the returned font, in request
  order, so a glyph that Figma used for two characters (s and S under the capitals option)
  can carry each character separately. For TrueType the ids are glyph ids in the subset
  font. For CFF the font is built so that each matched entry has its own glyph, and the
  id is both its glyph id and its CID.

Request:
  {"id": 2, "op": "charset", "candidates": [{"path": ..., "fontNumber": 0}, ...]}

Answer (for glyph lists): every character the first readable file maps, grouped for proofing.
  {"id": 2, "ok": true, "path": ..., "familyName", "styleName", "version", "modified": <unix time>,
   "totalGlyphs": 545, "mappedGlyphs": 467, "unmappedGlyphs": 78, "skipped": [codepoints],
   "groups": [{"label": "Uppercase", "codepoints": [65, 66, ...]}, ...]}

  Glyphs without a Unicode value (alternates, .ss01) can't be typed, so they are only counted.
  Invisible codepoints (controls, private use, line and paragraph separators) are skipped.

Request:
  {"id": 3, "op": "proofbook", "folder": "/Users/.../proofbook"}

Answer (for figma-proofbook): every proof-page in a ProofBook folder, as plain text to set in Figma.
  {"id": 3, "ok": true, "folder": ..., "name": "<folder name>",
   "pages": [{"path": "01-Latin-LC/a-z.txt", "section": "01-Latin-LC", "name": "a-z", "text": "...",
              "untypable": ["a.ss01", ...]}, ...],
   "skipped": [{"path": ..., "reason": "not downloaded" | "..."}],
   "styles": <figma-styles.json beside the pages, or null>}

  A page is any .txt file in the folder or a folder inside it, in alphabetical order. Its
  ProofBook header (line 1 is ---, up to the next ---) is left out. Glyphs-style glyph names
  (/a, /uni00E9, /infinity) become the characters they stand for; a name that can't be typed
  (an alternate such as /a.ss01) becomes a space and is listed in "untypable". Files iCloud
  has not downloaded are skipped rather than read, since reading one can hang.

Request:
  {"id": 4, "op": "proofbook-save", "folder": "/Users/.../proofbook",
   "pages": [{"path": "01-Latin-LC/a-z.txt", "laid": "<text as laid out>", "edited": "<text now>"}]}

Answer (for figma-proofbook): writes edits made in Figma back to the proof-pages.
  {"id": 4, "ok": true, "pages": [{"path": ..., "saved": true, "text": "<new text, typed>",
                                   "untypable": [...]}
                                  | {"path": ..., "saved": false, "reason": "..."}]}

  "laid" is the text the page was laid out with. If the file no longer gives that text, it was
  changed on disk since (in Glyphs, say) and is left alone. The header is kept as it is, and so
  is every line that wasn't edited, glyph names and all; an edited line is written as typed. A
  page where an edited line held a name that can't be typed (/a.ss01, shown as a space) is left
  alone too, since writing it would lose the name.
"""
import sys, os, re, json, base64, io, traceback, unicodedata, difflib

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.boundsPen import ControlBoundsPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.fontBuilder import FontBuilder
from fontTools import subset
from fontTools import agl

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
        if g is not None:
            # The glyph's box in em, top edge included, so the exporter can tell which
            # outlines in Figma's PDF belong to it.
            bb = metrics[g][1]
            r["box"] = [round(v, 6) for v in bb] if bb else None
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


# Glyph lists: groups in proofing order, as (label, general categories, letter kind).
SKIPPED_CATEGORIES = {"Cc", "Cf", "Co", "Cs", "Zl", "Zp"}
BASIC_LATIN = set(range(0x41, 0x5B)) | set(range(0x61, 0x7B))
CHARSET_GROUPS = [
    ("Uppercase", {"Lu", "Lt"}, "basic"),
    ("Uppercase, other letters", {"Lu", "Lt"}, "plain"),
    ("Uppercase, accented", {"Lu", "Lt"}, "accented"),
    ("Lowercase", {"Ll"}, "basic"),
    ("Lowercase, other letters", {"Ll"}, "plain"),
    ("Lowercase, accented", {"Ll"}, "accented"),
    ("Other letters", {"Lm", "Lo"}, None),
    ("Figures", {"Nd"}, None),
    ("Fractions and other numbers", {"No", "Nl"}, None),
    ("Punctuation", {"Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"}, None),
    ("Currency", {"Sc"}, None),
    ("Math", {"Sm"}, None),
    ("Symbols", {"So"}, None),
    ("Accents", {"Sk"}, None),
    ("Combining accents", {"Mn", "Mc", "Me"}, None),
    ("Spaces", {"Zs"}, None),
]


def letter_kind(cp):
    """basic (A-Z, a-z), accented (decomposes to a letter plus accents) or plain (Ø, Æ, Þ, ß)."""
    if cp in BASIC_LATIN:
        return "basic"
    d = unicodedata.normalize("NFD", chr(cp))
    if len(d) > 1 and all(unicodedata.category(c).startswith("M") for c in d[1:]):
        return "accented"
    return "plain"


def charset(req):
    """Every character a font maps, grouped. The first file that can be read is used:
    Figma Friend lists the exact family-and-style match first."""
    errors = []
    for c in req.get("candidates") or []:
        try:
            font = TTFont(c["path"], fontNumber=int(c.get("fontNumber", 0)), lazy=True)
            cmap = font.getBestCmap() or {}
            order = font.getGlyphOrder()
        except Exception as e:
            errors.append(f"{c['path']}: {type(e).__name__}: {e}")
            continue
        by_cat, skipped = {}, []
        for cp in sorted(cmap):
            cat = unicodedata.category(chr(cp))
            if cat in SKIPPED_CATEGORIES:
                skipped.append(cp)
            else:
                by_cat.setdefault(cat, []).append(cp)
        groups, claimed = [], set()
        for label, cats, kind in CHARSET_GROUPS:
            cps = sorted(cp for cat in cats for cp in by_cat.get(cat, []) if not kind or letter_kind(cp) == kind)
            claimed |= cats
            if cps:
                groups.append({"label": label, "codepoints": cps})
        # Anything else (codepoints newer than this Python's Unicode data, say) still shows up.
        rest = sorted(cp for cat, cps in by_cat.items() if cat not in claimed for cp in cps)
        if rest:
            groups.append({"label": "Other", "codepoints": rest})
        mapped = set(cmap.values())
        name = font["name"]
        return {"ok": True, "path": c["path"],
                "familyName": name.getDebugName(16) or name.getDebugName(1),
                "styleName": name.getDebugName(17) or name.getDebugName(2),
                "version": name.getDebugName(5),
                "modified": int(os.path.getmtime(c["path"])),
                "totalGlyphs": len(order),
                "mappedGlyphs": len(mapped),
                "unmappedGlyphs": sum(1 for g in order if g not in mapped and g != ".notdef"),
                "skipped": skipped, "groups": groups}
    return {"ok": False, "error": "no candidate file could be read", "tried": errors}


# ---------- proof-books (figma-proofbook) ----------

PROOFBOOK_STYLES = "figma-styles.json"
SF_DATALESS = 0x40000000   # macOS: an iCloud file whose contents are not on this Mac
# Glyphs' way of typing a glyph by name: a slash, the name, and an optional space that ends it.
GLYPH_NAME = re.compile(r"/([A-Za-z_][A-Za-z0-9._-]*) ?")


def proof_text(raw):
    """The proof text of a page: ProofBook's header (line 1 is ---, up to the next ---) left out.
    A header that never closes is proof text, as ProofBook reads it."""
    lines = raw.split("\n")
    if lines and lines[0].rstrip("\r") == "---":
        for i in range(1, len(lines)):
            if lines[i].rstrip("\r") == "---":
                return "\n".join(lines[i + 1:])
    return raw


def glyph_char(name):
    """The character a glyph name stands for, or None when it can't be typed (an alternate,
    a ligature, a name with a suffix)."""
    if "." in name:
        return None
    u = agl.toUnicode(name)
    return u if len(u) == 1 else None


def typed(text, untypable):
    def one(m):
        c = glyph_char(m.group(1))
        if c is None:
            untypable.append(m.group(1))
            return " "
        return c
    return GLYPH_NAME.sub(one, text)


def split_page(raw):
    """(header, proof text), with header + proof text == raw. The header is "" when there is none."""
    lines = raw.split("\n")
    if lines and lines[0].rstrip("\r") == "---":
        for i in range(1, len(lines)):
            if lines[i].rstrip("\r") == "---":
                head = "\n".join(lines[:i + 1]) + "\n"
                return head, raw[len(head):]
    return "", raw


def merge_edit(body, laid, edited):
    """The new proof text, or (None, reason). Untouched lines are kept exactly as in the file."""
    core = body.rstrip()
    tail = body[len(core):]
    original = core.split("\n")
    shown = [typed(line, []) for line in original]
    if "\n".join(shown) != laid.rstrip():
        return None, "changed on disk since it was laid out"
    edited = edited.replace("\u2028", "\n").replace("\r\n", "\n").replace("\r", "\n").rstrip()
    new = edited.split("\n")
    out, lost = [], []
    ops = difflib.SequenceMatcher(None, shown, new, autojunk=False).get_opcodes()
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            out += original[i1:i2]
            continue
        if tag == "replace":
            for line in original[i1:i2]:
                typed(line, lost)
        out += new[j1:j2]
    if lost:
        return None, "an edited line had " + ", ".join("/" + n for n in lost) + ", which can't be typed in Figma"
    return "\n".join(out) + tail, None


def save_page(folder, page):
    rel = page.get("path") or ""
    result = {"path": rel, "saved": False}
    root = os.path.realpath(folder)
    path = os.path.realpath(os.path.join(root, rel))
    if not path.startswith(root + os.sep) or not path.lower().endswith(".txt") or not os.path.isfile(path):
        result["reason"] = "not a page in the proof-book folder"
        return result
    try:
        if getattr(os.lstat(path), "st_flags", 0) & SF_DATALESS:
            result["reason"] = "not downloaded"
            return result
        with open(path, "rb") as fh:
            raw = fh.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        result["reason"] = str(e)
        return result
    crlf = "\r\n" in raw
    head, body = split_page(raw.replace("\r\n", "\n"))
    new_body, reason = merge_edit(body, page.get("laid") or "", page.get("edited") or "")
    if new_body is None:
        result["reason"] = reason
        return result
    if new_body != body:
        text = head + new_body
        if crlf:
            text = text.replace("\n", "\r\n")
        try:
            # Written in place, so the file keeps its Finder tags and other attributes.
            with open(path, "wb") as fh:
                fh.write(text.encode("utf-8"))
        except OSError as e:
            result["reason"] = str(e)
            return result
    untypable = []
    result.update(saved=True, text=typed(new_body, untypable), untypable=untypable)
    return result


def proofbook_save(req):
    folder = req.get("folder") or ""
    if not os.path.isdir(folder):
        return {"ok": False, "error": f"no folder at {folder}"}
    return {"ok": True, "pages": [save_page(folder, p) for p in req.get("pages") or []]}


def proofbook(req):
    folder = req.get("folder") or ""
    if not os.path.isdir(folder):
        return {"ok": False, "error": f"no folder at {folder}"}
    found = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.lower().endswith(".txt") and not f.startswith("."):
                found.append(os.path.relpath(os.path.join(root, f), folder))
    found.sort(key=lambda p: [part.casefold() for part in p.split(os.sep)])
    pages, skipped = [], []
    for rel in found:
        path = os.path.join(folder, rel)
        try:
            if getattr(os.lstat(path), "st_flags", 0) & SF_DATALESS:
                skipped.append({"path": rel, "reason": "not downloaded"})
                continue
            with open(path, "rb") as fh:
                raw = fh.read().decode("utf-8", errors="replace")
        except OSError as e:
            skipped.append({"path": rel, "reason": str(e)})
            continue
        untypable = []
        text = typed(proof_text(raw.replace("\r\n", "\n")), untypable)
        section = os.path.dirname(rel)
        pages.append({"path": rel, "section": section.replace(os.sep, " / "),
                      "name": os.path.basename(rel)[:-4], "text": text, "untypable": untypable})
    styles = None
    sp = os.path.join(folder, PROOFBOOK_STYLES)
    if os.path.isfile(sp):
        try:
            with open(sp, encoding="utf-8") as fh:
                styles = json.load(fh)
        except (OSError, ValueError) as e:
            styles = {"error": f"{PROOFBOOK_STYLES} could not be read: {e}"}
    return {"ok": True, "folder": folder, "name": os.path.basename(os.path.normpath(folder)),
            "pages": pages, "skipped": skipped, "styles": styles}


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
            elif req.get("op") == "charset":
                ans = charset(req)
            elif req.get("op") == "proofbook":
                ans = proofbook(req)
            elif req.get("op") == "proofbook-save":
                ans = proofbook_save(req)
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
