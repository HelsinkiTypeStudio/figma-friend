"""Check of making a proof-book folder match the Figma page, in Resources/fontwork.py
(op "proofbook-apply").

Run: python3 tests/test_proofbook_apply.py
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "Resources", "fontwork.py")
TRASH = tempfile.mkdtemp()


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


def laid(book, rel):
    """The text figma-proofbook laid the page out with: as read, trailing space trimmed."""
    pages = {p["path"]: p for p in ask({"op": "proofbook", "folder": book})["pages"]}
    return pages[rel]["text"].rstrip()


def edit(book, rel, text, to=None, laid_text=None):
    """One frame: laid out from `rel`, now named `to`, showing `text`."""
    return {"path": to or rel, "from": rel, "laid": laid(book, rel) if laid_text is None else laid_text,
            "text": text}


def apply(book, **req):
    a = ask(dict(req, op="proofbook-apply", folder=book))
    assert a["ok"], a
    return a


book = tempfile.mkdtemp()
HEAD = "---\nstatus: wip\nowner: NE\nnote: |\n  check b\n---\n"

# An edited line is written as typed; the header and the untouched lines stay exactly as they were.
write(book, "01/a.txt", HEAD + "abc /uni00E9 x\nHOH/a.ss01 HOH\nnnn\n\n")
a = apply(book, files=[edit(book, "01/a.txt", "abc éx\nHOH HOH\nnon")])
assert a["files"] == [{"ok": True}], a
assert read(book, "01/a.txt") == HEAD + "abc /uni00E9 x\nHOH/a.ss01 HOH\nnon\n\n", repr(read(book, "01/a.txt"))

# Added and deleted lines.
apply(book, files=[edit(book, "01/a.txt", "first\nabc éx\nnon\nlast")])
assert read(book, "01/a.txt") == HEAD + "first\nabc /uni00E9 x\nnon\nlast\n\n"

# Editing a line that holds a name Figma can't type would lose it: the page is left alone.
write(book, "01/b.txt", "HOH/a.ss01 HOH\nnnn\n")
a = apply(book, files=[edit(book, "01/b.txt", "HOH HOX\nnnn")])
assert not a["files"][0]["ok"] and "/a.ss01" in a["files"][0]["reason"], a
assert read(book, "01/b.txt") == "HOH/a.ss01 HOH\nnnn\n"

# A page changed on disk since the layout is left alone, even when it was only renamed.
a = apply(book, files=[edit(book, "01/b.txt", "x", to="01/c.txt", laid_text="what it used to say")])
assert "changed on disk" in a["files"][0]["reason"], a
assert os.path.exists(os.path.join(book, "01/b.txt")) and not os.path.exists(os.path.join(book, "01/c.txt"))

# Windows line endings and Figma's line separator.
write(book, "c.txt", "one\r\ntwo\r\n")
apply(book, files=[edit(book, "c.txt", "one three")])
assert read(book, "c.txt") == "one\r\nthree\r\n", repr(read(book, "c.txt"))

# A new section with a new frame: a new folder with a new page.
a = apply(book, files=[{"path": "02-New/words.txt", "from": None, "laid": None, "text": "Hamburg\nfonts  \n"}],
          folders=["01", "02-New", "03-Empty"])
assert a["files"] == [{"ok": True}], a
assert read(book, "02-New/words.txt") == "Hamburg\nfonts\n"
assert os.path.isdir(os.path.join(book, "03-Empty"))

# Renamed, and moved to another folder, keeping header and glyph names.
apply(book, files=[edit(book, "01/a.txt", laid(book, "01/a.txt"), to="02-New/a-renamed.txt")])
assert not os.path.exists(os.path.join(book, "01/a.txt"))
assert read(book, "02-New/a-renamed.txt") == HEAD + "first\nabc /uni00E9 x\nnon\nlast\n\n"

# Two pages swapping names.
write(book, "s/x.txt", "X\n")
write(book, "s/y.txt", "Y\n")
a = apply(book, files=[edit(book, "s/x.txt", "X", to="s/y.txt"), edit(book, "s/y.txt", "Y", to="s/x.txt")])
assert a["files"] == [{"ok": True}, {"ok": True}], a
assert read(book, "s/x.txt") == "Y\n" and read(book, "s/y.txt") == "X\n"

# A name used twice, or taken by a page that stays: left alone.
a = apply(book, files=[{"path": "s/z.txt", "from": None, "laid": None, "text": "1"},
                       {"path": "s/z.txt", "from": None, "laid": None, "text": "2"},
                       {"path": "s/x.txt", "from": None, "laid": None, "text": "3"}])
assert [f["ok"] for f in a["files"]] == [False, False, False], a
assert not os.path.exists(os.path.join(book, "s/z.txt")) and read(book, "s/x.txt") == "Y\n"

# Deleted frames and a deleted section go to the Trash; a folder with other files is kept.
write(book, "old/gone.txt", "bye\n")
write(book, "old/.DS_Store", "")
write(book, "keep/gone.txt", "bye\n")
write(book, "keep/notes.md", "mine\n")
a = apply(book, trash=["old/gone.txt", "keep/gone.txt"], goneFolders=["old", "keep"])
assert not os.path.exists(os.path.join(book, "old")), a
assert sorted(a["trashed"]) == ["keep/gone.txt", "old", "old/gone.txt"], a
assert os.path.exists(os.path.join(book, "keep/notes.md")) and a["skipped"][0]["path"] == "keep"
assert sorted(os.listdir(TRASH)) == ["gone 2.txt", "gone.txt", "old"], os.listdir(TRASH)

# Nothing outside the folder, and nothing that isn't a page.
outside = tempfile.mkdtemp()
write(outside, "x.txt", "keep")
bad = ["../" + os.path.basename(outside) + "/x.txt", "figma-styles.json", ".hidden/x.txt", "a/ b.txt"]
a = apply(book, files=[{"path": p, "from": None, "laid": None, "text": "x"} for p in bad],
          trash=["../" + os.path.basename(outside) + "/x.txt"])
assert not any(f["ok"] for f in a["files"]), a
assert read(outside, "x.txt") == "keep"
assert os.path.exists(os.path.join(book, "figma-styles.json")) is False

# An unchanged page is fine and is not rewritten.
before = os.stat(os.path.join(book, "c.txt")).st_mtime_ns
a = apply(book, files=[edit(book, "c.txt", "one\nthree")])
assert a["files"] == [{"ok": True}] and os.stat(os.path.join(book, "c.txt")).st_mtime_ns == before, a

assert not ask({"op": "proofbook-apply", "folder": book + "-missing"})["ok"]
print("proof-book saving: all checks passed")
