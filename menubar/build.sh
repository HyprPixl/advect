#!/bin/bash
# Build Advect.app — a menu bar front end for the advect renderer.
#
#   ./build.sh            build into menubar/build/Advect.app
#   ./build.sh --install  build, then move it into ~/Applications and launch it
#
# No Xcode project and no package manager: swiftc compiles the sources straight
# into a hand-laid bundle, and the renderer is copied in beside it so the .app
# keeps working wherever the repo ends up.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
build="$here/build"
app="$build/Advect.app"
contents="$app/Contents"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

echo "compiling…"
swiftc -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit -framework ServiceManagement -framework ImageIO \
    -o "$contents/MacOS/Advect" \
    "$here"/Sources/*.swift

cp "$here/Resources/Info.plist" "$contents/Info.plist"

# The renderer travels inside the bundle. advect locates advect_accel.c
# relative to its own path, so the C source has to sit right next to it.
cp "$repo/advect" "$contents/Resources/advect"
cp "$repo/advect_accel.c" "$contents/Resources/advect_accel.c"
chmod +x "$contents/Resources/advect"

# The app wears its own output as its icon: a fixed seed and palette, so it looks
# the same on every machine and doesn't change from build to build. Cached, since
# painting it costs a couple of seconds.
icon_source="$here/build/icon-source.png"
if [ ! -f "$icon_source" ]; then
    echo "painting the app icon…"
    # dune reads best at 16×16 — pale filaments have the most contrast left once
    # the whole thing is a few pixels across.
    python3 "$repo/advect" --seed 90210 --size 1024x1024 --palette dune \
        --glow 1.5 --sharp 0.45 --backend c --out "$icon_source" >/dev/null
fi

echo "making icon…"
iconset="$build/AppIcon.iconset"
rm -rf "$iconset"; mkdir -p "$iconset"
for size in 16 32 64 128 256 512; do
    sips -z $size $size "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$icon_source" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
rm -rf "$iconset"

# Ad-hoc signature: enough for a locally built app, and SMAppService needs the
# bundle to carry one at all before it will register a login item.
codesign --force --deep --sign - "$app" >/dev/null 2>&1 || echo "warning: codesign failed"

echo "built $app"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/Advect.app"
    osascript -e 'quit app "Advect"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$dest"
    mkdir -p "$HOME/Applications"
    cp -R "$app" "$dest"
    echo "installed $dest"
    open "$dest"
fi
