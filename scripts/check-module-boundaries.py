#!/usr/bin/env python3
"""Enforce the application's dependency direction, target hygiene, and retirement invariants without loading its runtime."""
import json
from pathlib import Path
import re
import subprocess

package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package']))
targets = {target['name']: target for target in package['targets']}


def dependencies(name):
    result = set()
    for dependency in targets[name]['dependencies']:
        for kind in ('byName', 'target', 'product'):
            if kind in dependency:
                result.add(dependency[kind][0])
    return result


required = {
    'PurloryFoundation',
    'PurloryStorage',
    'PurloryInference',
    'PurloryDocumentEngine',
    'PurloryIntelligence',
    'PurloryWorkspaceUI',
}
missing = required - targets.keys()
assert not missing, f'Missing required boundary targets: {sorted(missing)}'
assert not dependencies('PurloryFoundation'), 'Foundation must not depend on UI, domains or packages'
assert dependencies('PurloryStorage') == {'PurloryFoundation'}, 'Storage must depend only on generic Foundation'
assert dependencies('PurloryDocumentEngine') == {'PurloryFoundation', 'SwiftMath'}, (
    f"DocumentEngine has unexpected dependencies: {sorted(dependencies('PurloryDocumentEngine'))}"
)
assert not (dependencies('PurloryInference') & {'SwiftMath', 'PurloryKoreanBackend'}), (
    f"Inference must not depend on SwiftMath or KoreanBackend: {sorted(dependencies('PurloryInference'))}"
)

allowed = {
    'PurloryFoundation': set(),
    'PurloryStorage': {'PurloryFoundation'},
    'PurloryInference': {'PurloryFoundation'},
    'PurloryDocumentEngine': {'PurloryFoundation'},
    'PurloryIntelligence': {'PurloryFoundation', 'PurloryStorage', 'PurloryDocumentEngine', 'PurloryInference'},
    'PurloryWorkspaceUI': required - {'PurloryWorkspaceUI'},
    'PurloryCore': required,
}
for name, permitted in allowed.items():
    actual = dependencies(name) & (required | {'PurloryCore'})
    assert actual <= permitted, f'{name} has forbidden dependencies: {sorted(actual - permitted)}'
    for path in Path('Sources', name).rglob('*.swift'):
        imported = set(re.findall(r'^\s*(?:@[\w()]+\s+)*import\s+(\w+)', path.read_text(), re.MULTILINE))
        forbidden = (imported & (required | {'PurloryCore'})) - permitted
        assert not forbidden, f'{path} imports forbidden application modules: {sorted(forbidden)}'
        if name in {'PurloryFoundation', 'PurloryStorage', 'PurloryInference', 'PurloryIntelligence'}:
            assert not (imported & {'AppKit', 'SwiftUI', 'UIKit'}), f'{path} imports UI frameworks'
        if name != 'PurloryCore':
            assert '@_exported' not in path.read_text(), (
                f'{path} uses @_exported import; only PurloryCore may re-export implementation modules'
            )

assert dependencies('PurloryCore') == required, 'Core must only re-export the six implementation modules'
assert dependencies('Purlory') == {'PurloryCore'}, (
    f"Purlory app shell must depend only on PurloryCore: {sorted(dependencies('Purlory'))}"
)
assert dependencies('PurloryBench') <= {'PurloryCore', 'PurloryInference', 'PurloryIntelligence'}, (
    f"PurloryBench has unexpected dependencies: {sorted(dependencies('PurloryBench'))}"
)

retired_legacy_files = {
    'EntryStore.swift',
    'TrashStore.swift',
    'LegacyWorkspaceController.swift',
    'LegacyWorkspaceView.swift',
    'SidebarView.swift',
    'SidebarDragDrop.swift',
    'NarrativeView.swift',
    'CharacterBibleView.swift',
    'ContextInspectorView.swift',
}
for path in Path('Sources', 'PurloryWorkspaceUI').rglob('*.swift'):
    assert path.name not in retired_legacy_files, f'Retired legacy UI file reintroduced: {path}'

for path in Path('Sources', 'PurloryWorkspaceUI', 'Editor').rglob('*.swift'):
    text = path.read_text()
    assert 'nonisolated(unsafe)' not in text, (
        f'{path} introduces nonisolated(unsafe) in Editor; isolate access via @MainActor or OSAllocatedUnfairLock'
    )

print('All six implementation modules, executables, retirement guards, and Editor isolation boundaries are valid')
