#!/bin/bash
# Builds "Font Helper.app" in ./build and, with --install, copies it to /Applications.
#
# Needs: Xcode Command Line Tools (for swift and python3). Internet the first time,
# to fetch fontTools and PyInstaller into a private build folder. Nothing is installed
# into your own Python.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Font Helper.app"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/FontHelper/Settings.swift)

# Prefer a newer Python if one is installed; the Command Line Tools one (3.9) also works.
PYTHON=${PYTHON:-}
if [ -z "$PYTHON" ]; then
  for p in python3.13 python3.12 python3.11 python3.10 /usr/bin/python3; do
    if command -v "$p" >/dev/null 2>&1; then PYTHON=$(command -v "$p"); break; fi
  done
fi
echo "==> Python: $PYTHON ($("$PYTHON" --version 2>&1))"

echo "==> Building the app"
swift build -c release
BIN=$(swift build -c release --show-bin-path)/FontHelper

echo "==> Building the font worker (fontTools)"
if [ ! -x build/venv/bin/python ]; then
  "$PYTHON" -m venv build/venv
fi
build/venv/bin/python -m pip install --quiet --upgrade pip
build/venv/bin/python -m pip install --quiet -r Resources/requirements.txt "pyinstaller>=6,<7"
build/venv/bin/pyinstaller --noconfirm --clean --log-level WARN --onedir \
  --distpath build/worker --workpath build/pyinstaller --specpath build/pyinstaller \
  --name fontwork --collect-submodules fontTools Resources/fontwork.py

echo "==> Checking the font worker"
echo '{"id":0,"op":"ping"}' | build/worker/fontwork/fontwork

echo "==> Making $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FontHelper"
cp -R build/worker/fontwork "$APP/Contents/Resources/fontwork"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  osascript -e 'quit app "Font Helper"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/Font Helper.app"
  cp -R "$APP" "/Applications/Font Helper.app"
  open "/Applications/Font Helper.app"
  echo "Font Helper $VERSION is running. Look for the text icon in the menu bar."
else
  echo "Built $APP ($VERSION). Run scripts/build-app.sh --install to put it in /Applications and start it."
fi
