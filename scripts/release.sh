#!/bin/zsh
# Builds dist/Squared-<version>.dmg (Mac, Apple silicon + Intel) and dist/Squared-<version>.ipa (iPhone, unsigned).
# Neither needs an Apple developer account. See README "Install".
set -euo pipefail
cd "$(dirname "$0")/../ios"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | sed 's/[^0-9.]//g')
DIST=../dist; rm -rf $DIST; mkdir -p $DIST
xcodegen generate -q

# Mac (Catalyst), ad-hoc signed
xcodebuild build -project Squared.xcodeproj -scheme Squared -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -quiet
APP=build/Build/Products/Release-maccatalyst/Squared.app
codesign --force --deep -s - $APP
STAGE=$(mktemp -d); cp -R $APP $STAGE/; ln -s /Applications $STAGE/Applications
hdiutil create -volname Squared -srcfolder $STAGE -ov -format UDZO $DIST/Squared-$VERSION.dmg -quiet
rm -rf $STAGE

# iPhone, unsigned: sign it while installing (Sideloadly / AltStore) or build from Xcode instead
xcodebuild build -project Squared.xcodeproj -scheme Squared -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet
PAY=$(mktemp -d); mkdir $PAY/Payload; cp -R build/Build/Products/Release-iphoneos/Squared.app $PAY/Payload/
(cd $PAY && zip -qry - Payload) > $DIST/Squared-$VERSION.ipa
rm -rf $PAY

ls -lh $DIST
