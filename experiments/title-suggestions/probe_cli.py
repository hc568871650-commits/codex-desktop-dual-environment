"""Offline compatibility probe: isolated Home + loopback fake Responses endpoint, no API calls."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import title_service as m


def probe(cli):
    captured = []
    header_checks = []
    class Capture(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            header_checks.append(self.headers.get('x-title-offline-check') == 'offline-only')
            try:
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                captured.append(body)
            except Exception:
                captured.append({'captureError': True})
            data = b'{"error":{"message":"offline probe finished","type":"invalid_request_error"}}'
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    server = HTTPServer(('127.0.0.1', 0), Capture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codex-title-offline-probe-') as folder:
            root = Path(folder)
            home = root / 'home'
            temp = root / 'work'
            home.mkdir(); temp.mkdir()
            (temp / 'schema.json').write_text(json.dumps(m.SCHEMA), encoding='utf8')
            route = ('probe', 'gpt-6-luna', {'name':'Offline probe', 'wire_api':'responses',
                     'base_url':f'http://127.0.0.1:{server.server_port}/v1',
                     'request_max_retries':0, 'stream_max_retries':0,
                     'http_headers':{'x-title-offline-check':'offline-only'}})
            argv, env = m.command(cli, home, temp, route)
            result = subprocess.run(argv, input=b'Generate a title for: Test title preview.',
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=env, cwd=temp, timeout=40,
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if not captured:
                # Only isolated fake-credential logs are included; never use with a real Home.
                return {'passed':False, 'reason':'no_request_captured'}
            body = captured[0]
            names = [tool.get('name', tool.get('type')) for tool in body.get('tools', [])]
            return {'passed':not names and not body.get('captureError') and all(header_checks),
                              'capturedRequests':len(captured), 'toolNames':names,
                              'environmentHeaderVerified':all(header_checks),
                              'inputCharacters':len(json.dumps(body.get('input', []))),
                              'inputKinds': [(i.get('role'), len(json.dumps(i))) for i in body.get('input', [])],
                              'model':body.get('model')}
    finally:
        server.shutdown(); server.server_close(); worker.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = probe(args.cli)
    except (OSError, subprocess.TimeoutExpired):
        result = {'passed':False, 'reason':'cli_probe_failed'}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
