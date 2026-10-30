"""Bounded Windows sampler: counters/process metadata only; no command lines or chat data."""
import argparse, ctypes as c, json, os, time
from ctypes import wintypes as w
from pathlib import Path

class FileTime(c.Structure): _fields_=[('low',w.DWORD),('high',w.DWORD)]
def ticks(t): return (t.high<<32)|t.low
class Memory(c.Structure):
    _fields_=[('length',w.DWORD),('load',w.DWORD)]+[(n,c.c_ulonglong) for n in ('total','available','totalPage','availablePage','totalVirtual','availableVirtual','extended')]
class ProcessEntry(c.Structure):
    _fields_=[('size',w.DWORD),('usage',w.DWORD),('pid',w.DWORD),('heap',c.c_size_t),('module',w.DWORD),('threads',w.DWORD),('parent',w.DWORD),('priority',w.LONG),('flags',w.DWORD),('name',w.WCHAR*260)]
class ProcessMemory(c.Structure):
    _fields_=[('cb',w.DWORD),('faults',w.DWORD)]+[(n,c.c_size_t) for n in ('peakWorking','working','peakPaged','paged','peakNonpaged','nonpaged','pagefile','peakPagefile','private')]
class Io(c.Structure): _fields_=[(n,c.c_ulonglong) for n in ('readOps','writeOps','otherOps','readBytes','writeBytes','otherBytes')]
class CounterUnion(c.Union): _fields_=[('number',c.c_double),('large',c.c_longlong)]
class CounterValue(c.Structure): _fields_=[('status',w.DWORD),('value',CounterUnion)]
class CounterItem(c.Structure): _fields_=[('name',w.LPWSTR),('value',CounterValue)]
k=c.WinDLL('kernel32',use_last_error=True); ps=c.WinDLL('psapi',use_last_error=True); pdh=c.WinDLL('pdh',use_last_error=True)
k.CreateToolhelp32Snapshot.argtypes=[w.DWORD,w.DWORD];k.CreateToolhelp32Snapshot.restype=w.HANDLE
k.Process32FirstW.argtypes=[w.HANDLE,c.POINTER(ProcessEntry)];k.Process32NextW.argtypes=[w.HANDLE,c.POINTER(ProcessEntry)]
k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD];k.OpenProcess.restype=w.HANDLE;k.CloseHandle.argtypes=[w.HANDLE]
k.GetProcessTimes.argtypes=[w.HANDLE]+[c.POINTER(FileTime)]*4
k.GetProcessIoCounters.argtypes=[w.HANDLE,c.POINTER(Io)]
ps.GetProcessMemoryInfo.argtypes=[w.HANDLE,c.POINTER(ProcessMemory),w.DWORD]
k.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]
pdh.PdhOpenQueryW.argtypes=[w.LPCWSTR,c.c_size_t,c.POINTER(w.HANDLE)]
pdh.PdhAddEnglishCounterW.argtypes=[w.HANDLE,w.LPCWSTR,c.c_size_t,c.POINTER(w.HANDLE)]
pdh.PdhCollectQueryData.argtypes=[w.HANDLE];pdh.PdhCloseQuery.argtypes=[w.HANDLE]
pdh.PdhGetFormattedCounterValue.argtypes=[w.HANDLE,w.DWORD,c.POINTER(w.DWORD),c.POINTER(CounterValue)]
pdh.PdhGetFormattedCounterArrayW.argtypes=[w.HANDLE,w.DWORD,c.POINTER(w.DWORD),c.POINTER(w.DWORD),c.c_void_p]

def processes(previous,elapsed,paths):
    result=[]; next_values={}; snapshot=k.CreateToolhelp32Snapshot(2,0)
    if snapshot==c.c_void_p(-1).value:return [],{}
    entry=ProcessEntry();entry.size=c.sizeof(entry)
    try:
        valid=k.Process32FirstW(snapshot,c.byref(entry))
        while valid:
            handle=k.OpenProcess(0x1010,False,entry.pid) or k.OpenProcess(0x1000,False,entry.pid)
            if handle:
                try:
                    created,exited,kernel,user=FileTime(),FileTime(),FileTime(),FileTime()
                    if k.GetProcessTimes(handle,c.byref(created),c.byref(exited),c.byref(kernel),c.byref(user)):
                        key=(entry.pid,ticks(created));cpu=(ticks(kernel)+ticks(user))/1e7; memory=ProcessMemory();memory.cb=c.sizeof(memory);ps.GetProcessMemoryInfo(handle,c.byref(memory),memory.cb)
                        io=Io();k.GetProcessIoCounters(handle,c.byref(io));read,write=io.readBytes,io.writeBytes;prior=previous.get(key)
                        if key not in paths:
                            size=w.DWORD(32768);buffer=c.create_unicode_buffer(size.value)
                            paths[key]=buffer.value if k.QueryFullProcessImageNameW(handle,0,buffer,c.byref(size)) else None
                        row={'pid':entry.pid,'parent':entry.parent,'name':entry.name,'path':paths[key],'threads':entry.threads,'privateMiB':round(memory.private/1048576,2),'workingMiB':round(memory.working/1048576,2),'cpuPercent':round(max(0,cpu-prior[0])/elapsed/(os.cpu_count() or 1)*100,2) if prior else None,'readMiBps':round(max(0,read-prior[1])/elapsed/1048576,3) if prior else None,'writeMiBps':round(max(0,write-prior[2])/elapsed/1048576,3) if prior else None}
                        result.append(row);next_values[key]=(cpu,read,write)
                finally:k.CloseHandle(handle)
            valid=k.Process32NextW(snapshot,c.byref(entry))
    finally:k.CloseHandle(snapshot)
    return result,next_values

