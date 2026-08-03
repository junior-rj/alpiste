#!/bin/bash
#
# release.sh — Build, sign (Developer ID), notarize and package Alpiste as a DMG.
# Same flow as menubar-hide/scripts/release.sh; uses the team-wide notary profile.
#
# Uso:
#   ./scripts/release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-yourlaunch-notary}"
APP_NAME="Alpiste"
BUILD="build"

rm -rf "$BUILD"
mkdir -p "$BUILD"

python3 scripts/make-icon.py
xcodegen

echo "==> Arquivando (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -archivePath "$BUILD/$APP_NAME.xcarchive" archive

echo "==> Exportando com Developer ID"
xcodebuild -exportArchive \
  -archivePath "$BUILD/$APP_NAME.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$BUILD/export"

echo "==> Gerando DMG"
DMG="$BUILD/$APP_NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD/export/$APP_NAME.app" -ov -format UDZO "$DMG"

echo "==> Notarizando o DMG (aguarda concluir)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Grampeando o ticket no DMG"
xcrun stapler staple "$DMG"

# Cada .app deixado no disco vira um registro separado no LaunchServices, e aí
# Spotlight, Launchpad e o painel de Privacidade passam a listar um "Alpiste" por
# caminho de build. Só o DMG sobrevive ao release.
echo "==> Limpando artefatos intermediários"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILD/export/$APP_NAME.app" 2>/dev/null || true
rm -rf "$BUILD/export" "$BUILD/$APP_NAME.xcarchive"

echo "==> Pronto: $DMG"
