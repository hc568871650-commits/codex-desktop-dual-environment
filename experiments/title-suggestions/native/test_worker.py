import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = Path(__file__).resolve().parent
BOOT = r'''
import sys,threading,time
sys.path.insert(0,sys.argv[1]);import worker
class FakeService:
 def __init__(self,*a,**k): self.cancelled=set()
 def cancel(self,rid): self.cancelled.add(rid)
 def suggest(self,data):
  if data.get('refresh'):
   deadline=time.monotonic()+5
   while data['requestId'] not in self.cancelled and time.monotonic()<deadline:time.sleep(.01)
   if data['requestId'] in self.cancelled:raise worker.Failure('cancelled')
  return {'requestId':data['requestId'],'threadId':data['threadId'],'title':'测试标题','cached':False}
worker.NativeTitleService=FakeService
sys.argv=['worker','--binding',sys.argv[2]]
raise SystemExit(worker.main())
'''


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        config=Path(self.temp.name)/'binding.json'
        config.write_text(json.dumps({'cli':{'path':'unused','sha256':'fixture'},'home':'unused','profile':'unused','model':'fixture',
            'compatibility':{'passed':True,'toolCount':0,'environmentHeaderVerified':True,'cliSha256':'fixture'}}))
        self.proc=subprocess.Popen([sys.executable,'-I','-B','-X','utf8','-c',BOOT,str(HERE),str(config)],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.queue=queue.Queue()
        self.reader=threading.Thread(target=lambda:[self.queue.put(json.loads(x)) for x in self.proc.stdout],daemon=True)
        self.reader.start()
        self.assertEqual(self.queue.get(timeout=4),{'type':'ready'})
    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            try:self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait()
        self.proc.stdout.close();self.proc.stderr.close();self.temp.cleanup()
    def send(self,ident,rid,refresh=False):
        self.proc.stdin.write((json.dumps({'id':ident,'method':'/native/suggest','data':{'requestId':rid,'threadId':'fixture','refresh':refresh}})+'\n').encode());self.proc.stdin.flush()
    def test_multiple_requests_do_not_stop_worker(self):
        for n in range(3):
            self.send(str(n),str(n));result=self.queue.get(timeout=3)
            self.assertEqual(result['result']['requestId'],str(n))
    def test_eof_cancels_owned_work_and_exits(self):
        self.send('slow','slow',True)
        self.proc.stdin.close();self.proc.wait(timeout=2)
        self.assertEqual(self.proc.returncode,0)
    def test_cancel_is_processed_while_generation_is_running(self):
        self.send('slow','slow',True)
        self.proc.stdin.write(b'{"id":"cancel","method":"/native/cancel","data":{"requestId":"slow"}}\n');self.proc.stdin.flush()
        values=[self.queue.get(timeout=2),self.queue.get(timeout=2)]
        self.assertTrue(any(x.get('error')=='cancelled' for x in values))
        self.assertTrue(any(x.get('result',{}).get('cancelled') for x in values))

if __name__=='__main__':unittest.main()
