import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import title_service as m


def request(request_id="request-1", **extra):
    return {"requestId": request_id, "threadId": "thread-a", "currentTitle": "旧名字",
            "messages": [{"role": "user", "text": "帮我改善双开体验"}], **extra}


class CoreTests(unittest.TestCase):
    def test_context_bounds_and_empty(self):
        result = m.bounded_context([{"role": "user", "text": "中" * 5000}] * 20)
        self.assertEqual(sum(len(x["text"]) for x in result), 8000)
        with self.assertRaisesRegex(m.Failure, "empty_context"):
            m.bounded_context([])

    def test_json_schema_and_control_characters(self):
        self.assertEqual(m.validate_title('{"title":" 中文标题 "}'), "中文标题")
        for raw in ['no json', '{}', '{"title":"a","extra":1}', '{"title":42}', '{"title":"a\\nb"}', json.dumps({"title":"中" * 61})]:
            with self.assertRaises(m.Failure):
                m.validate_title(raw)

    def test_cache_refresh_cancel_and_thread_isolation(self):
        gen = m.Generator()
        self.assertFalse(gen.generate(request())["cached"])
        self.assertTrue(gen.generate(request("request-2"))["cached"])
        self.assertFalse(gen.generate(request("request-3", refresh=True))["cached"])
        self.assertFalse(gen.generate(request("request-4", threadId="thread-b"))["cached"])
        gen.cancel("request-5")
        with self.assertRaisesRegex(m.Failure, "cancelled"):
            gen.generate(request("request-5"))

    def test_mid_request_cancel(self):
        gen, errors = m.Generator(), []
        def run():
            try:
                gen.generate(request())
            except m.Failure as exc:
                errors.append(str(exc))
        worker = threading.Thread(target=run)
        worker.start()
        time.sleep(.05)
        gen.cancel("request-1")
        worker.join(2)
        self.assertEqual(errors, ["cancelled"])
        self.assertFalse(gen.cache)

    def test_route_and_no_key_on_command_line(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"TEST_TITLE_KEY": "secret-never-in-argv"}):
            home = Path(folder)
            (home / "config.toml").write_text('model_provider="test"\nmodel="gpt-6-luna"\n[model_providers.test]\nname="Test"\nbase_url="https://example.com/v1"\nwire_api="responses"\nenv_key="TEST_TITLE_KEY"', encoding="utf8")
            route = m.load_route(home)
            args, env = m.command(Path("codex.exe"), home, home, route)
            self.assertNotIn("secret-never-in-argv", " ".join(args))
            self.assertEqual(env["TEST_TITLE_KEY"], "secret-never-in-argv")
            self.assertEqual(env["CODEX_HOME"], str(home))
            self.assertIn('--ignore-user-config', args)
            self.assertIn('model_provider="test"', args)
            self.assertIn('--ephemeral', args)
            with (home / "config.toml").open("a") as stream:
                stream.write('\nexperimental_bearer_token="bad"')
            with self.assertRaisesRegex(m.Failure, "unsupported_provider_fields"):
                m.load_route(home)

    def test_mocked_cli_success_and_timeout(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            route = ("test", "model", {"name": "test", "base_url": "http://127.0.0.1:1", "wire_api": "responses"})
            gen = m.Generator()
            gen.home, gen.cli, gen.route, gen.timeout = home, home / "codex.exe", route, .01
            class Process:
                returncode = 0
                def poll(self): return self.returncode
                def wait(self, timeout): return self.returncode
                def kill(self): self.returncode = -9
            def successful(args, **kwargs):
                output = Path(args[args.index('--output-last-message') + 1])
                output.write_text('{"title":"模拟结果"}', encoding="utf8")
                return Process()
            with patch.object(m, 'load_route', return_value=route), patch.object(subprocess, 'Popen', side_effect=successful):
                self.assertEqual(gen.invoke([], '', threading.Event(), False), '模拟结果')
            proc = Process()
            proc.returncode = None
            with patch.object(m, 'load_route', return_value=route), patch.object(subprocess, 'Popen', return_value=proc):
                with self.assertRaisesRegex(m.Failure, 'timeout'):
                    gen.invoke([], '', threading.Event(), False)
                self.assertEqual(proc.returncode, -9)

    def _unread_stdin_process(self, cancellation):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            route = ("test", "model", {"name":"Test", "base_url":"http://127.0.0.1:1"})
            gen, stop = m.Generator(), threading.Event()
            gen.home, gen.cli, gen.route = home, Path(sys.executable), route
            gen.timeout = 10 if cancellation else .1
            folders, processes = [], []
            original_popen = subprocess.Popen
            def sleeping_command(cli, codex_home, temp, selected):
                folders.append(temp)
                return [sys.executable, '-c', 'import time; time.sleep(5)'], os.environ.copy()
            def launch(*args, **kwargs):
                self.assertNotEqual(kwargs['stdin'], subprocess.PIPE)
                self.assertGreater(os.fstat(kwargs['stdin'].fileno()).st_size, 24_000)
                proc = original_popen(*args, **kwargs)
                processes.append(proc)
                return proc
            timer = threading.Timer(.1, stop.set) if cancellation else None
            if timer:
                timer.start()
            start = time.monotonic()
            try:
                with patch.object(m, 'load_route', return_value=route), patch.object(m, 'command', side_effect=sleeping_command), patch.object(subprocess, 'Popen', side_effect=launch):
                    with self.assertRaisesRegex(m.Failure, 'cancelled' if cancellation else 'timeout'):
                        gen.invoke([{'role':'user', 'text':'中' * 8000}], '', stop, False)
                self.assertLess(time.monotonic() - start, 1.5, 'must not wait for unread-stdin child sleep')
                self.assertTrue(processes and processes[0].poll() is not None)
                self.assertTrue(folders and not folders[0].exists(), 'private prompt/output directory must be removed')
            finally:
                if timer:
                    timer.cancel()
                    timer.join()
                for proc in processes:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=3)

    def test_real_unread_stdin_process_timeout(self):
        self._unread_stdin_process(False)

    def test_real_unread_stdin_process_cancel(self):
        self._unread_stdin_process(True)


    def test_header_secrets_only_in_child_environment(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CODEX_TEST_HEADER": "from-env-secret"}):
            home = Path(folder)
            base = 'model_provider="test"\nmodel="gpt-6-luna"\n[model_providers.test]\nname="Test"\nbase_url="https://example.com/v1"\n'
            valid = base + '[model_providers.test.http_headers]\nx-openai-actor-authorization="bait-key"\n[model_providers.test.env_http_headers]\nx-extra="CODEX_TEST_HEADER"'
            (home / 'config.toml').write_text(valid, encoding='utf8')
            route = m.load_route(home)
            argv, env = m.command(Path('codex.exe'), home, home, route)
            self.assertNotIn('bait-key', ' '.join(argv))
            self.assertNotIn('from-env-secret', ' '.join(argv))
            self.assertIn('bait-key', env.values())
            self.assertEqual(env['CODEX_TEST_HEADER'], 'from-env-secret')
            self.assertTrue(any('env_http_headers={"x-openai-actor-authorization" = "TITLE_PREVIEW_HEADER_' in x for x in argv))
            for invalid in ('http_headers={"bad name"="a"}', 'http_headers={"x"=""}', 'http_headers={"x"="a\\r\\nb"}', 'env_http_headers={"x"="MISSING_TITLE_TEST_ENV"}'):
                (home / 'config.toml').write_text(base + invalid, encoding='utf8')
                with self.assertRaises(m.Failure):
                    m.load_route(home)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = m.Server(m.Generator())
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def call(self, path, body, headers=None, method="POST"):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        good = {"Origin": self.server.origin, "X-Title-Token": self.server.token, "Content-Type": "application/json"}
        good.update(headers or {})
        conn.request(method, path, body, good)
        response = conn.getresponse()
        content = response.read()
        conn.close()
        return response.status, content

    def test_guardrails(self):
        for headers in ({"Origin":"https://attacker.example"}, {"X-Title-Token":"bad"}, {"Host":"attacker.example"}):
            self.assertEqual(self.call('/suggest', '{}', headers)[0], 403)
        self.assertEqual(self.call('/suggest', 'x' * (m.MAX_BODY + 1))[0], 413)
        self.assertEqual(self.call('/suggest', '{}', {"Content-Type":"text/plain"})[0], 415)
        self.assertEqual(self.call('/suggest', 'not json')[0], 400)
        self.assertEqual(self.call('/../config.toml', None, method='GET')[0], 404)
        self.assertEqual(self.call('/suggest', '{}', method='PUT')[0], 501)

    def test_harness_and_preview_only_status(self):
        status, body = self.call('/', None, method='GET')
        self.assertEqual(status, 200)
        self.assertIn(b'harness.js', body)
        status, body = self.call('/status', '{}')
        self.assertEqual(json.loads(body), {"mode":"mock", "nativeIntegration":False})
        status, body = self.call('/suggest', json.dumps(request()))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['threadId'], 'thread-a')


if __name__ == '__main__':
    unittest.main(verbosity=2)
