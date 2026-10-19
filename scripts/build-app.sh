#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-branding.py
python3 scripts/check-editor-bundle.py

# CLT's macOS 27 SDK can require SwiftUI macro plugins supplied only with full Xcode.
# The 26 SDK builds the same macOS 14 deployment target without those plugins.
task_sdk="$(xcrun --show-sdk-path)"
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
swift build --build-system native --sdk "$task_sdk" -c release
task_bin="$(swift build --build-system native --sdk "$task_sdk" -c release --show-bin-path)"
task_destination="${CANOPY_APP_PATH:-$PWD/build/Canopy.app}"
task_identity="${CANOPY_SIGN_IDENTITY:-}"
if [[ -z "$task_identity" ]]; then
    task_identities=()
    while IFS= read -r task_hash; do
        [[ -n "$task_hash" ]] && task_identities+=("$task_hash")
    done < <(security find-identity -v -p codesigning | awk '/"(Apple Development:|Developer ID Application:)/ { print $2 }')
    if (( ${#task_identities} == 1 )); then
        task_identity="${task_identities[1]}"
    else
        print -u2 "Choose a stable signing certificate with CANOPY_SIGN_IDENTITY. Found ${#task_identities} valid Apple signing identities."
        print -u2 "For a disposable preview only, explicitly set CANOPY_SIGN_IDENTITY=-; ad hoc builds do not preserve permission identity across updates."
        exit 1
    fi
fi
mkdir -p "$PWD/build" "${task_destination:h}"
task_staging="$(mktemp -d "${task_destination:h}/.canopy-build.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
task_app="$task_staging/Canopy.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/Canopy" "$task_app/Contents/MacOS/Canopy"
cp Resources/Info.plist "$task_app/Contents/Info.plist"
cp Resources/PrivacyPolicy.txt Resources/PrivacyInfo.xcprivacy "$task_app/Contents/Resources/"
cp -R Resources/NoteEditor "$task_app/Contents/Resources/NoteEditor"
task_icon_builder="$PWD/build/canopy-icon-builder"
swiftc -sdk "$task_sdk" -D CANOPY_ICON_BUILDER Sources/CanopyCore/ProductBrand.swift Sources/CanopyApp/Infrastructure/BrandArtwork.swift scripts/make-icon.swift -o "$task_icon_builder"
"$task_icon_builder" "$task_app/Contents/Resources/Canopy.icns" "$PWD/build/canopy-icon.png" "$PWD/build/canopy-brand.png"
codesign --force --sign "$task_identity" --entitlements Resources/Canopy.entitlements "$task_app"
codesign --verify --deep --strict "$task_app"
if [[ -e "$task_destination" ]]; then
    if lsof -t "$task_destination/Contents/MacOS/Canopy" >/dev/null 2>&1; then
        print -u2 "Quit the Canopy copy at $task_destination before replacing it, or choose a different CANOPY_APP_PATH."
        exit 1
    fi
    mv "$task_destination" "$task_staging/previous.app"
fi
if ! mv "$task_app" "$task_destination"; then
    [[ -e "$task_staging/previous.app" ]] && mv "$task_staging/previous.app" "$task_destination"
    exit 1
fi
print "Built $task_destination"
