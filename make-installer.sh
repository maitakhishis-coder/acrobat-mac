#!/bin/bash
# Crea un instalador .pkg a partir de dist/FocalGeometry.acroplugin
# Ejecutar en macOS DESPUÉS de build-macos.sh.
#
# Uso básico (sin firmar, solo para pruebas):
#   bash make-installer.sh
#
# Uso con firma y notarización (para distribuir):
#   APP_SIGN_ID="Developer ID Application: Tu Nombre (TEAMID)" \
#   PKG_SIGN_ID="Developer ID Installer: Tu Nombre (TEAMID)" \
#   NOTARY_PROFILE="mi-perfil-notary" \
#   bash make-installer.sh
#
# El perfil de notarización se crea una vez con:
#   xcrun notarytool store-credentials mi-perfil-notary \
#       --apple-id TU_APPLE_ID --team-id TEAMID --password CONTRASEÑA_ESPECÍFICA_DE_APP
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo "Este script solo funciona en macOS." >&2
    exit 2
fi

VERSION="${VERSION:-1.0.0}"
IDENTIFIER="${IDENTIFIER:-com.focal.acrobat.geometry}"
# Carpeta de plug-ins de Acrobat DC / Acrobat Pro (revisar en la instalación real del usuario).
INSTALL_DIR="${INSTALL_DIR:-/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Plug-ins}"

here=$(cd "$(dirname "$0")" && pwd)
plugin="$here/dist/FocalGeometry.acroplugin"
[[ -d "$plugin" ]] || { echo "No existe $plugin. Ejecuta antes build-macos.sh." >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root"
ditto "$plugin" "$root/FocalGeometry.acroplugin"

# 1) Firmar el bundle (opcional pero necesario para notarizar)
if [[ -n "${APP_SIGN_ID:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$APP_SIGN_ID" "$root/FocalGeometry.acroplugin"
    codesign --verify --deep --strict "$root/FocalGeometry.acroplugin"
fi

# 2) Construir el paquete
mkdir -p "$here/dist"
out="$here/dist/FocalGeometry-$VERSION.pkg"
sign_args=()
[[ -n "${PKG_SIGN_ID:-}" ]] && sign_args=(--sign "$PKG_SIGN_ID")

pkgbuild --root "$root" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "$INSTALL_DIR" \
    ${sign_args[@]+"${sign_args[@]}"} \
    "$out"

# 3) Notarizar y grapar (opcional)
if [[ -n "${NOTARY_PROFILE:-}" && -n "${PKG_SIGN_ID:-}" ]]; then
    xcrun notarytool submit "$out" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$out"
fi

echo "Instalador creado: $out"
