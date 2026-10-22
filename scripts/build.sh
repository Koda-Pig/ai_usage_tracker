#!/bin/zsh
# Usage: scripts/build.sh [build|run|install|test]
#   build    release build, assemble and sign build/AI Usage Tracker.app
#   run      build, quit any running copy, launch from build/
#   install  build, copy to ~/Applications, launch from there (Open at Login binds to that path)
#   test     swift test
#
# Signing: SIGN_IDENTITY if set, else the first "Apple Development" certificate in your keychain,
# else ad hoc. A stable identity matters: the Keychain ties the saved Claude sign-in to the
# app's signature, so an ad hoc build asks for Keychain access again after every rebuild.
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="AI Usage Tracker"
EXE="AIUsageTracker"
APP="build/$APP_NAME.app"

build() {
  swift build -c release --product "$EXE"
  local bin="$(swift build -c release --show-bin-path)/$EXE"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$bin" "$APP/Contents/MacOS/$EXE"
  cp Resources/Info.plist "$APP/Contents/Info.plist"

  local identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | head -1)}"
  codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$APP"
  echo "Signed with: ${identity:-ad hoc}"
  echo "Built $APP"
}

quit_running() {
  pkill -x "$EXE" 2>/dev/null || true
  while pgrep -x "$EXE" >/dev/null; do sleep 0.1; done   # open fails with -600 while the old copy is exiting
}

relaunch() {
  quit_running
  open "$1"
}

case "${1:-build}" in
  build) build ;;
  run) build; relaunch "$APP" ;;
  install)
    build
    mkdir -p ~/Applications
    quit_running
    rm -rf ~/Applications/"$APP_NAME.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"$APP_NAME.app"
    echo "Installed to ~/Applications/$APP_NAME.app"
    ;;
  test) swift test ;;
  *) echo "usage: $0 [build|run|install|test]"; exit 1 ;;
esac
