#!/bin/bash
# Package a fresh app copy so release signing never changes the development app.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-local}"
case "$mode" in
    local) ;;
    release)
        : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name or SHA-1 hash}"
        : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
        ;;
    *) echo "Usage: $0 [local|release]" >&2; exit 1 ;;
esac

app="dist/LinkCam.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a numeric major.minor.patch app version; got: $version" >&2
    exit 1
fi

filename="LinkCam-$version-universal"
if [[ "$mode" == local ]]; then
    filename="$filename-unnotarized"
    echo "Creating an ad-hoc signed DMG for testing. Public releases need make release." >&2
fi

work_dir=$(mktemp -d "$PWD/dist/.dmg.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
stage="$work_dir/volume"
mkdir -p "$stage"
ditto "$app" "$stage/LinkCam.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Install.txt" <<'INSTALL'
LinkCam

1. Drag LinkCam.app to Applications.
2. Eject this disk image.
3. Open LinkCam from Applications.
4. Click the video-camera icon in your menu bar to open the controls.

Requires macOS 13 Ventura or later and an Insta360 Link 2.
The app supports Apple Silicon and Intel Macs.
Allow camera access when prompted to enable the live preview.
INSTALL
if [[ "$mode" == local ]]; then
    cat >> "$stage/Install.txt" <<'NOTICE'

TEST BUILD: This copy is ad-hoc signed and has not been notarized by Apple.
macOS Gatekeeper may block it when downloaded. Use the signed, notarized
release for public distribution.
NOTICE
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements app/LinkCam.entitlements "$stage/LinkCam.app"
    # Reject a development certificate or ad-hoc signature before uploading.
    if ! codesign -dv --verbose=4 "$stage/LinkCam.app" 2>&1 \
        | grep '^Authority=Developer ID Application:' > /dev/null; then
        echo "Public releases require a Developer ID Application certificate." >&2
        exit 1
    fi
fi
codesign --verify --deep --strict --verbose=2 "$stage/LinkCam.app"
lipo "$stage/LinkCam.app/Contents/MacOS/LinkCam" -verify_arch arm64 x86_64

if [[ "$mode" == release ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
        notary_args+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    # Staple the app first so it keeps its ticket after copying to Applications.
    ditto -c -k --keepParent "$stage/LinkCam.app" "$work_dir/LinkCam.zip"
    xcrun notarytool submit "$work_dir/LinkCam.zip" "${notary_args[@]}" --wait
    xcrun stapler staple "$stage/LinkCam.app"
    xcrun stapler validate "$stage/LinkCam.app"
    spctl --assess --type execute --verbose=2 "$stage/LinkCam.app"
fi

dmg="$work_dir/$filename.dmg"
hdiutil create -volname "LinkCam $version" -srcfolder "$stage" -format UDZO "$dmg"
if [[ "$mode" == release ]]; then
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi
hdiutil verify "$dmg"
mv -f "$dmg" "dist/$filename.dmg"
(
    cd dist
    shasum -a 256 "$filename.dmg" > "$filename.dmg.sha256"
)
echo "Created dist/$filename.dmg and its SHA-256 checksum."
