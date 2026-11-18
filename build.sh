#!/usr/bin/env bash
# build.sh - Nils-Player v1.7
# Builds dist/Nils-Player.exe (single file) from:
#   (needs Wine to stamp the icon into mpv.exe; set WINE=/path/to/wine64 if needed)
#   $DL/mpvx/            unpacked mpv Windows build (zhongfly/mpv-winbuild, x86_64)
#   $DL/mi/pymediainfo/  MediaInfo.dll + License.html
#   ./config/            portable_config (mpv.conf, input.conf, scripts/)
set -euo pipefail
cd "$(dirname "$0")"
DL=${DL:?set DL to the download folder}
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

export GOOS=windows GOARCH=amd64 CGO_ENABLED=0

echo "== helper"
(cd helper && [ -f go.mod ] || go mod init mi-helper >/dev/null 2>&1; go build -trimpath -ldflags "-s -w" -o "$STAGE/mi-helper.exe" .)

echo "== payload"
cp "$DL/mpvx/mpv.exe" "$STAGE/"
echo "== icon into mpv.exe (window + taskbar icon)"
(cd seticon && [ -f go.mod ] || go mod init seticon >/dev/null 2>&1; go build -trimpath -o "$STAGE/seticon.exe" .)
WINEDEBUG=-all ${WINE:-wine} "$STAGE/seticon.exe" "$STAGE/mpv.exe" icon/nils-player.ico 2>/dev/null | tail -1
rm -f "$STAGE/seticon.exe"
mkdir -p "$STAGE/mpv" "$STAGE/licenses"
cp "$DL/mpvx/mpv/fonts.conf" "$STAGE/mpv/"
cp -r "$DL/mpvx/doc/." "$STAGE/licenses/mpv-doc/" 2>/dev/null || true
cp "$DL/mi/pymediainfo/MediaInfo.dll" "$STAGE/"
cp "$DL/mi/pymediainfo/License.html" "$STAGE/licenses/MediaInfo-License.html"
cp -r config "$STAGE/portable_config"
rm -f launcher/payload.zip
(cd "$STAGE" && zip -q -r -9 "$OLDPWD/launcher/payload.zip" .)

BUILD_ID="v1.7-$(sha256sum launcher/payload.zip | cut -c1-12)"
echo "== resources"
cp icon/nils-player.ico launcher/app.ico
(cd launcher && x86_64-w64-mingw32-windres --preprocessor=cpp --preprocessor-arg=-P -O coff -i app.rc -o rsrc_windows_amd64.syso)
echo "== launcher ($BUILD_ID)"
mkdir -p dist
(cd launcher && [ -f go.mod ] || go mod init nils-player >/dev/null 2>&1
 go build -trimpath -ldflags "-s -w -H windowsgui -X main.buildID=$BUILD_ID" -o ../dist/Nils-Player.exe .)
ls -la dist/Nils-Player.exe
