#!/usr/bin/env python3
"""Reject stale editor assets; runtime never downloads editor code."""
import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
bundle=root/'Resources/NoteEditor'
manifest=json.loads((bundle/'manifest.json').read_text())
for path,expected in manifest['sources'].items():
    assert hashlib.sha256((root/path).read_bytes()).hexdigest()==expected, f'Rebuild note editor after changing {path}: cd EditorWeb && npm ci --ignore-scripts && npm run build'
for path,expected in manifest['outputs'].items():
    assert hashlib.sha256((bundle/path).read_bytes()).hexdigest()==expected, f'Editor bundle mismatch: {path}'
print('Bundled offline editor matches its pinned source and dependencies.')
