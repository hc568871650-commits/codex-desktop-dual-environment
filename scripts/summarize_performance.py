"""Summarize this task's bounded sampler output without reading app data."""
import argparse, json, re, statistics
from collections import defaultdict
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--directory',required=True);args=parser.parse_args()
root=Path(args.directory);cpu=[];memory=[];cost=[];queue=[];latency=[];paging=[];gpu=[];processes={};first=last=None
with (root/'samples.jsonl').open(encoding='utf8') as source:
    for line in source:
        try: row=json.loads(line)
        except json.JSONDecodeError: continue
        first=first or row['utc'];last=row['utc']
        if row.get('cpuPercent') is not None:cpu.append(row['cpuPercent'])
        memory.append(row['availableMiB']);cost.append(row['sampleCostMs'])
        for key,target in [('diskQueue',queue),('diskSecondsPerTransfer',latency),('pagesInputPerSecond',paging)]:
            if row['disk'].get(key) is not None:target.append(row['disk'][key])
        gpu.extend(row.get('gpuBusyEngines',[]))
        for item in row['processes']:
            key=(item['pid'],item['name']);p=processes.setdefault(key,{'pid':item['pid'],'name':item['name'],'path':item['path'],'privateMiBMax':0,'cpu':[],'samples':0})
            p['privateMiBMax']=max(p['privateMiBMax'],item['privateMiB']);p['samples']+=1
            if item['cpuPercent'] is not None:p['cpu'].append(item['cpuPercent'])
def stats(values):
    return {'average':round(statistics.mean(values),3),'maximum':max(values),'p95':sorted(values)[min(len(values)-1,int(len(values)*.95))]} if values else None
for item in processes.values():item['cpuPercent']=stats(item.pop('cpu'))
summary={'fromUtc':first,'toUtc':last,'samples':len(memory),'cpuPercent':stats(cpu),'availableMiBMinimum':min(memory) if memory else None,'sampleCostMs':stats(cost),'diskQueue':stats(queue),'diskLatencyMs':stats([v*1000 for v in latency]),'pagesInputPerSecond':stats(paging),'gpuHighestObservedEngines':sorted(gpu,key=lambda e:e['percent'],reverse=True)[:5],'controllersAndWorkers':[p for p in processes.values() if p['name'].lower() in ('codexdualcontroller.exe','powershell.exe','pythonw.exe')],'topCpuProcesses':sorted(processes.values(),key=lambda p:(p['cpuPercent'] or {}).get('maximum',0),reverse=True)[:10],'limits':['Only covers recorded intervals after reboot; cannot establish the cause of the earlier freeze.','CPU percentages are normalized by logical processor count.','Private memory is process committed memory, not total physical RAM consumption.','GPU output includes only busy counters at sampled instants; absence is not proof of zero GPU load.']}
(root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:summary[k] for k in ('fromUtc','toUtc','samples','cpuPercent','availableMiBMinimum','sampleCostMs','diskQueue','diskLatencyMs')},ensure_ascii=False,indent=2))
