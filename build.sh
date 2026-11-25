#!/bin/zsh
set -eu

source_dir=${0:A:h}
if [[ $# != 1 || $1 != /* || $1 != */FoldDay.app || -e $1 ]]; then
    print -u2 "Usage: zsh build.sh /absolute/path/to/new/FoldDay.app"
    exit 2
fi
app=$1
contents=$app/Contents
mkdir -p "$contents/MacOS" "$contents/Resources"

archs=($(/usr/bin/uname -m))
if [[ "${FOLDDAY_UNIVERSAL:-0}" == 1 ]]; then
    archs=(arm64 x86_64)
fi
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/foldday-build.XXXXXXXX")
trap '/bin/rm -R -- "$stage"' EXIT
helpers=()
apps=()
for arch in "${archs[@]}"; do
    target="$arch-apple-macos14.0"
    helpers+=("$stage/lidawake-power-$arch")
    apps+=("$stage/FoldDay-$arch")
    /usr/bin/swiftc -warnings-as-errors -swift-version 5 -O -target "$target" \
        "$source_dir/PowerControl.swift" "$source_dir/PowerHelper.swift" \
        -o "$stage/lidawake-power-$arch"
    /usr/bin/swiftc -warnings-as-errors -swift-version 5 -O -target "$target" \
        -import-objc-header "$source_dir/KeychainLookup.h" \
        "$source_dir/PowerControl.swift" "$source_dir/MacHardware.swift" "$source_dir/ProximitySettings.swift" \
        "$source_dir/ProximityEvidence.swift" "$source_dir/Proximity.swift" "$source_dir/Localization.swift" "$source_dir/FoldDay.swift" \
        -o "$stage/FoldDay-$arch"
done
if (( ${#archs[@]} > 1 )); then
    /usr/bin/lipo -create "${helpers[@]}" -output "$contents/Resources/lidawake-power"
    /usr/bin/lipo -create "${apps[@]}" -output "$contents/MacOS/FoldDay"
else
    /bin/cp "${helpers[1]}" "$contents/Resources/lidawake-power"
    /bin/cp "${apps[1]}" "$contents/MacOS/FoldDay"
fi
/bin/cp "$source_dir/LICENSE-BLEUnlock" "$contents/Resources/LICENSE-BLEUnlock"
/bin/cp -R "$source_dir/Resources/en.lproj" "$source_dir/Resources/zh-Hans.lproj" "$contents/Resources/"

/usr/bin/printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>local.lidawake</string>' \
    '<key>CFBundleExecutable</key><string>FoldDay</string>' \
    '<key>CFBundleDevelopmentRegion</key><string>en</string>' \
    '<key>CFBundleName</key><string>FoldDay</string>' \
    '<key>CFBundleDisplayName</key><string>FoldDay</string>' \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '<key>CFBundleShortVersionString</key><string>1.3.0</string>' \
    '<key>CFBundleVersion</key><string>7</string>' \
    '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
    '<key>LSUIElement</key><true/>' \
    '<key>NSHighResolutionCapable</key><true/>' \
    '<key>NSBluetoothAlwaysUsageDescription</key><string>FoldDay uses Bluetooth LE signals from your selected devices to detect proximity.</string>' \
    '</dict></plist>' > "$contents/Info.plist"

/usr/bin/codesign --force --sign - --identifier local.lidawake.power "$contents/Resources/lidawake-power"
identity=${FOLDDAY_SIGNING_IDENTITY:--}
if [[ "$identity" == - ]]; then
    /usr/bin/codesign --force --sign - "$app"
else
    if [[ ! "$identity" =~ '^[0-9a-fA-F]{40}$' ]]; then
        print -u2 "FOLDDAY_SIGNING_IDENTITY must be the signing certificate's SHA-1 fingerprint."
        exit 2
    fi
    keychain=()
    if [[ -n ${FOLDDAY_SIGNING_KEYCHAIN:-} ]]; then
        keychain=(--keychain "$FOLDDAY_SIGNING_KEYCHAIN")
    fi
    /usr/bin/codesign --force --sign "$identity" "${keychain[@]}" --options runtime --timestamp=none \
        --requirements "=designated => identifier \"local.lidawake\" and certificate leaf = H\"$identity\"" "$app"
fi
/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app"
