"""Check of writing Figma edits back to proof-pages in Resources/fontwork.py (op "proofbook-save").

Run: python3 tests/test_proofbook_save.py
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "Resources", "fontwork.py")


def write(folder, rel, text):
    path = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def read(folder, rel):
    with open(os.path.join(folder, rel), encoding="utf-8", newline="") as fh:
        return fh.read()


def ask(req):
    out = subprocess.run([sys.executable, WORKER], input=json.dumps(req) + "\n",
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def laid(book, rel):
    """The text figma-proofbook laid the page out with: as read, trailing space trimmed."""
    pages = {p["path"]: p for p in ask({"op": "proofbook", "folder": book})["pages"]}
    return pages[rel]["text"].rstrip()


def save(book, rel, edited, laid_text=None):
    a = ask({"op": "proofbook-save", "folder": book,
             "pages": [{"path": rel, "laid": laid(book, rel) if laid_text is None else laid_text,
                        "edited": edited}]})
    assert a["ok"], a
    return a["pages"][0]


book = tempfile.mkdtemp()
HEAD = "---\nstatus: wip\nowner: NE\nnote: |\n  check b\n---\n"

# An edited line is written as typed; the header and the untouched lines stay exactly as they were.
write(book, "01/a.txt", HEAD + "abc /uni00E9 x\nHOH/a.ss01 HOH\nnnn\n\n")
r = save(book, "01/a.txt", "abc éx\nHOH HOH\nnon")
assert r["saved"], r
assert read(book, "01/a.txt") == HEAD + "abc /uni00E9 x\nHOH/a.ss01 HOH\nnon\n\n", repr(read(book, "01/a.txt"))
assert r["text"] == "abc éx\nHOH HOH\nnon\n\n", repr(r["text"])
assert r["untypable"] == ["a.ss01"]

# Added and deleted lines.
r = save(book, "01/a.txt", "first\nabc éx\nnon\nlast")
assert r["saved"], r
assert read(book, "01/a.txt") == HEAD + "first\nabc /uni00E9 x\nnon\nlast\n\n", repr(read(book, "01/a.txt"))

# Editing a line that holds a name Figma can't type would lose it: the page is left alone.
write(book, "01/b.txt", "HOH/a.ss01 HOH\nnnn\n")
r = save(book, "01/b.txt", "HOH HOX\nnnn")
assert not r["saved"] and "/a.ss01" in r["reason"], r
assert read(book, "01/b.txt") == "HOH/a.ss01 HOH\nnnn\n"

# A page changed on disk since the layout is left alone.
r = save(book, "01/b.txt", "something", laid_text="what it used to say")
assert not r["saved"] and "changed on disk" in r["reason"], r
assert read(book, "01/b.txt") == "HOH/a.ss01 HOH\nnnn\n"

# Windows line endings and Figma's line separator.
write(book, "c.txt", "one\r\ntwo\r\n")
r = save(book, "c.txt", "one three")
assert r["saved"], r
assert read(book, "c.txt") == "one\r\nthree\r\n", repr(read(book, "c.txt"))

# Nothing outside the folder, and nothing that isn't a page.
outside = tempfile.mkdtemp()
write(outside, "x.txt", "keep")
for rel in ("../" + os.path.basename(outside) + "/x.txt", "figma-styles.json", "missing.txt"):
    r = save(book, rel, "x", laid_text="keep")
    assert not r["saved"], (rel, r)
assert read(outside, "x.txt") == "keep"

# An unchanged page is fine and is not rewritten.
before = os.stat(os.path.join(book, "c.txt")).st_mtime_ns
r = save(book, "c.txt", "one\nthree")
assert r["saved"] and os.stat(os.path.join(book, "c.txt")).st_mtime_ns == before, r

assert not ask({"op": "proofbook-save", "folder": book + "-missing", "pages": []})["ok"]
print("proof-book saving: all checks passed")
