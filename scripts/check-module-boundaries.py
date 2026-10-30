#!/usr/bin/env python3
"""Enforce the application's dependency direction without loading its runtime."""
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

required = {'PurloryFoundation', 'PurloryStorage', 'PurloryInference',
            'PurloryDocumentEngine', 'PurloryIntelligence', 'PurloryWorkspaceUI'}
missing = required - targets.keys()
assert not missing, f'Missing required boundary targets: {sorted(missing)}'
assert not dependencies('PurloryFoundation'), 'Foundation must not depend on UI, domains or packages'
assert dependencies('PurloryStorage') == {'PurloryFoundation'}, 'Storage must depend only on generic Foundation'
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
assert dependencies('PurloryCore') == required, 'Core must only re-export the six implementation modules'
print('All six implementation modules and the Core facade have valid dependency boundaries')
