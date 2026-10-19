#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_upload_candidate=NO
if [[ "${1:-}" == --upload-candidate && $# == 1 ]]; then
  task_upload_candidate=YES
elif (( $# != 0 )); then
  print -u2 'Usage: archive-app-store.sh [--upload-candidate]'
  exit 2
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  print -u2 'Full Xcode is required. Select it with Xcode Settings → Locations → Command Line Tools.'
  exit 1
fi
: "${CANOPY_TEAM_ID:?Set CANOPY_TEAM_ID to the team that owns the registered App ID.}"
if [[ "$task_upload_candidate" == YES ]]; then
  python3 scripts/check-store-readiness.py --upload-candidate-config
else
  : "${CANOPY_PRIVACY_POLICY_URL:?Set a published HTTPS privacy policy URL.}"
  : "${CANOPY_SUPPORT_URL:?Set a published HTTPS support URL.}"
  python3 scripts/check-store-readiness.py --release-config
fi
xcodebuild -project Canopy.xcodeproj -scheme CanopyAppStore -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "${CANOPY_ARCHIVE_PATH:-$PWD/build/Canopy-AppStore.xcarchive}" \
  DEVELOPMENT_TEAM="$CANOPY_TEAM_ID" CANOPY_PRIVACY_POLICY_URL="${CANOPY_PRIVACY_POLICY_URL:-}" \
  CANOPY_SUPPORT_URL="${CANOPY_SUPPORT_URL:-}" CANOPY_UPLOAD_CANDIDATE="$task_upload_candidate" \
  -allowProvisioningUpdates archive
print 'Archive created. In Xcode Organizer choose Validate App, then App Store Connect distribution.'
