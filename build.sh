#!/bin/zsh
# Usage:
#   ./build.sh            build build/CmdTab.app
#   ./build.sh install    build, copy to /Applications, and launch
#
# Set CODESIGN_IDENTITY to a real signing identity to keep the Accessibility grant across rebuilds.
# With the default ad-hoc signature, macOS treats every rebuild as a new app.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/CmdTab.app
BUNDLE_ID=com.sandipchitale.cmdtab

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A universal binary: compiled for Apple silicon and Intel, then merged.
ARCH_DIR=build/arch
rm -rf "$ARCH_DIR"
mkdir -p "$ARCH_DIR"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
        Sources/*.swift \
        -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework ScreenCaptureKit \
        -o "$ARCH_DIR/CmdTab-$arch"
done
lipo -create "$ARCH_DIR"/CmdTab-arm64 "$ARCH_DIR"/CmdTab-x86_64 -output "$APP/Contents/MacOS/CmdTab"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    # Permission grants are tied to the code signature. If it changed (always, with ad-hoc signing), the old
    # Accessibility and Screen Recording grants are stale. Clear them so macOS asks again.
    requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p' }
    old_req=$(requirement /Applications/CmdTab.app || true)
    new_req=$(requirement "$APP")
    pkill -x CmdTab 2>/dev/null && sleep 0.5 || true
    rm -rf /Applications/CmdTab.app
    cp -R "$APP" /Applications/
    if [[ -z "${CODESIGN_IDENTITY:-}" || "$old_req" != "$new_req" ]]; then
        tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
        tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
        echo "Signature changed: grant Accessibility (and Screen Recording for thumbnails) again."
    fi
    open /Applications/CmdTab.app
    echo "Installed and launched /Applications/CmdTab.app"
fi
