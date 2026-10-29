#!/usr/bin/env python3
"""Verify the package's generic storage boundary without importing application code."""
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

required = {'PurloryFoundation', 'PurloryStorage'}
missing = required - targets.keys()
assert not missing, f'Missing required boundary targets: {sorted(missing)}'
assert not dependencies('PurloryFoundation'), 'Foundation must not depend on UI, domains or packages'
assert dependencies('PurloryStorage') == {'PurloryFoundation'}, 'Storage must depend only on generic Foundation'
print('Generic Foundation/Storage module boundaries verified')