def system_cpu():
    idle,kernel,user=FileTime(),FileTime(),FileTime();k.GetSystemTimes(c.byref(idle),c.byref(kernel),c.byref(user));return ticks(idle),ticks(kernel)+ticks(user)
def counter_value(handle):
    value=CounterValue()
    if handle and pdh.PdhGetFormattedCounterValue(handle,0x200,None,c.byref(value))==0 and value.status in (0,1):return round(value.value.number,3)
    return None
def gpu_values(handle):
    if not handle:return []
    size,count=w.DWORD(),w.DWORD();pdh.PdhGetFormattedCounterArrayW(handle,0x200,c.byref(size),c.byref(count),None)
    if not size.value or size.value>4*1024*1024:return []
    buffer=c.create_string_buffer(size.value)
    if pdh.PdhGetFormattedCounterArrayW(handle,0x200,c.byref(size),c.byref(count),buffer)!=0:return []
    array=c.cast(buffer,c.POINTER(CounterItem));result=[]
    for n in range(count.value):
        item=array[n]
        if item.value.status in (0,1) and item.value.value.number>=0.5:result.append({'engine':item.name,'percent':round(item.value.value.number,2)})
    return sorted(result,key=lambda x:x['percent'],reverse=True)[:12]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--directory',required=True);parser.add_argument('--seconds',type=int,default=1200);parser.add_argument('--interval',type=float,default=3);args=parser.parse_args()
    root=Path(args.directory);root.mkdir(parents=True,exist_ok=True);stop=root/'stop.request';log=root/'samples.jsonl'
    (root/'sampler.json').write_text(json.dumps({'pid':os.getpid(),'startedUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'seconds':args.seconds,'interval':args.interval,'logicalProcessors':os.cpu_count(),'commandLinesRecorded':False}),encoding='utf8')
    query=w.HANDLE();pdh.PdhOpenQueryW(None,0,c.byref(query));counters={}
    for name,path in {'diskQueue':r'\PhysicalDisk(_Total)\Avg. Disk Queue Length','diskBytesPerSecond':r'\PhysicalDisk(_Total)\Disk Bytes/sec','diskSecondsPerTransfer':r'\PhysicalDisk(_Total)\Avg. Disk sec/Transfer','pagesInputPerSecond':r'\Memory\Pages Input/sec','gpu':r'\GPU Engine(*)\Utilization Percentage'}.items():
        handle=w.HANDLE()
        if pdh.PdhAddEnglishCounterW(query,path,0,c.byref(handle))==0:counters[name]=handle
    previous={};paths={};last_cpu=system_cpu();start=last=time.monotonic();samples=0
    try:
        while time.monotonic()-start<args.seconds and not stop.exists():
            tick=time.monotonic();elapsed=max(.01,tick-last);cpu=system_cpu();denominator=cpu[1]-last_cpu[1];memory=Memory();memory.length=c.sizeof(memory);k.GlobalMemoryStatusEx(c.byref(memory))
            rows,previous=processes(previous,elapsed,paths);pdh.PdhCollectQueryData(query)
            important={'chatgpt.exe','codex.exe','codexdualcontroller.exe','node.exe','python.exe','pythonw.exe','powershell.exe','pwsh.exe','dotnet.exe','dwm.exe','msmpeng.exe'}
            top={r['pid'] for r in sorted(rows,key=lambda r:r['cpuPercent'] or 0,reverse=True)[:10]}|{r['pid'] for r in sorted(rows,key=lambda r:r['privateMiB'],reverse=True)[:10]}
            selected=[r for r in rows if r['pid'] in top or r['name'].lower() in important]
            value={'utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'elapsed':round(tick-start,3),'cpuPercent':round((1-(cpu[0]-last_cpu[0])/denominator)*100,2) if denominator else None,'availableMiB':round(memory.available/1048576,1),'physicalUsedPercent':memory.load,'commitUsedMiB':round((memory.totalPage-memory.availablePage)/1048576,1),'commitLimitMiB':round(memory.totalPage/1048576,1),'disk':{n:counter_value(h) for n,h in counters.items() if n!='gpu'},'gpuBusyEngines':gpu_values(counters.get('gpu')),'processes':selected,'sampleCostMs':round((time.monotonic()-tick)*1000,2)}
            with log.open('a',encoding='utf8') as file:file.write(json.dumps(value,ensure_ascii=False)+'\n')
            samples+=1;last=tick;last_cpu=cpu
            time.sleep(max(.1,args.interval-(time.monotonic()-tick)))
    finally:
        pdh.PdhCloseQuery(query)
        (root/'finished.json').write_text(json.dumps({'samples':samples,'seconds':round(time.monotonic()-start,2),'stoppedByRequest':stop.exists()}),encoding='utf8')
if __name__=='__main__':main()
