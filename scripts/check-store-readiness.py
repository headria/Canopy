#!/usr/bin/env python3
"""Validate source configuration; release URLs/team are checked before archive."""
import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/check-branding.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/check-editor-bundle.py')], check=True)
parser = argparse.ArgumentParser()
parser.add_argument('--release-config', action='store_true')
parser.add_argument('--upload-candidate-config', action='store_true', help='Check signing for a draft upload; public contact/URLs may follow before review.')
args = parser.parse_args()

def plist(path):
    with open(root / path, 'rb') as handle: return plistlib.load(handle)

entitlements = plist('Resources/AppStore.entitlements')
assert entitlements['com.apple.security.app-sandbox'] is True
assert entitlements['com.apple.security.network.client'] is True
assert entitlements['com.apple.security.files.bookmarks.app-scope'] is True
assert set(entitlements) == {
    'com.apple.security.app-sandbox', 'com.apple.security.network.client',
    'com.apple.security.device.audio-input', 'com.apple.security.files.user-selected.read-write',
    'com.apple.security.files.bookmarks.app-scope'
}, 'Unexpected sandbox entitlement.'
assert not any('temporary-exception' in key for key in entitlements), 'Store builds must not request sandbox exceptions.'
privacy = plist('Resources/PrivacyInfo.xcprivacy')
assert privacy['NSPrivacyTracking'] is False and not privacy['NSPrivacyTrackingDomains']
assert privacy['NSPrivacyCollectedDataTypes'] == [], 'This release has no AI or other content-upload entry points.'
reasons = {item['NSPrivacyAccessedAPIType']: set(item['NSPrivacyAccessedAPITypeReasons']) for item in privacy['NSPrivacyAccessedAPITypes']}
assert reasons['NSPrivacyAccessedAPICategoryUserDefaults'] == {'CA92.1'}
assert reasons['NSPrivacyAccessedAPICategoryFileTimestamp'] == {'C617.1', '3B52.1'}
assert (root / 'StoreAssets/Canopy.icns').is_file()
assert (root / 'Resources/PrivacyPolicy.txt').stat().st_size > 1000
assert plist('Resources/StoreInfo.plist')['NSHumanReadableCopyright'].strip(), 'macOS uploads require a copyright key.'
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root / 'Canopy.xcodeproj/project.pbxproj')]))
objects = project['objects']
targets = [obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget']
assert {obj['name'] for obj in targets} == {'CanopyCore', 'CanopyAppStore'}
source_refs = [obj for obj in objects.values() if obj.get('lastKnownFileType') == 'sourcecode.swift']
expected = list((root / 'Sources/CanopyCore').rglob('*.swift')) + list((root / 'Sources/CanopyApp').rglob('*.swift'))
assert len(source_refs) == len(expected), 'Regenerate the project after adding source files.'
config = (root / 'Store/Store.xcconfig').read_text()
assert 'CANOPY_APP_STORE' in config and 'MACOSX_DEPLOYMENT_TARGET = 26.0' in config
print('Store project, entitlements, resources and privacy declarations passed source checks.')

if args.release_config or args.upload_candidate_config:
    assert os.environ.get('CANOPY_TEAM_ID'), 'Missing Apple Developer team'
    for name in ('CANOPY_PRIVACY_POLICY_URL', 'CANOPY_SUPPORT_URL'):
        raw_value = os.environ.get(name, '')
        if args.upload_candidate_config and not args.release_config and not raw_value:
            continue
        value = urlparse(raw_value)
        assert value.scheme == 'https' and value.hostname and not value.username and not value.password, f'{name} must be public HTTPS'
        assert value.hostname not in {'localhost', 'example.com', 'example.org', '127.0.0.1'}, f'{name} is still a placeholder'
    if args.release_config:
        print('Release team and URL values supplied. Verify ownership and public page availability before review.')
    else:
        print('Draft upload signing configured. Complete public URLs, contact details and live meeting verification before App Review.')
