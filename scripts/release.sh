#!/bin/bash
#
# release.sh — Config do Alpiste; o fluxo de release (build fora do repo, assinatura
# Developer ID, DMG, notarização e staple) mora no script compartilhado do workspace:
# sparrow_workspace/scripts/release-macos.sh.
#
# Uso:
#   ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# O python3 do PATH pode ser um venv de outro projeto sem Pillow; sondar os
# binários conhecidos em vez de confiar no PATH.
FOUND=""
for CANDIDATE in "${PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  [ -n "$CANDIDATE" ] || continue
  if "$CANDIDATE" -c "import PIL" 2>/dev/null; then FOUND="$CANDIDATE"; break; fi
done
[ -n "$FOUND" ] || { echo "Nenhum python3 com Pillow encontrado: python3 -m pip install pillow" >&2; exit 1; }

export APP_NAME="Alpiste"
export DMG_VERSIONED=1
export PRE_BUILD_CMD="$FOUND scripts/make-icon.py"
export CLEAN_LAUNCH_SERVICES=1
# Sem exec: precisamos rodar a poda abaixo depois do fluxo compartilhado terminar.
../../scripts/release-macos.sh

# Poda os DMGs antigos de build/, mantendo só o recém-gerado. DMG parado engana
# sobre o que está instalado, e a pasta acumulava toda versão desde a 0.2.0. Só roda
# num release bem-sucedido: o set -e aborta acima se o build compartilhado falhar.
# O mais recente por mtime é o que acabou de sair; find pega também o legado
# Alpiste.dmg sem sufixo de versão.
KEEP="$(ls -t build/Alpiste-*.dmg 2>/dev/null | head -1)"
if [ -n "$KEEP" ]; then
  find build -maxdepth 1 -type f -name 'Alpiste*.dmg' ! -path "$KEEP" -print -delete
fi
