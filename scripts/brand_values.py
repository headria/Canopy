"""Read the app's authoritative Swift identity for release tooling."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def load_brand():
    source = (ROOT / 'Sources/CanopyCore/ProductBrand.swift').read_text()
    name = json.loads(re.search(r'public static let name = ("[^"\n]+")', source).group(1))
    colors = {key: f'#{value.lower()}' for key, value in re.findall(
        r'public static let (\w+): UInt32 = 0x([0-9A-Fa-f]{6})', source)}
    assert set(colors) == {'paper', 'ink', 'muted', 'accent', 'border', 'surface', 'primary', 'iconTop'}
    return name, colors
