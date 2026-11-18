#!/usr/bin/env bash
set -euo pipefail
# Keep parsing, provenance and subprocess arguments structured; never evaluate user arguments.
exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description='Synthetic editor input baseline. --quick is a smoke subset, not performance acceptance.')
parser.add_argument('--output', required=True, type=Path, help='new directory; existing paths are refused')
parser.add_argument('--quick', action='store_true', help='1k short/plain middle, Latin and synthetic Hangul, immediate, one repetition')
parser.add_argument('--sizes')
parser.add_argument('--shapes')
parser.add_argument('--formats')
parser.add_argument('--positions')
parser.add_argument('--traces')
parser.add_argument('--timings')
parser.add_argument('--repetitions', type=int)
parser.add_argument('--cadence-ms', type=float, default=30)
parser.add_argument('--instrumentation', choices=['on', 'off'], default='on')
parser.add_argument('--signposts', choices=['on', 'off'], default='off')
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
args = parser.parse_args()
choices = {
    'sizes': ('1000,10000,100000,230544,500000,1000000', '1000'),
    'shapes': ('short,long', 'short'), 'formats': ('plain,markdown', 'plain'),
    'positions': ('start,middle,end,moving', 'middle'), 'traces': ('latin,hangul,editing,paste', 'latin,hangul'),
    'timings': ('immediate,idle', 'immediate'),
}
for key, (full, quick) in choices.items():
    value = getattr(args, key) or (quick if args.quick else full)
    parts = value.split(',')
    if len(set(parts)) != len(parts) or not set(parts).issubset(full.split(',')):
        parser.error(f'invalid {key}: {value}')
    setattr(args, key, value)
args.repetitions = args.repetitions if args.repetitions is not None else (1 if args.quick else 5)
if not 1 <= args.repetitions <= 100 or not 1 <= args.cadence_ms <= 1000:
    parser.error('repetitions must be 1...100 and cadence-ms must be finite and 1...1000')
root = Path.cwd()
if not (root / 'Package.swift').is_file() or not (root / 'Tests/PurloryCoreTests/EditorInputBenchmarkTests.swift').is_file():
    parser.error('run this script from the Purlory checkout root')
output = args.output.expanduser().resolve()
if output.exists():
    parser.error('output already exists; choose a new directory')
output.mkdir(parents=True)

def command(arguments):
    return subprocess.check_output(arguments, cwd=root, text=True, stderr=subprocess.STDOUT).strip()

def optional(arguments):
    try:
        return command(arguments)
    except (OSError, subprocess.CalledProcessError):
        return 'unknown'

print('SMOKE SUBSET: not a performance acceptance run.' if args.quick else 'Synthetic matrix: no external visual or real Korean IME measurement.', flush=True)
# Build once, then hash the exact executable used by --skip-build. No package/model download is requested.
build = ['swift', 'build', '--build-tests', '--disable-automatic-resolution', '-c', args.configuration]
with (output / 'build.log').open('w') as log:
    result = subprocess.run(build, cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print(f'Build failed; see {output / "build.log"}', file=sys.stderr)
    sys.exit(result.returncode)
bin_path = Path(command(['swift', 'build', '--show-bin-path', '-c', args.configuration]))
binary = bin_path / 'PurloryPackageTests.xctest/Contents/MacOS/PurloryPackageTests'
if not binary.is_file():
    raise RuntimeError(f'missing built test executable: {binary}')
provenance = {
    'sourceSHA': command(['git', 'rev-parse', 'HEAD']),
    'sourceDirty': str(bool(command(['git', 'status', '--porcelain']))).lower(),
    'trackedDiffSHA256': hashlib.sha256(subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=root)).hexdigest(),
    'configuration': args.configuration,
    'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'executablePath': str(binary), 'swiftVersion': command(['swift', '--version']),
    'macOS': optional(['sw_vers']), 'hardwareModel': optional(['sysctl', '-n', 'hw.model']),
    'architecture': platform.machine(), 'gpu': 'unknown',
    'powerSource': optional(['pmset', '-g', 'batt']),
    'buildCommand': ' '.join(build),
    'runnerArguments': json.dumps(vars(args), default=str, sort_keys=True),
}
(output / 'provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
environment = os.environ.copy()
for key in choices:
    environment['PURLORY_INPUT_BENCHMARK_' + key.upper()] = getattr(args, key)
environment.update({
    'PURLORY_INPUT_BENCHMARK_OUTPUT': str(output),
    'PURLORY_INPUT_BENCHMARK_REPETITIONS': str(args.repetitions),
    'PURLORY_INPUT_BENCHMARK_CADENCE_MS': str(args.cadence_ms),
    'PURLORY_INPUT_BENCHMARK_INSTRUMENTATION': args.instrumentation,
    'PURLORY_INPUT_BENCHMARK_SIGNPOSTS': args.signposts,
    'PURLORY_INPUT_BENCHMARK_QUICK': '1' if args.quick else '0',
    'PURLORY_INPUT_BENCHMARK_ISOLATED': '1',
})
run = ['swift', 'test', '--skip-build', '--disable-automatic-resolution', '-c', args.configuration,
       '--filter', 'EditorInputBenchmarkTests/testRecordBaseline']
with tempfile.TemporaryDirectory(prefix='purlory-input-benchmark-home-') as isolated:
    environment['CFFIXED_USER_HOME'] = isolated
    with (output / 'test.log').open('w') as log:
        result = subprocess.run(run, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
(output / 'execution.json').write_text(json.dumps({'exitCode': result.returncode, 'command': run}, indent=2) + '\n')
if result.returncode:
    print(f'Experiment failed; no successful integrity claim. See {output / "test.log"}', file=sys.stderr)
    sys.exit(result.returncode)
report = json.loads((output / 'report.json').read_text())
assert report['runs'], 'empty report'
for run in report['runs']:
    assert run['integrity']['finalText'] == 'passed'
    assert all(row['requested'] <= row['started'] <= row['ended'] for row in run['schedule'])
    rows = run.get('trace', {}).get('samples', [])
    assert all(a['timestamp'] <= b['timestamp'] for a, b in zip(rows, rows[1:]))
print(f'Recorded {len(report["runs"])} runs in {output}', flush=True)
print('Draw observations, probe delays, and synthetic composition are not external visual/real-IME evidence.', flush=True)
PY
