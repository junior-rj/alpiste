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
STAGE="$BUILD/staging"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || { echo "MARKETING_VERSION não encontrado em project.yml"; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree com mudanças não commitadas. Commit antes do release."
  git status --short
  exit 1
fi

command -v xcodegen >/dev/null \
  || { echo "xcodegen não encontrado: brew install xcodegen"; exit 1; }
python3 -c "import PIL" 2>/dev/null \
  || { echo "Pillow não encontrado: python3 -m pip install pillow"; exit 1; }

# Só a staging é destruída antes de começar. Um DMG de um release anterior
# sobrevive se este release falhar no meio do caminho.
rm -rf "$STAGE"
mkdir -p "$STAGE"

python3 scripts/make-icon.py
xcodegen

echo "==> Arquivando (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -archivePath "$STAGE/$APP_NAME.xcarchive" archive

echo "==> Exportando com Developer ID"
xcodebuild -exportArchive \
  -archivePath "$STAGE/$APP_NAME.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$STAGE/export"

echo "==> Gerando DMG"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE/export/$APP_NAME.app" -ov -format UDZO "$DMG"

echo "==> Notarizando o DMG (aguarda concluir)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Grampeando o ticket no DMG"
xcrun stapler staple "$DMG"

echo "==> Verificação final"
xcrun stapler validate "$DMG"
spctl -a -t exec -vv "$STAGE/export/$APP_NAME.app"

# Cada .app deixado no disco vira um registro separado no LaunchServices, e aí
# Spotlight, Launchpad e o painel de Privacidade passam a listar um "Alpiste" por
# caminho de build. Só o DMG sobrevive ao release.
echo "==> Limpando artefatos intermediários"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$STAGE/export/$APP_NAME.app" 2>/dev/null || true
rm -rf "$STAGE"

echo "==> Pronto: $DMG"
