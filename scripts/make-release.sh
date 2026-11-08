#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Builds a release: PatchPrimeMac-<version>.pkg and PatchPrimeMac-<version>.dmg (the
# installer, the Uninstall app and a Read Me) in build/release. Apple Silicon only.
#
# Releases are signed ad-hoc: no signing key exists anywhere, and anyone can rebuild
# the same thing. macOS ties the microphone permission to the signature, which an
# ad-hoc one changes with every build, so after an update it asks again (once).
# PPMAC_SIGN=<certificate> signs with a certificate instead, from PPMAC_KEYCHAIN
# (default ~/.patchprimemac-signing/signing.keychain-db; PPMAC_KEYCHAIN_PASSWORD, or
# keychain-password.txt there, unlocks it).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(cat packaging/VERSION)"
out="$root/build/release"
identity="${PPMAC_SIGN:--}"
keychain="${PPMAC_KEYCHAIN:-$HOME/.patchprimemac-signing/signing.keychain-db}"
sign() {
    if [ "$identity" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --sign "$identity" --keychain "$keychain" "$@"
    fi
}
if [ "$identity" != "-" ]; then
    pass="${PPMAC_KEYCHAIN_PASSWORD:-$(cat "$HOME/.patchprimemac-signing/keychain-password.txt" 2>/dev/null || true)}"
    [ -n "$pass" ] && security unlock-keychain -p "$pass" "$keychain"
fi

echo "== PatchPrimeMac $version"
rm -rf "$out"
mkdir -p "$out"

echo "== Building (Apple Silicon, release)"
if [ ! -f build/aspl-prefix/lib/libASPL.a ]; then
    # Makefiles, not Ninja: libASPL's custom commands give CMake 4 an empty byproduct,
    # which Ninja rejects ("defined as an output multiple times").
    cmake -S third_party/libASPL -B build/aspl -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$root/build/aspl-prefix" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release
    cmake --build build/aspl --target install -j "$(sysctl -n hw.ncpu)"
fi
cmake -S driver -B build/release-driver -G Ninja -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release
cmake --build build/release-driver
swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"

echo "== Testing"
"$bin/ppdsp-test" | tail -1
"$bin/ppshared-test" | tail -1
"$bin/ppcore-test" | tail -1

echo "== Assembling the app"
payload="$out/payload"
app="$payload/Applications/PatchPrimeMac.app"
engine="$app/Contents/Helpers/PatchPrimeEngine.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$engine/Contents/MacOS"
cp "$bin/PatchPrimeMac" "$bin/patchprime-ctl" "$app/Contents/MacOS/"
cp "$bin/PatchPrimeEngine" "$bin/patchprime-scan" "$engine/Contents/MacOS/"
# The soundboard's built-in sounds (see packaging/sounds/SOURCES.md).
mkdir -p "$engine/Contents/Resources/Sounds"
cp packaging/sounds/*.wav "$engine/Contents/Resources/Sounds/"
cp docs/user-guide.md packaging/uninstall.sh build/release-driver/ppdriver "$app/Contents/Resources/"
# Debug symbols out: they hold the build machine's paths and aren't needed to run.
strip -S "$app/Contents/MacOS/"* "$engine/Contents/MacOS/"* "$app/Contents/Resources/ppdriver"
# The licences of the code built in: ours (GPL) and the third-party notices the BSD
# and MIT licences ask a binary to carry.
notices="$out/THIRD-PARTY-NOTICES.txt"
{
    echo "PatchPrimeMac includes the following third-party software."
    echo "Its own licence is GPL-3.0-or-later (LICENSE.txt). Source: https://github.com/kingsqueak/PatchPrimeMac"
    for part in "RNNoise (Xiph.Org), noise suppression|Sources/RNNoise/COPYING" \
                "libASPL (Victor Gaydov and contributors), the audio driver framework|third_party/libASPL/LICENSE" \
                "libASPL: Apple sample code it is based on (2012)|third_party/libASPL/LICENSE.apple2012" \
                "libASPL: Apple sample code it is based on (2020)|third_party/libASPL/LICENSE.apple2020"; do
        echo; echo "=============================================================================="
        echo "${part%%|*}"; echo "=============================================================================="; echo
        cat "${part#*|}"
    done
    echo; echo "=============================================================================="
    echo "The soundboard's built-in sounds"; echo "=============================================================================="; echo
    cat packaging/sounds/SOURCES.md
} > "$notices"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp "$notices" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>PatchPrimeMac</string>
	<key>CFBundleIdentifier</key><string>com.kingsqueak.patchprimemac</string>
	<key>CFBundleName</key><string>PatchPrimeMac</string>
	<key>CFBundleDisplayName</key><string>PatchPrimeMac</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<!-- macOS asks for the engine's microphone access in the name of the app it lives in. -->
	<key>NSMicrophoneUsageDescription</key><string>PatchPrimeMac mixes your microphones and audio devices. Nothing is sent anywhere.</string>
	<key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later. KC2RGW Chris.</string>
</dict>
</plist>
PL
sed -e "s|<string>0.1</string>|<string>$version</string>|" -e "s|<key>CFBundleVersion</key><string>1</string>|<key>CFBundleVersion</key><string>$version</string>|" \
    packaging/PatchPrimeEngine-Info.plist > "$engine/Contents/Info.plist"
# The Uninstall app: the script asks, uninstall.sh does the work.
uninstall_app="$out/Uninstall PatchPrimeMac.app"
osacompile -o "$uninstall_app" packaging/Uninstall.applescript
cp packaging/uninstall.sh "$app/Contents/Resources/ppdriver" "$uninstall_app/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.kingsqueak.patchprimemac.uninstall" \
    -c "Add :CFBundleShortVersionString string $version" "$uninstall_app/Contents/Info.plist"

echo "== Signing"
sign "$engine/Contents/MacOS/patchprime-scan"
sign "$engine"
sign "$uninstall_app/Contents/Resources/ppdriver"
sign "$uninstall_app"
cp -R "$uninstall_app" "$app/Contents/Resources/"
sign "$app/Contents/Resources/ppdriver" "$app/Contents/MacOS/patchprime-ctl"
sign "$app"
mkdir -p "$payload/Library/Audio/Plug-Ins/HAL"
driver="$payload/Library/Audio/Plug-Ins/HAL/PatchPrimeMac.driver"
cp -R build/release-driver/PatchPrimeMac.driver "$driver"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" "$driver/Contents/Info.plist"
strip -S "$driver/Contents/MacOS/"*
codesign --force --sign - "$driver" # the driver stays ad-hoc: coreaudiod loads it either way
codesign --verify --deep --strict "$app" && echo "app signature checks out"

echo "== Installer"
# macOS file attributes would go into the package as ._ files.
xattr -cr "$payload" "$uninstall_app" 2>/dev/null || true
# Nothing from the build machine's home folder goes out.
if leaked=$(grep -r -l -a -F "$HOME" "$payload" "$uninstall_app"); then
    echo "Build paths from $HOME are in:"; echo "$leaked"; exit 1
fi
scripts="$out/pkg-scripts"
mkdir -p "$scripts"
cat packaging/pkg-scripts/preinstall > "$scripts/preinstall"
cat packaging/pkg-scripts/postinstall > "$scripts/postinstall"
chmod 755 "$scripts"/*
export COPYFILE_DISABLE=1
components="$out/components.plist"
pkgbuild --analyze --root "$payload" "$components" >/dev/null
# Install where it's meant to go, even if a copy of the app exists elsewhere.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$components" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :1:BundleIsRelocatable false" "$components" 2>/dev/null || true
pkgbuild --root "$payload" --component-plist "$components" --scripts "$scripts" \
    --identifier com.kingsqueak.patchprimemac --version "$version" --install-location / \
    "$out/PatchPrimeMac-core.pkg" >/dev/null
resources="$out/installer-resources"
mkdir -p "$resources"
cp packaging/installer/*.html "$resources/"
cp LICENSE "$resources/LICENSE.txt"
sed "s/@VERSION@/$version/g" packaging/distribution.xml.in > "$out/distribution.xml"
productbuild --distribution "$out/distribution.xml" --resources "$resources" --package-path "$out" \
    "$out/PatchPrimeMac-$version.pkg" >/dev/null
rm "$out/PatchPrimeMac-core.pkg"

echo "== Disk image"
stage="$out/dmg"
mkdir -p "$stage"
cp "$out/PatchPrimeMac-$version.pkg" "$stage/"
cp -R "$uninstall_app" "$stage/"
cp "packaging/Read Me.txt" "$stage/"
cp LICENSE "$stage/LICENSE.txt"
cp "$notices" "$stage/"
hdiutil create -volname "PatchPrimeMac $version" -srcfolder "$stage" -format UDZO -ov \
    "$out/PatchPrimeMac-$version.dmg" >/dev/null
rm -rf "$stage"
# The staged apps go too: Spotlight would find them and Finder could open one instead
# of the installed app.
rm -rf "$payload" "$uninstall_app" "$scripts" "$resources" "$notices"

echo "== Done"
ls -lh "$out"/PatchPrimeMac-"$version".*
shasum -a 256 "$out"/PatchPrimeMac-"$version".*
