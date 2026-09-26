#!/usr/bin/env python3
"""Temporary local CA fixtures and real HTTPS validation; no API credentials."""
import argparse
import datetime as dt
import json
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time


def openssl(directory, *args):
    subprocess.run(['openssl', *args], cwd=directory, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def certificates(directory):
    openssl(directory, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '3', '-subj', '/CN=Jevlin Temporary Test CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
    (directory / 'index').write_text('')
    (directory / 'serial').write_text('1000\n')
    (directory / 'newcerts').mkdir()
    now = dt.datetime.now(dt.timezone.utc)
    for name, hostname, start, end in [
        ('valid', 'localhost', now-dt.timedelta(days=1), now+dt.timedelta(days=1)),
        ('expired', 'localhost', now-dt.timedelta(days=2), now-dt.timedelta(days=1)),
        ('wrong_host', 'wrong.example.invalid', now-dt.timedelta(days=1), now+dt.timedelta(days=1)),
        ('future', 'localhost', now+dt.timedelta(days=1), now+dt.timedelta(days=2)),
    ]:
        (directory / 'ca.conf').write_text(f'''[ca]
default_ca = local
[local]
database = index
serial = serial
new_certs_dir = newcerts
certificate = ca.pem
private_key = ca.key
default_md = sha256
policy = policy
unique_subject = no
x509_extensions = server
[policy]
commonName = supplied
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:{hostname}
''')
        openssl(directory, 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', name+'.key', '-out', name+'.csr', '-subj', '/CN='+hostname)
        openssl(directory, 'ca', '-batch', '-notext', '-config', 'ca.conf',
                '-in', name+'.csr', '-out', name+'.pem',
                '-startdate', start.strftime('%Y%m%d%H%M%SZ'), '-enddate', end.strftime('%Y%m%d%H%M%SZ'))
    openssl(directory, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', 'untrusted.key', '-out', 'untrusted.pem', '-days', '1',
            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost')


class Server:
    def __init__(self, directory, name):
        self.name = name
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(directory/(name+'.pem'), directory/(name+'.key'))
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(32)
        self.listener.settimeout(.2)
        self.url = f'https://localhost:{self.listener.getsockname()[1]}/'
        self.stopped = threading.Event()
        self.errors = []
        self.requests = 0
        self.rejected = 0
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                stream, _ = self.listener.accept()
            except socket.timeout:
                continue
            try:
                stream.settimeout(3)
                with self.context.wrap_socket(stream, server_side=True) as tls:
                    data = b''
                    while b'\r\n\r\n' not in data:
                        chunk = tls.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                        if len(data) > 32768:
                            raise ValueError('oversized test request')
                    if b'\r\n\r\n' not in data:
                        self.rejected += 1
                        continue
                    head, body = data.split(b'\r\n\r\n', 1)
                    length = next(int(line.split(b':',1)[1]) for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:'))
                    if length > 32768:
                        raise ValueError('oversized test body')
                    while len(body) < length:
                        chunk = tls.recv(length-len(body))
                        if not chunk:
                            break
                        body += chunk
                    self.requests += 1
                    tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nokay')
            except (ssl.SSLError, ConnectionError):
                self.rejected += 1  # Certificate rejection or injected OOM.
            except Exception as exc:
                self.errors.append(repr(exc))
            finally:
                stream.close()

    def close(self):
        self.stopped.set()
        self.thread.join(4)
        self.listener.close()
        if self.thread.is_alive():
            self.errors.append('server thread did not stop')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--optimize', choices=['Debug', 'ReleaseSafe'], default='Debug')
    parser.add_argument('--report', type=pathlib.Path, default=pathlib.Path('tls-report.json'))
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='jevlin-tls-') as temporary:
        directory = pathlib.Path(temporary)
        binary = directory / 'tls-tests'
        subprocess.run([args.zig, 'test', str(root/'src/http.zig'), '--test-filter', 'TLS fixture',
                        '--test-no-exec', '-O'+args.optimize, '-femit-bin='+str(binary)], check=True)
        certificates(directory)
        verification = {}
        expected = {'valid': None, 'expired': 'certificate has expired', 'wrong_host': 'hostname mismatch',
                    'future': 'certificate is not yet valid', 'untrusted': 'self-signed certificate'}
        for name, reason in expected.items():
            check = subprocess.run(['openssl', 'verify', '-CAfile', 'ca.pem', '-no-CApath', '-no-CAstore',
                                    '-purpose', 'sslserver', '-verify_hostname', 'localhost', name+'.pem'],
                                   cwd=directory, capture_output=True, text=True)
            detail = check.stdout + check.stderr
            if (reason is None and check.returncode != 0) or (reason is not None and (check.returncode == 0 or reason not in detail.lower())):
                raise RuntimeError(f'{name}: fixture did not produce expected verification result: {detail}')
            verification[name] = detail.strip()
        servers = [Server(directory, name) for name in ['valid','expired','wrong_host','future','untrusted']]
        fixture = {server.name: server.url for server in servers}
        fixture['ca'] = str(directory/'ca.pem')
        env = os.environ.copy()
        env['JEVLIN_TLS_FIXTURE'] = json.dumps(fixture)
        started = time.monotonic()
        try:
            run = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=120)
            output = run.stdout + run.stderr
            code = run.returncode
        except subprocess.TimeoutExpired as exc:
            output = 'TLS test process exceeded 120 seconds\n'
            for part in (exc.stdout, exc.stderr):
                if part:
                    output += part.decode(errors='replace') if isinstance(part, bytes) else part
            code = -1
        finally:
            for server in servers:
                server.close()
        evidence = {server.name: {'http_requests': server.requests, 'rejected_connections': server.rejected,
                                 'errors': server.errors} for server in servers}
        # Invalid certificates must be rejected before sending HTTP credentials/body.
        passed = code == 0 and servers[0].requests > 0 and all(not s.errors for s in servers) and all(s.requests == 0 for s in servers[1:])
        report = {'passed': passed, 'optimize': args.optimize, 'elapsed_seconds': round(time.monotonic()-started,3),
                  'exit_code': code, 'servers': evidence, 'fixture_verification': verification, 'test_output': output}
        args.report.write_text(json.dumps(report, indent=2)+'\n')
        print(output, end='')
        print(f'report={args.report} passed={passed}', flush=True)
        return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
