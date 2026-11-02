#!/usr/bin/env python3
"""Catch missing or malformed bundled onboarding catalogs before distribution."""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
resources = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Voicelab/Features/Onboarding/Experience/Resources'
languages = {'en', 'uz', 'ru', 'de', 'ko', 'zh-Hans', 'hi', 'es', 'ar', 'fr', 'bn', 'pt', 'id', 'ur', 'ja', 'pcm'}

def validate(reference, value, path):
    assert type(value) is type(reference), f'{path}: incorrect value type'
    if isinstance(reference, dict):
        assert value.keys() == reference.keys(), f'{path}: inconsistent keys'
        for key in reference:
            validate(reference[key], value[key], f'{path}.{key}')
    elif isinstance(reference, list):
        assert len(value) == len(reference), f'{path}: inconsistent list length'
        for index, entry in enumerate(value):
            validate(reference[index], entry, f'{path}[{index}]')
    elif isinstance(value, str):
        assert value.strip(), f'{path}: empty translation'

for name in ['Welcome', 'Permissions', 'Setup', 'TryIt', 'Questionnaire']:
    catalog = json.loads((resources / f'{name}Languages.json').read_text())
    assert set(catalog) == languages, f'{name}: incomplete language coverage'
    for language, copy in catalog.items():
        validate(catalog['en'], copy, f'{name}.{language}')
        if name == 'Welcome':
            assert len(copy['stages']) == 6 and len(copy['captions']) == 4 and len(copy['demoSteps']) == 3
fonts = resources / 'Fonts' if (resources / 'Fonts').is_dir() else resources
assert len(list(fonts.glob('*.ttf'))) == 7, 'Bundle all seven Manrope weights'
assert (fonts / 'OFL.txt').is_file(), 'Bundle the font license'
print('PASS: five catalogs, all 16 languages, complete key/list shapes, seven Manrope weights and font license.')
