#!/bin/bash
set -euo pipefail
if [[ $# != 1 || $(uname -s) != Darwin ]]; then
    echo "Uso en macOS: $0 /ruta/al/Acrobat_DC_SDK_Mac_2023_V5.dmg" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
mkdir "$work/mount" "$work/sdk"
mounted=0
cleanup() {
    if [[ $mounted == 1 ]]; then hdiutil detach "$work/mount" >/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$1"
mounted=1
ditto "$work/mount" "$work/sdk"
# La copia hereda los permisos de solo lectura del DMG: hay que poder modificarla.
chflags -R nouchg "$work/sdk" 2>/dev/null || true
chmod -R u+w "$work/sdk"
python3 "$here/prepare-starter.py" "$work/sdk" "$here" "$work/project-path"
project=$(cat "$work/project-path")
xcodebuild -project "$project" -target Starter -configuration Release \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CLANG_CXX_LANGUAGE_STANDARD=c++17 CLANG_ENABLE_OBJC_ARC=YES \
    'OTHER_LDFLAGS=$(inherited) -framework AppKit' \
    PRODUCT_NAME=FocalGeometry CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$work/build" build
bundle="$work/build/FocalGeometry.acroplugin"
test -d "$bundle"
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$bundle/Contents/Info.plist")
lipo -verify_arch arm64 x86_64 "$bundle/Contents/MacOS/$executable"
mkdir -p "$PWD/dist"
ditto "$bundle" "$PWD/dist/FocalGeometry.acroplugin"
echo "Compilado para Intel y Apple Silicon: $PWD/dist/FocalGeometry.acroplugin"
