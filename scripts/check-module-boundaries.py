#!/usr/bin/env python3
"""Enforce the application's dependency direction without loading its runtime."""
import json
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
assert dependencies('PurloryCore') == required, 'Core must only re-export the six implementation modules'
print('All six implementation modules and the Core facade have valid dependency boundaries')
