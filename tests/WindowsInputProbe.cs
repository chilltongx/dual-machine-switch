using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using System.Linq;
class WindowsInputProbe {
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [STAThread] static void Main() {
        var started=DateTimeOffset.UtcNow;
        bool shift=false,moved=false;
        Point start;GetCursorPos(out start);
        for(int i=0;i<800;i++) {
            if((GetAsyncKeyState(0xA0)&0x8000)!=0) shift=true;
            Point now;GetCursorPos(out now);
            if(now.X!=start.X || now.Y!=start.Y) moved=true;
            Thread.Sleep(10);
        }
        var result=new {started=started.ToString("o"),shiftObserved=shift,cursorMoved=moved,displays=Screen.AllScreens.Select(s=>new {name=s.DeviceName,primary=s.Primary,x=s.Bounds.X,y=s.Bounds.Y,width=s.Bounds.Width,height=s.Bounds.Height}).ToArray()};
        File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"input-probe.json"),new JavaScriptSerializer().Serialize(result));
    }
}
