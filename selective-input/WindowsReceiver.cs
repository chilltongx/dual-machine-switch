using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

// An SSH tunnel carries authenticated events to a loopback-only socket.
// Only the desktop-session receiver injects input. No public port is exposed.
class SelectiveInput {
    [StructLayout(LayoutKind.Sequential)] struct MouseInput {public int X,Y;public uint Data,Flags,Time;public UIntPtr Extra;}
    [StructLayout(LayoutKind.Sequential)] struct KeyboardInput {public ushort Vk,Scan;public uint Flags,Time;public UIntPtr Extra;}
    [StructLayout(LayoutKind.Explicit)] struct Union {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Key;
    }
    [StructLayout(LayoutKind.Sequential)] struct Input {public uint Type;public Union Value;}
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
    static readonly Dictionary<int,Input> Held=new Dictionary<int,Input>();
    static readonly Dictionary<int,Input> Buttons=new Dictionary<int,Input>();
    static readonly string Root=AppDomain.CurrentDomain.BaseDirectory;
    static int repeatKey=-1;
    static long repeatAt;
    static readonly Stopwatch Clock=Stopwatch.StartNew();
    static long keyEvents,mouseEvents,lastStatus;
    static double mouseGain=1.0,mouseRemainderX,mouseRemainderY;
    static DateTime gainModified=DateTime.MinValue;

    static int ScaleAxis(int delta,double gain,ref double remainder) {
        double scaled=delta*gain+remainder;
        int whole=(int)scaled;
        remainder=scaled-whole;
        return whole;
    }
    static void ReloadMouseGain() {
        try {
            string path=Path.Combine(Root,"mouse-gain.txt");
            if(!File.Exists(path))return;
            DateTime modified=File.GetLastWriteTimeUtc(path);if(modified==gainModified)return;
            double gain;
            if(!double.TryParse(File.ReadAllText(path).Trim(),NumberStyles.Float,CultureInfo.InvariantCulture,out gain)||!(gain>=0.05&&gain<=4.0))return;
            gainModified=modified;mouseGain=gain;mouseRemainderX=mouseRemainderY=0;
            Log("forwarded mouse gain="+gain.ToString(CultureInfo.InvariantCulture));
        }catch(IOException){}
    }

