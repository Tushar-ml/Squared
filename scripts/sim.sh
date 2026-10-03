#!/bin/sh
# Headless simulator helpers: sim.sh install | launch [args...] | open <url> | shot <name>
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEV="${SIM_DEVICE:-iPhone 17 Pro}"; APP=tech.simplismart.roommatecoins
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
  install) xcrun simctl install "$DEV" "$ROOT/ios/build/Build/Products/Debug-iphonesimulator/RoommateCoins.app" ;;
  launch) shift; xcrun simctl terminate "$DEV" $APP 2>/dev/null; xcrun simctl launch "$DEV" $APP "$@" ;;
  open) xcrun simctl openurl "$DEV" "$2" ;;
  shot) mkdir -p "${SHOTS:-/tmp/rc-shots}"; xcrun simctl io "$DEV" screenshot "${SHOTS:-/tmp/rc-shots}/$2.png" >/dev/null 2>&1 && echo "${SHOTS:-/tmp/rc-shots}/$2.png" ;;
esac
