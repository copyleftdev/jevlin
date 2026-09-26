#!/usr/bin/env python3
"""Linux-only local TLS rejection and same-process lifecycle soak; no API key."""
import argparse
import json
import pathlib
import socket
import ssl
import statistics
import subprocess
import tempfile
import threading
import time
import os

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--zig', default='zig')
p.add_argument('--seconds', type=int, default=300)
p.add_argument('--report', type=pathlib.Path, default=pathlib.Path('soak-report.json'))
a = p.parse_args()
if not 30 <= a.seconds <= 86400:
    p.error('--seconds must be 30..86400')
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='jevlin-soak-') as temporary:
    temp = pathlib.Path(temporary)
    binary = temp / 'transport-tests'
    subprocess.run([a.zig, 'test', str(root / 'src/http.zig'), '--test-filter', 'opt-in',
                    '--test-no-exec', '-OReleaseSafe', '-femit-bin=' + str(binary),
                    '--global-cache-dir', str(temp / 'cache')], check=True)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(temp / 'key.pem'), '-out', str(temp / 'cert.pem'),
                    '-days', '1', '-subj', '/CN=localhost',
                    '-addext', 'subjectAltName=IP:127.0.0.1'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(temp / 'cert.pem', temp / 'key.pem')
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(.25)
    stopped = threading.Event()
    server_errors = []
    def serve():
        while not stopped.is_set():
            try:
                stream, _ = listener.accept()
            except socket.timeout:
                continue
            try:
                stream.settimeout(5)
                with context.wrap_socket(stream, server_side=True) as tls:
                    tls.recv(4096)
            except (ssl.SSLError, ConnectionError):
                pass  # Peer rejection of the self-signed certificate is expected.
            except Exception as exc:
                server_errors.append(repr(exc))
            finally:
                stream.close()
    server = threading.Thread(target=serve, daemon=True)
    server.start()
    env = os.environ.copy()
    env['JEVLIN_SOAK_SECONDS'] = str(a.seconds)
    env['JEVLIN_TEST_TLS_URL'] = f'https://127.0.0.1:{listener.getsockname()[1]}/'
    samples = []
    started = time.monotonic()
    with (temp / 'run.log').open('w+') as log:
        child = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            while child.poll() is None:
                if time.monotonic() - started > a.seconds + 60:
                    raise TimeoutError('soak exceeded duration plus 60 second cleanup allowance')
                try:
                    status = pathlib.Path(f'/proc/{child.pid}/status').read_text()
                    fields = dict(line.split(':', 1) for line in status.splitlines())
                    samples.append({'seconds': round(time.monotonic()-started, 3),
                                    'rss_kib': int(fields['VmRSS'].split()[0]),
                                    'threads': int(fields['Threads']),
                                    'fds': len(list(pathlib.Path(f'/proc/{child.pid}/fd').iterdir()))})
                except (FileNotFoundError, ProcessLookupError, KeyError):
                    pass
                time.sleep(.5)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
            stopped.set()
            server.join(6)
            listener.close()
        log.seek(0)
        output = log.read()
    n = len(samples)
    middle = samples[n//4:n//2]
    last = samples[3*n//4:]
    plateau = bool(middle and last) and statistics.median(s['rss_kib'] for s in last) <= statistics.median(s['rss_kib'] for s in middle) + 16384
    threads = bool(middle and last) and statistics.median(s['threads'] for s in last) <= statistics.median(s['threads'] for s in middle) + 4
    passed = child.returncode == 0 and plateau and threads and not server_errors
    report = {'passed': passed, 'requested_seconds': a.seconds,
              'elapsed_seconds': round(time.monotonic()-started, 3), 'exit_code': child.returncode,
              'rss_plateau_gate': plateau, 'thread_plateau_gate': threads,
              'rss_growth_allowance_kib': 16384, 'thread_growth_allowance': 4,
              'samples': samples, 'test_output': output, 'server_errors': server_errors}
    a.report.write_text(json.dumps(report, indent=2) + '\n')
    print(output, end='')
    print(f'report={a.report} passed={passed} samples={n}', flush=True)
    raise SystemExit(0 if passed else 1)
