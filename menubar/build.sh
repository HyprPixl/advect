#!/bin/bash
# Build Advect.app — a menu bar front end for the advect renderer.
#
#   ./build.sh              build into menubar/build/Advect.app (ad-hoc signed)
#   ./build.sh --install    build, then move it into ~/Applications and launch it
#   ./build.sh --notarize   sign with a Developer ID, notarize, and staple
#   ./build.sh --dmg        additionally wrap it in a signed, notarized .dmg
#
# No Xcode project and no package manager: swiftc compiles the sources straight
# into a hand-laid bundle, with the renderer and the C march compiled in. The
# result is one self-contained binary that needs nothing installed to run.
#
# Ad-hoc signing is fine on the machine that built it. Anything you hand to
# someone else has to be signed with a Developer ID *and* notarized, or
# Gatekeeper refuses to open it. For that:
#
#   SIGN_ID   the Developer ID Application identity, e.g.
#             "Developer ID Application: Your Name (TEAMID)".
#             Defaults to the only Developer ID in the keychain, if there is one.
#   NOTARY_PROFILE  a notarytool keychain profile (default: advect-notary).
#
# Create the profile once, by either route — build.sh doesn't care which, since
# both end up as the same kind of keychain entry:
#
#   App Store Connect API key (sturdier; survives Apple ID password changes,
#   and it's the only one that works unattended in CI):
#     xcrun notarytool store-credentials advect-notary \
#       --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
#       --key-id XXXXXXXXXX --issuer <issuer-uuid>
#
#   Apple ID + app-specific password:
#     xcrun notarytool store-credentials advect-notary \
#       --apple-id you@example.com --team-id TEAMID \
#       --password <app-specific-password>
#
#   The app-specific password must be generated at appleid.apple.com while
#   signed in as that same Apple ID — one made under a different account gives
#   an HTTP 401. Check the profile with:
#     xcrun notarytool history --keychain-profile advect-notary
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
build="$here/build"
app="$build/Advect.app"
contents="$app/Contents"

install=0
notarize=0
dmg=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --notarize) notarize=1 ;;
        --dmg) notarize=1; dmg=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

# Universal, so the download runs on Intel Macs too and not just the machine
# that happened to build it. The renderer is compiled *into* the binary — no
# interpreter, no scripts in Resources, nothing to find at run time.
slices=""
for arch in arm64 x86_64; do
    echo "compiling ($arch)…"
    cc -O3 -target "$arch-apple-macos13.0" -c "$repo/advect_accel.c" \
        -o "$build/advect_accel-$arch.o"
    swiftc -O \
        -target "$arch-apple-macos13.0" \
        -framework AppKit -framework ServiceManagement -framework ImageIO \
        -import-objc-header "$here/Sources/Render/advect_accel.h" \
        -o "$build/Advect-$arch" \
        "$here"/Sources/*.swift "$here"/Sources/Render/*.swift \
        "$build/advect_accel-$arch.o"
    slices="$slices $build/Advect-$arch"
done
lipo -create $slices -output "$contents/MacOS/Advect"
rm -f $slices "$build"/advect_accel-*.o

cp "$here/Resources/Info.plist" "$contents/Info.plist"

# The app wears its own output as its icon: a fixed seed and palette, so it looks
# the same on every machine and doesn't change from build to build. Cached, since
# painting it costs a couple of seconds.
icon_source="$here/build/icon-source.png"
if [ ! -f "$icon_source" ]; then
    echo "painting the app icon…"
    # moss reads best at 16×16: violet filaments against a near-black ground keep
    # the most contrast once the whole thing is a few pixels across. The warmer
    # palettes lose their strokes into the background at that size.
    python3 "$repo/advect" --seed 90210 --size 1024x1024 --palette moss \
        --glow 1.5 --sharp 0.45 --out "$icon_source" >/dev/null
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

# Signing. The bundle holds exactly one Mach-O (Contents/MacOS/Advect) and no
# nested code, so there is nothing to sign inside-out and --deep isn't wanted.
# SMAppService needs the bundle to carry *some* signature before it will register
# a login item, so even the throwaway build gets an ad-hoc one.
if [ "$notarize" = 1 ]; then
    sign_id="${SIGN_ID:-$(security find-identity -v -p codesigning |
        awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
    if [ -z "$sign_id" ]; then
        echo "error: --notarize needs a Developer ID Application certificate." >&2
        echo "  None found in the keychain. Create one in Xcode:" >&2
        echo "  Settings → Accounts → your team → Manage Certificates → + →" >&2
        echo "  Developer ID Application. Then re-run, or set SIGN_ID." >&2
        exit 1
    fi
    # Braced deliberately: bash 3.2 (what macOS ships) isn't UTF-8 aware when it
    # parses an identifier, and reads the first byte of the following "…" as part
    # of the variable name.
    echo "signing as ${sign_id}…"
    # Hardened runtime and a secure timestamp are both prerequisites for
    # notarization. Nothing here needs an entitlement exception: the app spawns
    # no subprocesses and loads no code it didn't ship with.
    codesign --force --options runtime --timestamp --sign "$sign_id" "$app"
else
    codesign --force --sign - "$app" >/dev/null 2>&1 || echo "warning: codesign failed"
fi

codesign --verify --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /'
echo "built $app"

if [ "$notarize" = 1 ]; then
    profile="${NOTARY_PROFILE:-advect-notary}"
    zip="$build/Advect.zip"
    rm -f "$zip"
    # ditto, not zip(1): it preserves the symlinks and extended attributes that
    # the signature is computed over.
    ditto -c -k --keepParent "$app" "$zip"
    echo "submitting to notary service (this takes a few minutes)…"
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
    # Staple the ticket into the bundle so it validates without a network round
    # trip on the machine that opens it.
    xcrun stapler staple "$app"
    rm -f "$zip"
    echo "=== Gatekeeper assessment ==="
    spctl --assess --type execute --verbose=4 "$app"
fi

if [ "$dmg" = 1 ]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$contents/Info.plist")"
    image="$build/Advect-$version.dmg"
    stage="$build/dmg"
    rm -rf "$stage" "$image"
    mkdir -p "$stage"
    cp -R "$app" "$stage/"
    # The customary drag-to-install target.
    ln -s /Applications "$stage/Applications"

    echo "building $(basename "$image")…"
    hdiutil create -volname "Advect" -srcfolder "$stage" -ov -quiet \
        -format UDZO -imagekey zlib-level=9 "$image"
    rm -rf "$stage"

    # The disk image is what actually gets downloaded, so it needs its own
    # signature and its own notarization — the app's ticket inside doesn't
    # vouch for the container.
    codesign --force --timestamp --sign "$sign_id" "$image"
    echo "notarizing the disk image…"
    xcrun notarytool submit "$image" --keychain-profile "$profile" --wait
    xcrun stapler staple "$image"

    echo "=== disk image assessment ==="
    spctl --assess --type open --context context:primary-signature --verbose=4 "$image"
    ls -lh "$image" | awk '{print "  " $9 "  " $5}'
fi

if [ "$install" = 1 ]; then
    dest="$HOME/Applications/Advect.app"
    osascript -e 'quit app "Advect"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$dest"
    mkdir -p "$HOME/Applications"
    cp -R "$app" "$dest"
    echo "installed $dest"
    open "$dest"
fi
