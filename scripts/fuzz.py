#!/usr/bin/env python3
"""Bounded, separate coverage-guided campaigns with verified coverage evidence."""
import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--zig', default='zig')
    p.add_argument('--iterations', type=int, default=100_000)
    p.add_argument('--optimize', choices=['Debug', 'ReleaseSafe'], default='Debug')
    p.add_argument('--output', type=pathlib.Path, default=pathlib.Path('fuzz-results'))
    a = p.parse_args()
    if not 1_000 <= a.iterations <= 1_000_000:
        p.error('iterations must be 1000..1000000 per target')
    if platform.system() != 'Linux':
        p.error('This campaign runner currently supports Linux only')
    zig = shutil.which(a.zig)
    if zig is None:
        p.error('Zig executable not found')
    version = subprocess.run([zig, 'version'], capture_output=True, text=True, check=True).stdout.strip()
    if version != '0.16.0':
        p.error('This harness and Smith corpus format require Zig 0.16.0')
    root = pathlib.Path(__file__).resolve().parents[1]
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'zig': version, 'platform': platform.platform(),
              'optimize': a.optimize, 'requested_iterations_per_target': a.iterations,
              'backend': 'LLVM', 'error_return_tracing': False, 'targets': {}}
    report['commit'] = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    report['dirty_checkout'] = bool(subprocess.run(['git', 'status', '--porcelain'], cwd=root, capture_output=True, text=True, check=True).stdout.strip())
    report_path = output/'fuzz-report.json'
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    for target, label in [('parser', 'fuzz parser and typed decoder'), ('encoder', 'fuzz request encoder')]:
        with tempfile.TemporaryDirectory(prefix='jevlin-fuzz-'+target+'-') as directory:
            cache = pathlib.Path(directory)/'cache'
            env = os.environ.copy()
            env.pop('JEVLIN_FUZZ_REPLAY', None)
            env.pop('ZIG_LOCAL_CACHE_DIR', None)
            env['NO_COLOR'] = '1'
            command = [zig, 'build', 'fuzz', '-Dfuzz-target='+target,
                       '-Doptimize='+a.optimize, '--fuzz='+str(a.iterations),
                       '--cache-dir', str(cache), '--summary', 'all']
            started = time.monotonic()
            child = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = child.communicate(timeout=600)
                log, code = stdout+stderr, child.returncode
            except subprocess.TimeoutExpired:
                # Stop the build runner AND its compiler/fuzzer children.
                os.killpg(child.pid, signal.SIGKILL)
                stdout, stderr = child.communicate()
                log = 'Campaign exceeded 600 seconds\n'+stdout+stderr
                code = -1
            (output/(target+'.log')).write_text(log)
            crash = cache/'f/crash'
            crash_saved = crash.exists()
            if crash_saved:
                shutil.copyfile(crash, output/(target+'-crash.smith'))
            runs = re.search(r'Runs: (\d+) -> (\d+)', log)
            unique = re.search(r'Unique runs: (\d+) -> (\d+)', log)
            coverage = re.search(r'Coverage: (\d+)/(\d+) -> (\d+)/(\d+)', log)
            valid = bool(code == 0 and not crash_saved and label in log and runs and unique and coverage
                         and int(runs[1]) == 0 and int(runs[2]) >= a.iterations
                         and 0 < int(coverage[3]) <= int(coverage[4]))
            result = {'passed': valid, 'exit_code': code, 'elapsed_seconds': round(time.monotonic()-started, 3),
                      'runs': int(runs[2]) if runs else None, 'unique_runs': int(unique[2]) if unique else None,
                      'covered_pcs': int(coverage[3]) if coverage else None,
                      'instrumented_pcs': int(coverage[4]) if coverage else None, 'crash_saved': crash_saved}
            report['targets'][target] = result
            report_path.write_text(json.dumps(report, indent=2)+'\n')
            print(target+': '+json.dumps(result), flush=True)
    report['passed'] = all(result['passed'] for result in report['targets'].values())
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
