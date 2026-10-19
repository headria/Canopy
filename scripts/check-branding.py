#!/usr/bin/env python3
"""Fail a release build if its public names or website palette drift apart."""
import argparse
import json
import plistlib
from pathlib import Path
from brand_values import ROOT, load_brand

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path)
args = parser.parse_args()
name, palette = load_brand()

def check_info(path):
    with path.open('rb') as file: info = plistlib.load(file)
    assert info['CFBundleName'] == name and info['CFBundleDisplayName'] == name, f'Name mismatch: {path}'
    return info

check_info(ROOT / 'Resources/Info.plist')
check_info(ROOT / 'Resources/StoreInfo.plist')
metadata = json.loads((ROOT / 'Store/metadata.en-US.json').read_text())
assert metadata.get('applicationName', metadata['name']) == name
assert metadata['name'] == name or metadata['name'].startswith(name + ': '), 'Store listing must retain the app brand.'
assert len(metadata['name']) <= 30, 'Store listing name exceeds Apple\'s limit.'
assert f'PRODUCT_NAME = {name}\n' in (ROOT / 'Store/Store.xcconfig').read_text()
for page in ('privacy', 'support'):
    html = (ROOT / f'Store/Web/{page}.html').read_text()
    assert f'— {name}</title>' in html
    assert all(palette[key] in html for key in ('paper', 'ink', 'primary', 'border'))

def luminance(hex_color):
    rgb = [int(hex_color[index:index+2], 16) / 255 for index in (1, 3, 5)]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in rgb]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

for foreground, background in [('ink', 'paper'), ('muted', 'paper'), ('paper', 'primary'), ('ink', 'accent')]:
    values = sorted([luminance(palette[foreground]), luminance(palette[background])])
    assert (values[1] + 0.05) / (values[0] + 0.05) >= 4.5, f'Low text contrast: {foreground}/{background}'
if args.app:
    info = check_info(args.app / 'Contents/Info.plist')
    assert (args.app / 'Contents/MacOS' / info['CFBundleExecutable']).is_file()
    assert (args.app / 'Contents/Resources' / (info['CFBundleIconFile'] + '.icns')).is_file()
print(f'{name}: app branding, Store listing, website palette and primary text contrast passed.')