    static void Log(string value) {File.AppendAllText(Path.Combine(Root,"receiver.log"),DateTimeOffset.Now.ToString("o")+" "+value+Environment.NewLine);}
    static void Send(Input value) {if(SendInput(1,new[]{value},Marshal.SizeOf(typeof(Input)))!=1) throw new Exception("SendInput rejected: "+Marshal.GetLastWin32Error());if(value.Type==1)keyEvents++;else mouseEvents++;}
    static void Status(bool connected) {try{File.WriteAllText(Path.Combine(Root,"selective-receiver-state.json"),"{\"connected\":"+(connected?"true":"false")+",\"keyEvents\":"+keyEvents+",\"mouseEvents\":"+mouseEvents+",\"mouseGain\":"+mouseGain.ToString(CultureInfo.InvariantCulture)+"}");}catch(IOException){}}
    static Input Scan(int code,bool down) {return new Input{Type=1,Value=new Union{Key=new KeyboardInput{Scan=(ushort)(code&255),Flags=(uint)(8|((code&0x100)!=0?1:0)|(down?0:2))}}};}
    static Input Virtual(int key,bool down) {return new Input{Type=1,Value=new Union{Key=new KeyboardInput{Vk=(ushort)key,Flags=(uint)(down?0:2)}}};}
    static int ScanForUsage(int u) {
        int[] letters={0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
        if(u>=4&&u<=29)return letters[u-4];
        if(u>=30&&u<=38)return u-28;
        if(u>=58&&u<=67)return u+1;
        if(u>=104&&u<=115)return -1;
        switch(u) {
            case 39:return 0x0b;case 40:return 0x1c;case 41:return 1;case 42:return 0x0e;case 43:return 0x0f;case 44:return 0x39;
            case 45:return 0x0c;case 46:return 0x0d;case 47:return 0x1a;case 48:return 0x1b;case 49:return 0x2b;case 50:return 0x2b;
            case 51:return 0x27;case 52:return 0x28;case 53:return 0x29;case 54:return 0x33;case 55:return 0x34;case 56:return 0x35;
            case 57:return 0x3a;case 68:return 0x57;case 69:return 0x58;case 71:return 0x46;
            case 73:return 0x152;case 74:return 0x147;case 75:return 0x149;case 76:return 0x153;case 77:return 0x14f;case 78:return 0x151;
            case 79:return 0x14d;case 80:return 0x14b;case 81:return 0x150;case 82:return 0x148;case 83:return 0x45;
            case 84:return 0x135;case 85:return 0x37;case 86:return 0x4a;case 87:return 0x4e;case 88:return 0x11c;
            case 89:return 0x4f;case 90:return 0x50;case 91:return 0x51;case 92:return 0x4b;case 93:return 0x4c;case 94:return 0x4d;
            case 95:return 0x47;case 96:return 0x48;case 97:return 0x49;case 98:return 0x52;case 99:return 0x53;case 100:return 0x56;case 101:return 0x15d;
            case 224:return 0x1d;case 225:return 0x2a;case 226:return 0x38;case 227:return 0x15b;
            case 228:return 0x11d;case 229:return 0x36;case 230:return 0x138;case 231:return 0x15c;
        }
        return -1;
    }
    static bool KeyInput(int page,int usage,bool down,out Input result) {
        result=new Input();
        if(page==7) {
            int scan=ScanForUsage(usage);
            if(scan>=0){result=Scan(scan,down);return true;}
            if(usage==70){result=Virtual(0x2c,down);return true;}
            if(usage==72){result=Virtual(0x13,down);return true;}
            if(usage>=104&&usage<=115){result=Virtual(0x7c+usage-104,down);return true;}
        }
        if(page==12) {
            int vk=0;
            switch(usage){case 0xe9:vk=0xaf;break;case 0xea:vk=0xae;break;case 0xe2:vk=0xad;break;case 0xcd:vk=0xb3;break;case 0xb5:vk=0xb0;break;case 0xb6:vk=0xb1;break;case 0xb7:vk=0xb2;break;}
            if(vk!=0){result=Virtual(vk,down);return true;}
        }
        return false;
    }
    static void ReleaseAll() {
        foreach(Input value in Held.Values){Input up=value;up.Value.Key.Flags|=2;try{Send(up);}catch{}}
        foreach(Input value in Buttons.Values){try{Send(value);}catch{}}
        Held.Clear();Buttons.Clear();repeatKey=-1;mouseRemainderX=mouseRemainderY=0;
    }
    static void ProcessLine(string line) {
        if(line.Length>128)throw new Exception("Invalid frame length");
        string[] p=line.Split(' ');
        if(p[0]=="h"&&p.Length==1)return;
        if(p[0]=="r"&&p.Length==1){ReleaseAll();return;}
        if(p[0]=="k"&&p.Length==4) {
            int page=int.Parse(p[1]),usage=int.Parse(p[2]),state=int.Parse(p[3]);
            if((page!=7&&page!=12)||usage<0||usage>65535||(state!=0&&state!=1))throw new Exception("Invalid key frame");
            int id=page*65536+usage;Input input;
            if(!KeyInput(page,usage,state==1,out input))return;
            if(state==1) {
                if(Held.ContainsKey(id))return;
                Send(input);Held[id]=input;
                if(page==7&&usage<224&&usage!=57&&usage!=70&&usage!=71&&usage!=72&&usage!=83){repeatKey=id;repeatAt=Clock.ElapsedMilliseconds+500;}
            } else {
                if(!Held.ContainsKey(id))return;
                Send(input);Held.Remove(id);if(repeatKey==id)repeatKey=-1;
            }
            return;
        }
        if(p[0]=="m"&&p.Length==3) {
            int x=int.Parse(p[1]),y=int.Parse(p[2]);
            if(Math.Abs((long)x)>10000||Math.Abs((long)y)>10000)throw new Exception("Invalid motion frame");
            x=ScaleAxis(x,mouseGain,ref mouseRemainderX);y=ScaleAxis(y,mouseGain,ref mouseRemainderY);
            if(x==0&&y==0)return;
            Send(new Input{Type=0,Value=new Union{Mouse=new MouseInput{X=x,Y=y,Flags=1}}});return;
        }
        if(p[0]=="b"&&p.Length==3) {
            int button=int.Parse(p[1]),state=int.Parse(p[2]);
            if(button<1||button>5||(state!=0&&state!=1))throw new Exception("Invalid button frame");
            uint[] downs={0,2,8,32,128,128},ups={0,4,16,64,256,256};
            Input up=new Input{Type=0,Value=new Union{Mouse=new MouseInput{Flags=ups[button],Data=(uint)(button>=4?button-3:0)}}};
            Input input=up;input.Value.Mouse.Flags=state==1?downs[button]:ups[button];
            if(state==1){if(Buttons.ContainsKey(button))return;Send(input);Buttons[button]=up;}
            else if(Buttons.ContainsKey(button)){Send(input);Buttons.Remove(button);}
            return;
        }
        if(p[0]=="s"&&p.Length==3) {
            int x=int.Parse(p[1]),y=int.Parse(p[2]);
            if(Math.Abs((long)x)>100||Math.Abs((long)y)>100)throw new Exception("Invalid scroll frame");
            if(y!=0)Send(new Input{Type=0,Value=new Union{Mouse=new MouseInput{Flags=0x800,Data=unchecked((uint)(y*120))}}});
            if(x!=0)Send(new Input{Type=0,Value=new Union{Mouse=new MouseInput{Flags=0x1000,Data=unchecked((uint)(x*120))}}});
            return;
        }
        throw new Exception("Unknown frame");
    }
    static int Server() {
        if(Process.GetCurrentProcess().SessionId==0)throw new Exception("Receiver must run in interactive desktop session");
        string secret=File.ReadAllText(Path.Combine(Root,"selective-token.txt")).Trim();
        if(secret.Length!=64)throw new Exception("Missing connection secret");
        var listener=new TcpListener(IPAddress.Loopback,24811);listener.Start(1);
        ReloadMouseGain();
        Log("loopback receiver started in session "+Process.GetCurrentProcess().SessionId);
        while(true) {
            try {
                using(var client=listener.AcceptTcpClient()) {
                    client.NoDelay=true;
                    var stream=client.GetStream();var reader=new StreamReader(stream);var writer=new StreamWriter(stream){AutoFlush=true};
                    Task<string> hello=reader.ReadLineAsync();
                    if(!hello.Wait(3000))continue;
                    string wanted="HELLO "+secret,actual=hello.Result??"";
                    int difference=actual.Length^wanted.Length;
                    if(actual.Length==wanted.Length)for(int i=0;i<wanted.Length;i++)difference|=actual[i]^wanted[i];
                    if(difference!=0)continue;
                    writer.WriteLine("READY");Log("session connected");
                    Status(true);
                    long last=Clock.ElapsedMilliseconds;Task<string> pending=reader.ReadLineAsync();
                    while(true) {
                        if(pending.Wait(10)) {
                            string line=pending.Result;if(line==null||line=="q")break;
                            ProcessLine(line);last=Clock.ElapsedMilliseconds;pending=reader.ReadLineAsync();
                        }
                        if(Clock.ElapsedMilliseconds-last>3000)throw new Exception("Heartbeat timeout");
                        if(Clock.ElapsedMilliseconds-lastStatus>500){ReloadMouseGain();Status(true);lastStatus=Clock.ElapsedMilliseconds;}
                        if(repeatKey>=0&&Held.ContainsKey(repeatKey)&&Clock.ElapsedMilliseconds>=repeatAt){Send(Held[repeatKey]);repeatAt=Clock.ElapsedMilliseconds+35;}
                    }
                }
            } catch(Exception e){Log("session ended: "+e.GetType().Name+" "+e.Message);}
            finally {ReleaseAll();Status(false);Log("session released all input");}
        }
    }
    static int Main(string[] args) {
        try {
            if(args.Length==1&&args[0]=="--self-test") {
                if(ScanForUsage(4)!=0x1e||ScanForUsage(79)!=0x14d||ScanForUsage(228)!=0x11d||Marshal.SizeOf(typeof(Input))!=(IntPtr.Size==8?40:28))return 3;
                double remainder=0;int total=0;
                for(int i=0;i<100;i++)total+=ScaleAxis(1,0.5,ref remainder);
                if(total!=50||remainder!=0)return 4;
                total=0;for(int i=0;i<100;i++)total+=ScaleAxis(-1,0.5,ref remainder);
                if(total!=-50||remainder!=0)return 5;
                if(ScaleAxis(1,0.5,ref remainder)!=0||ScaleAxis(-1,0.5,ref remainder)!=0||remainder!=0)return 6;
                Console.WriteLine("mapping, SendInput layout, and 50% fractional mouse movement checks passed");return 0;
            }
            return Server();
        } catch(Exception e) {try{Log("startup failed: "+e.GetType().Name);}catch{}return 1;}
    }
}
