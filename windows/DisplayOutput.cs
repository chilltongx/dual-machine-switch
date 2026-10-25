using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Threading;

// Temporary output control fallback. Does not update the Windows registry.
class DisplayOutput {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Device {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Key;
    }
    class Snapshot { public string Device; public string AdapterKey; public string Mode; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string name, uint index, ref Device device, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettingsEx(string name, int mode, IntPtr data, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name, IntPtr mode, IntPtr window, uint flags, IntPtr param);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths, IntPtr pathArray, uint modes, IntPtr modeArray, uint flags);
    static string Root = AppDomain.CurrentDomain.BaseDirectory;
    static JavaScriptSerializer Json = new JavaScriptSerializer();
    static Device NewDevice() { var d = new Device(); d.Size = Marshal.SizeOf(typeof(Device)); return d; }
    static void Log(string value) { File.AppendAllText(Path.Combine(Root,"output.log"), DateTimeOffset.Now.ToString("o")+" "+value+Environment.NewLine); }
    static void Report(string action,Device device,bool attached) {
        File.WriteAllText(Path.Combine(Root,"display-output-state.json"),Json.Serialize(new {action=action,device=device.Name,attached=attached,time=DateTimeOffset.UtcNow.ToString("o")}));
    }
    static bool Attached(string name) {
        for(uint i=0;;i++) {
            Device device=NewDevice();
            if(!EnumDisplayDevices(null,i,ref device,0)) throw new Exception("Output missing from enumeration: "+name);
            if(device.Name==name) {Log("readback "+name+" flags="+device.Flags);return (device.Flags&1)!=0;}
        }
    }
    static int Main(string[] args) {
        IntPtr mode = Marshal.AllocHGlobal(220);
        try {
            string command = args.Length == 1 ? args[0] : "/inspect";
            if(command!="/inspect" && command!="/detach" && command!="/restore") throw new Exception("Unknown command");
            var config=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(Root,"config.json")));
            string hardwareId=config.ContainsKey("monitorHardwareId") ? Convert.ToString(config["monitorHardwareId"]) : "";
            if(String.IsNullOrWhiteSpace(hardwareId))throw new Exception("Configure monitorHardwareId in config.json");
            var adapters = new List<Device>();
            var targets = new List<Device>();
            int active = 0;
            for(uint index=0;;index++) {
                Device adapter = NewDevice();
                if(!EnumDisplayDevices(null,index,ref adapter,0)) break;
                adapters.Add(adapter);
                if((adapter.Flags & 1)!=0) active++;
                for(uint sub=0;;sub++) {
                    Device panel=NewDevice();
                    if(!EnumDisplayDevices(adapter.Name,sub,ref panel,0)) break;
                    if((panel.Id??"").IndexOf("MONITOR\\"+hardwareId+"\\",StringComparison.OrdinalIgnoreCase)>=0) {
                        targets.Add(adapter); break;
                    }
                }
            }
            string backup=Path.Combine(Root,"display-output-backup.json");
            var activeTargets=targets.FindAll(d=>(d.Flags&1)!=0);
            if(activeTargets.Count==1) targets=activeTargets;
            else if(activeTargets.Count==0 && targets.Count>1 && File.Exists(backup)) {
                Snapshot saved=Json.Deserialize<Snapshot>(File.ReadAllText(backup));
                targets=targets.FindAll(d=>d.Name==saved.Device && d.Key==saved.AdapterKey);
            }
            if(command=="/restore") {
                Snapshot saved=Json.Deserialize<Snapshot>(File.ReadAllText(backup));
                Device adapter=adapters.Find(d=>d.Name==saved.Device && d.Key==saved.AdapterKey);
                if(adapter.Name==null) throw new Exception("Original adapter changed; refusing to restore a different output");
                if((adapter.Flags&1)!=0) {Log("already attached; mode unchanged");Report(command,adapter,true);return 0;}
                byte[] bytes=Convert.FromBase64String(saved.Mode);
                if(bytes.Length!=220) throw new Exception("Invalid display backup");
                Marshal.Copy(bytes,0,mode,220);
                int result=ChangeDisplaySettingsEx(adapter.Name,mode,IntPtr.Zero,0,IntPtr.Zero);
                Log("restore "+adapter.Name+" result="+result);
                if(result!=0) {
                    // Our detach never changes the registry: restore the saved Windows topology.
                    int database=SetDisplayConfig(0,IntPtr.Zero,0,IntPtr.Zero,0x8f);
                    Log("restore saved topology result="+database);
                    if(database!=0) throw new Exception("Restore failed: "+result+"; topology restore: "+database);
                }
                Thread.Sleep(1000);
                if(!Attached(adapter.Name)) throw new Exception("Restore returned success but output is still detached");
                Report(command,adapter,true);
                return 0;
            }
            if(targets.Count==0 && File.Exists(backup)) {
                Snapshot saved=Json.Deserialize<Snapshot>(File.ReadAllText(backup));
                Device old=adapters.Find(d=>d.Name==saved.Device && d.Key==saved.AdapterKey);
                if(old.Name!=null && (old.Flags&1)==0) {Log("already detached; backup unchanged");Report(command,old,false);return 0;}
            }
            if(targets.Count!=1) throw new Exception("Expected exactly one configured monitor output; got "+targets.Count);
            Device target=targets[0];
            if((target.Flags&1)==0) {Log("already detached; backup unchanged");Report(command,target,false);return 0;}
            var zeros=new byte[220]; Marshal.Copy(zeros,0,mode,220); Marshal.WriteInt16(mode,68,220);
            if(!EnumDisplaySettingsEx(target.Name,-1,mode,0)) throw new Exception("Cannot read current output mode");
            int width=Marshal.ReadInt32(mode,172),height=Marshal.ReadInt32(mode,176);
            Log("target="+target.Name+" flags="+target.Flags+" activeOutputs="+active+" mode="+width+"x"+height);
            if(command=="/inspect") {Report(command,target,true);return 0;}
            if(width==0 || height==0) { Log("zero-sized output; backup unchanged");Report(command,target,false);return 0; }
            if((target.Flags & 4)!=0 || active<2) throw new Exception("Refusing to detach the primary or only active output");
            var original=new byte[220];Marshal.Copy(mode,original,0,220);
            File.WriteAllText(backup,Json.Serialize(new Snapshot {Device=target.Name,AdapterKey=target.Key,Mode=Convert.ToBase64String(original)}));
            Marshal.WriteInt32(mode,72,0x180020); // DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT
            Marshal.WriteInt32(mode,172,0); Marshal.WriteInt32(mode,176,0);
            int changed=ChangeDisplaySettingsEx(target.Name,mode,IntPtr.Zero,0,IntPtr.Zero);
            Log("detach "+target.Name+" result="+changed);
            if(changed!=0) throw new Exception("Detach failed: "+changed);
            Thread.Sleep(1000);
            if(Attached(target.Name)) throw new Exception("Detach returned success but output is still attached");
            Report(command,target,false);
            return 0;
        } catch(Exception e) {Log("ERROR "+e); return 1;}
        finally {Marshal.FreeHGlobal(mode);}
    }
}
