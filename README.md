# Figma Friend

A small menu bar app that lets Figma plugins use the fonts installed on your Mac. Figma gives plugins only font names, never the files, and a plugin can't read your disk. Figma Friend fills that gap.

It is made for [figma-export-pdf](https://github.com/HelsinkiTypeStudio/figma-export-pdf), which writes real, selectable text into PDFs in your own fonts. Later it can also serve Test Font Reloader.

- **Always the current build.** Every request reads the font file fresh from disk. Nothing is copied or kept, so a build you exported a minute ago is the one that gets used.
- **Checked, never swapped.** Each glyph Figma drew is matched to the font file by its width and outline box. A glyph that doesn't match exactly is reported, and the plugin keeps that text as Figma's outlines.
- **Variable fonts.** The font is fixed at the axis values Figma used, including CFF2 test builds from Glyphs, and turned into a plain TrueType or CFF font that every PDF reader can show.
- **Small PDFs.** Only the glyphs used are sent back, so an embedded font is a few KB.

## Install

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/HelsinkiTypeStudio/font-helper.git
cd font-helper
scripts/build-app.sh --install
```

This builds **Figma Friend.app**, copies it to /Applications and starts it. The first build downloads fontTools into a private folder inside `build/`; your own Python is not touched. Look for **FF** in the menu bar. Choose **Open at Login** there to keep it running.

## Using it

The first time a plugin connects, Figma Friend asks whether to allow it. After that the plugin remembers its key.

The menu has:

- **Copy Pairing Key**, for a plugin that asks you to paste it.
- **Unpair All Plugins**, which makes a new key, so every plugin has to ask again.
- **Show Log**, which opens `~/Library/Logs/Figma Friend.log`.

## Security

Figma Friend only listens on 127.0.0.1, so nothing on your network can reach it. Web pages in your browser can reach localhost, so every request except `/ping` and `/pair` needs the pairing key, and a key is only handed out after you click Allow. Only allow a request you just started from Figma.

## For plugin developers

Every answer allows any origin, because Figma plugin windows have a null origin. Add `http://localhost:7337` to `networkAccess.allowedDomains` in the plugin's manifest, with a `reasoning`. Send the key in the `X-Helper-Key` header.

| Request | Answer |
| --- | --- |
| `GET /ping` | `{"ok": true, "app": "Figma Friend", "version", "paired"}` |
| `POST /pair` with `{"plugin": "Name"}` | Shows the Allow dialog. `{"key"}`, or 403 if declined |
| `GET /fonts/files?family=&style=` | The installed files for a family, exact style first |
| `POST /fonts/prepare` | The font check and subset font, below |
| `POST /save?name=Name.pdf` with the file as the body | Shows a save dialog in the last folder used. While it is open, a PDF is made smaller with [PDF Compressor](https://github.com/niklas-ekholm/pdf-compressor)'s method (images at 220 ppi at the size shown, shorter path numbers, best lossless compression; text and fonts untouched). Turn it off with **Make Saved PDFs Smaller** in the menu. `{"saved": path, "bytes", "sentBytes"}` or `{"cancelled": true}` |

`/fonts/prepare` takes the glyphs from the hidden text layer of Figma's own PDF export, in em:

```json
{"family": "Bookish Variable", "style": "Medium", "axes": {"wght": 585, "opsz": 24},
 "glyphs": [{"w": 0.4819, "llx": 0.0278, "lly": -0.0117, "urx": 0.4512, "chars": "a"}]}
```

`w` is the advance width and `llx`, `lly`, `urx` the left, bottom and right edges of the glyph's box, as Figma records them. The top edge is left out, because Figma's value isn't the glyph's top. The answer has a font program (`format` `TrueType` or `CFF`, base64 in `font`) and, for each glyph in the same order, a `gid` or `null` with the reason. See [Resources/fontwork.py](Resources/fontwork.py) for the details.

## Roadmap

- **Proofs.** A Figma plugin that stamps each proof with the font file it was set in: build version and date. Every proof then shows which build it is.
- **Glyph lists.** A plugin that asks Figma Friend for a font's full character set and lays it out in Figma for proofing.

## Development

```sh
swift run                         # runs from Terminal, using /usr/bin/python3 with fontTools
python3 tests/test_fontwork.py    # checks the font work with two small made-up fonts
```

`tests/check_worker.py` runs the font work against real exports made by the figma-export-pdf test plugin.

## Licence

MIT
