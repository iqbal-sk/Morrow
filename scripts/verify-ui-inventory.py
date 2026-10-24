#!/usr/bin/env python3
"""Checks rendered size and requested app state; native inventories are diagnostic only.

In-process NSView traversal does not reliably expose SwiftUI's virtual accessibility
elements, even for visible windows. A real external accessibility pass is still needed.
"""
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
expectations = {
    'library': ['Search', 'Add Folders'],
    'browse-min': ['All', 'Screenshots', 'Images', 'Documents', 'Video', 'Audio'],
    'search': ['Search', 'All', 'Open', 'Show in Finder'],
    'code-hint': ['Search'],
    'code-results': ['Search', 'Code'],
    'people': ['Add Person', 'Scan Settings'],
    'activity': ['Manage Folders'],
    'settings-general': ['Search shortcut', 'Open Morrow'],
    'settings-folders': ['Add Folders', 'Reset Directory'],
    'settings-people': ['Enable People search', 'Minimum face size', 'Open People'],
    'settings-code': ['Add Folders', 'Open code in'],
    'settings-storage': ['Reset Index', 'Size on disk'],
    'add-folders': ['Cancel', 'Add'],
    'add-code-folders': ['Cancel', 'Add'],
    'onboarding-welcome': ['Get Started'],
    'onboarding-folders': ['Start Indexing', 'Back'],
    'onboarding-code': ['Continue', 'Back'],
    'onboarding-shortcut': ['Continue', 'Back'],
    'onboarding-ready': ['Done'],
    'panel': ['Search'],
}

def flatten(node):
    if not node:
        return []
    return [node] + [item for child in node.get('children', []) for item in flatten(child)]

results = []
for line in (output / 'manifest.tsv').read_text().splitlines():
    name, requested_width, requested_height = line.split('\t')
    labels = expectations.get(name, ['Search'])
    inventory = json.loads((output / f'{name}.json').read_text())
    nodes = flatten(inventory['root'])
    observed_labels = [label for label in labels if any(label in node['label'] for node in nodes)]
    frame = inventory['root']['frame']
    layout_ok = frame[2] > 0 and frame[3] > 0
    if not name.startswith('add-') and name != 'panel':
        layout_ok = layout_ok and abs(frame[2] - int(requested_width)) <= 1
    state_path = output / f'{name}-state.json'
    state_ok = True
    if name != 'panel':
        state = json.loads(state_path.read_text())
        if name.startswith('settings-'):
            state_ok = state['settingsTab'] == name.removeprefix('settings-')
        elif name.startswith('onboarding-'):
            state_ok = state['onboardingStep'] == name.removeprefix('onboarding-')
        elif name in ('people', 'activity'):
            state_ok = state['destination'] == name
        elif not name.startswith('add-'):
            state_ok = state['destination'] == 'library'
            if name == 'browse-min': state_ok = state_ok and state['browsing'] and state['hasResults']
            if name == 'library': state_ok = state_ok and state['contentState'] == 'home'
            if name == 'search': state_ok = state_ok and state['contentState'] == 'fileResults'
            if name == 'no-results': state_ok = state_ok and state['contentState'] == 'empty'
            if name == 'code-results': state_ok = state_ok and state['contentState'] == 'codeResults'
            if name == 'code-hint': state_ok = state_ok and 'codeHint' in state['contentState']
    result = {'view': name, 'elements': len(nodes), 'frame': frame, 'expectedLabels': labels,
              'observedLabels': observed_labels, 'statePassed': state_ok,
              'layoutPassed': layout_ok, 'semanticStatus': 'external-accessibility-pass-required', 'passed': False}
    results.append(result)
    verdict = 'PARTIAL' if layout_ok and state_ok else 'FAIL'
    print(f"{verdict} {name}: {len(nodes)} native elements; {frame[2]}×{frame[3]}; state {'correct' if state_ok else 'MISMATCH'}")

(output / 'report.json').write_text(json.dumps(results, indent=2))
if any(not result['layoutPassed'] or not result['statePassed'] for result in results):
    raise SystemExit(1)
print('Rendered sizes and requested states checked. Control accessibility, interactions and glass require a visible desktop pass.')
