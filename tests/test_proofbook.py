"""Check of the proof-book reading in Resources/fontwork.py (op "proofbook").

Run: python3 tests/test_proofbook.py
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "Resources", "fontwork.py")


def write(folder, rel, text):
    path = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def ask(req):
    out = subprocess.run([sys.executable, WORKER], input=json.dumps(req) + "\n",
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


book = tempfile.mkdtemp()
write(book, "02-Numbers/figures.txt", "0123456789\n")
write(book, "01-Latin-LC/b-pairs.txt", "---\nstatus: wip\nowner: NE\nnote: |\n  check b\n---\nnbnbn\n---\nhbhbh\n")
write(book, "01-Latin-LC/a-z.txt", "abc /infinity /uni00E9/a.ss01 x\r\nnext\r\n")
write(book, "01-Latin-LC/A-open.txt", "---\nstatus: wip\nnever closed\n")
write(book, "01-Latin-LC/notes.md", "not a page")
write(book, ".hidden/x.txt", "hidden")
write(book, "top.txt", "Hamburgefonstiv")
write(book, "figma-styles.json", json.dumps({"choice": "masters"}))

a = ask({"id": 1, "op": "proofbook", "folder": book})
assert a["ok"], a
paths = [p["path"] for p in a["pages"]]
assert paths == ["01-Latin-LC/A-open.txt", "01-Latin-LC/a-z.txt", "01-Latin-LC/b-pairs.txt",
                 "02-Numbers/figures.txt", "top.txt"], paths
pages = {p["path"]: p for p in a["pages"]}
assert pages["01-Latin-LC/b-pairs.txt"]["text"] == "nbnbn\n---\nhbhbh\n", "header left out, later --- kept"
assert pages["01-Latin-LC/A-open.txt"]["text"].startswith("---\nstatus"), "a header that never closes is text"
az = pages["01-Latin-LC/a-z.txt"]
assert az["text"] == "abc ∞é x\nnext\n", repr(az["text"])
assert az["untypable"] == ["a.ss01"], az["untypable"]
assert az["section"] == "01-Latin-LC" and az["name"] == "a-z"
assert pages["top.txt"]["section"] == ""
assert a["styles"] == {"choice": "masters"}
assert a["name"] == os.path.basename(book)
assert not ask({"id": 2, "op": "proofbook", "folder": book + "-missing"})["ok"]
print("proof-book reading: all checks passed")
