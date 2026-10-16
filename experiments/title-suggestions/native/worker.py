"""Private stdio worker owned by the native title loader; no TCP listener."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import re
from pathlib import Path
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from title_service import NativeTitleService, Failure  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binding', required=True, type=Path)
    args = parser.parse_args()
    lock = threading.Lock()

    def emit(value):
        with lock:
            sys.stdout.write(json.dumps(value, ensure_ascii=False) + '\n')
            sys.stdout.flush()

    try:
        binding = json.loads(args.binding.read_text(encoding='utf-8-sig'))
        cli = Path(binding['cli']['path'])
        compatibility = binding.get('compatibility', {})
        if (compatibility.get('passed') is not True or compatibility.get('toolCount') != 0
                or compatibility.get('environmentHeaderVerified') is not True
                or compatibility.get('cliSha256') != binding['cli'].get('sha256')):
            raise Failure('offline_compatibility_required')
        service = NativeTitleService(Path(binding['home']), Path(binding['profile']), cli,
                                     model=binding['model'], live=True, timeout=45)
    except Exception:
        emit({'type': 'failed', 'error': 'worker_initialization_failed'})
        return 1
    emit({'type': 'ready'})
    capacity = threading.BoundedSemaphore(2)
    active = set()
    state_lock = threading.Lock()
    stopping = threading.Event()

    def run(message):
        request = message['data']
        request_id = request.get('requestId')
        try:
            with state_lock:
                active.add(request_id)
                if stopping.is_set():
                    raise Failure('cancelled')
            result = service.suggest(request)
            emit({'id': message['id'], 'result': result})
        except Failure as error:
            emit({'id': message['id'], 'error': str(error)})
        except Exception:
            emit({'id': message['id'], 'error': 'generation_failed'})
        finally:
            with state_lock:
                active.discard(request_id)
            capacity.release()

    with ThreadPoolExecutor(max_workers=2) as pool:
        try:
            while True:
                raw = sys.stdin.buffer.readline(16385)
                if not raw:
                    break
                if len(raw) > 16384 or not raw.endswith(b'\n'):
                    break
                try:
                    message = json.loads(raw)
                    if not isinstance(message, dict):
                        continue
                    if message.get('method') == 'shutdown':
                        break
                    ident = message.get('id')
                    data = message.get('data')
                    if not isinstance(ident, str) or len(ident) > 100 or not isinstance(data, dict):
                        continue
                    if message.get('method') == '/native/cancel':
                        request_id = data.get('requestId')
                        if isinstance(request_id, str) and len(request_id) <= 100:
                            service.cancel(request_id)
                        emit({'id': ident, 'result': {'cancelled': True}})
                    elif message.get('method') == '/native/suggest':
                        if not isinstance(data.get('requestId'), str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', data['requestId']):
                            emit({'id': ident, 'error': 'invalid_identity'})
                        elif not capacity.acquire(blocking=False):
                            emit({'id': ident, 'error': 'busy'})
                        else:
                            pool.submit(run, message)
                    else:
                        emit({'id': ident, 'error': 'unsupported_method'})
                except (ValueError, UnicodeError):
                    continue
        finally:
            stopping.set()
            with state_lock:
                for request_id in active:
                    if isinstance(request_id, str):
                        service.cancel(request_id)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
