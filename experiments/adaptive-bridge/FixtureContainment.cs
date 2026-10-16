using System;
using System.Runtime.InteropServices;
// The fixture owns this handle until process exit. Windows then closes it and
// terminates only this fixture's descendants, including on a runner timeout.
static class FixtureContainment {
 static IntPtr job;
 [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcess,PerJob; public uint Flags; public UIntPtr Min,Max; public uint Active; public UIntPtr Affinity; public uint Priority,Scheduling; }
 [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes; }
 [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic; public Io Io; public UIntPtr ProcessMemory,JobMemory,PeakProcess,PeakJob; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr handle,int type,ref Extended value,uint length);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr handle,IntPtr process);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 public static void Initialize() {
  job=CreateJobObject(IntPtr.Zero,null);
  var limits=new Extended(); limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE
  if(job==IntPtr.Zero || !SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(Extended))) || !AssignProcessToJobObject(job,GetCurrentProcess()))
   throw new InvalidOperationException("fixture-process-containment-unavailable");
 }
}
