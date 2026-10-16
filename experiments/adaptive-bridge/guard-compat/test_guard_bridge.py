import importlib.util, json, sys, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, r"E:\Codex-API\FirstTokenGuard\scripts")
spec = importlib.util.spec_from_file_location("guard_candidate", HERE / "desktop_service.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class GuardBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.probe = self.root / "Guard-BridgeRuntime.ps1"
        self.probe.write_bytes((HERE / self.probe.name).read_bytes())
        self.binding = self.root / "guard-runtime-binding.json"
        self.binding.write_text(json.dumps(dict(schema=1, integrationPath=r"E:\Codex-API\AdaptiveBridge\fixture\integration.json", integrationHash="A"*64, launchHelperHash="B"*64)))
        self.exe = self.root / "codex.exe"; self.exe.write_text("fixture")
        self.s = module.DesktopService.__new__(module.DesktopService)
        self.s.home = self.root / "home"; self.s.profile = self.root / "profile"
        self.s.clock = lambda: 1000
        self.s.api_process = lambda now=None: (True, "10")
        self.s.reader_process = "10"; self.s._cli_probe = (0, None)
        self.row = dict(ProcessId=30, ParentProcessId=20, DesktopProcessId=10, BridgeProcessId=20,
                        ExecutablePath=str(self.exe), Started=100, VerifiedBridge=True)
        self.file_patch = patch.object(module, "__file__", str(self.root / "desktop_service.py"))
        self.file_patch.start()
    def tearDown(self): self.file_patch.stop(); self.temp.cleanup()
    def result(self, **changes):
        payload = dict(schema=1, apiHome=str(self.s.home), profile=str(self.s.profile), rows=[dict(self.row)])
        payload.update(changes)
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload))
    def test_validated_chain_cli(self):
        with patch.object(module.subprocess, "run", return_value=self.result()) as run:
            self.assertEqual(self.s._verified_bridge_backends("10"), [self.row])
            self.assertIn("-File", run.call_args.args[0]); self.assertNotIn("-Command", run.call_args.args[0])
    def test_discover_cli_fallback(self):
        with patch.object(module.subprocess, "run", side_effect=[SimpleNamespace(returncode=0, stdout="[]"), self.result()]):
            self.assertEqual(self.s.discover_cli(True), self.exe.resolve())
    def test_backend_replay_uses_same_verified_chain(self):
        with patch.object(module.subprocess, "run", side_effect=[SimpleNamespace(returncode=0, stdout="[]"), self.result()]):
            self.assertEqual(self.s._backend_processes(), {"pid:30:": 100})
    def test_direct_path_behavior_preserved(self):
        direct=dict(ProcessId=30,ParentProcessId=10,ExecutablePath=str(self.exe))
        with patch.object(module.subprocess, "run", return_value=SimpleNamespace(returncode=0,stdout=json.dumps([direct]))) as run:
            self.assertEqual(self.s.discover_cli(True),self.exe.resolve());self.assertEqual(run.call_count,1)
    def test_probe_hash_tampering(self):
        self.probe.write_text("tamper")
        with patch.object(module.subprocess,"run") as run:
            self.assertEqual(self.s._verified_bridge_backends("10"),[]);run.assert_not_called()
    def test_missing_sidecar(self):
        self.binding.unlink()
        with patch.object(module.subprocess,"run") as run:
            self.assertEqual(self.s._verified_bridge_backends("10"),[]);run.assert_not_called()
    def test_invalid_sidecar_root(self):
        self.binding.write_text(json.dumps(dict(schema=1,integrationPath=r"C:\other\integration.json",integrationHash="A"*64,launchHelperHash="B"*64)))
        with patch.object(module.subprocess,"run") as run:
            self.assertEqual(self.s._verified_bridge_backends("10"),[]);run.assert_not_called()
    def test_cross_instance_and_invalid_reports(self):
        cases=[self.result(schema=99),self.result(apiHome=str(self.root/'other')),self.result(profile=str(self.root/'other')),self.result(rows=[]),self.result(rows=[self.row,self.row])]
        for field,value in [('VerifiedBridge',False),('DesktopProcessId',99),('BridgeProcessId',99),('Started',0),('ProcessId',True),('ParentProcessId',10),('ExecutablePath',str(self.root/'missing.exe'))]:
            bad=dict(self.row);bad[field]=value;cases.append(self.result(rows=[bad]))
        for result in cases:
            with self.subTest(result=result.stdout),patch.object(module.subprocess,"run",return_value=result):
                self.assertEqual(self.s._verified_bridge_backends("10"),[])
    def test_process_failure(self):
        with patch.object(module.subprocess,"run",return_value=SimpleNamespace(returncode=1,stdout="")):
            self.assertEqual(self.s._verified_bridge_backends("10"),[])

if __name__ == '__main__': unittest.main(verbosity=2)
