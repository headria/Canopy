#!/bin/zsh
# Local sandboxed preview, not an uploadable App Store archive.
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-branding.py
python3 scripts/check-editor-bundle.py
task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[[ -d "$task_sdk" ]] || task_sdk="$(xcrun --show-sdk-path)"
task_arch="${CANOPY_STORE_ARCH:-arm64}"
[[ "$task_arch" == arm64 || "$task_arch" == x86_64 ]] || { print -u2 'CANOPY_STORE_ARCH must be arm64 or x86_64'; exit 1; }
task_scratch="$PWD/build/store-$task_arch-swiftpm"
swift build --build-system native --scratch-path "$task_scratch" --sdk "$task_sdk" \
  --triple "$task_arch-apple-macosx26.0" -c release -Xswiftc -DCANOPY_APP_STORE
task_bin="$(swift build --build-system native --scratch-path "$task_scratch" --sdk "$task_sdk" \
  --triple "$task_arch-apple-macosx26.0" -c release --show-bin-path)"
task_app="$PWD/build/store-preview-$task_arch/Canopy.app"
if lsof -t "$task_app/Contents/MacOS/Canopy" >/dev/null 2>&1; then
  print -u2 'Quit the sandbox preview before rebuilding it.'; exit 1
fi
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/Canopy" "$task_app/Contents/MacOS/Canopy"
cp Resources/StoreInfo.plist "$task_app/Contents/Info.plist"
python3 - "$task_app/Contents/Info.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: info=plistlib.load(f)
# A disposable preview must not attach to the installed app's identity or library.
info.update(CFBundleIdentifier='com.canopy.desktop.storepreview', CFBundleVersion='21',
    CFBundleShortVersionString='1.0', LSMinimumSystemVersion='26.0',
    CanopyPrivacyPolicyURL='', CanopySupportURL='')
info['CanopyPreviewMode']=True
with open(p,'wb') as f: plistlib.dump(info,f)
PY
cp Resources/PrivacyPolicy.txt Resources/PrivacyInfo.xcprivacy StoreAssets/Canopy.icns "$task_app/Contents/Resources/"
rm -rf "$task_app/Contents/Resources/NoteEditor"
cp -R Resources/NoteEditor "$task_app/Contents/Resources/NoteEditor"
codesign --force --sign - --options runtime --entitlements Resources/AppStore.entitlements "$task_app"
codesign --verify --deep --strict "$task_app"
print "Built sandbox preview: $task_app"
