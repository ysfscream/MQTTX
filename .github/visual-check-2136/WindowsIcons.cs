using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Ask the Shell for icons, preserving the alpha channel in its HBITMAP.
public static class NativeVisual {
    [StructLayout(LayoutKind.Sequential)] public struct Size { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfo {
        public uint size; public int width, height; public ushort planes, bits;
        public uint compression, imageSize; public int xppm, yppm; public uint used, important;
    }
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory {
        [PreserveSig] int GetImage(Size size, uint flags, out IntPtr bitmap);
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItemImageFactory item);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, byte[] pixels, ref BitmapInfo info, uint usage);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint msg, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint="GetClassLongPtrW")] static extern IntPtr GetClassLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    public static void Init() { SetProcessDPIAware(); }

    public static string ShellIcon(string path, int size, string output) {
        Guid iid = typeof(IShellItemImageFactory).GUID;
        IShellItemImageFactory item;
        Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item));
        IntPtr bitmap = IntPtr.Zero, dc = GetDC(IntPtr.Zero);
        try {
            // SIIGBF_ICONONLY: no thumbnail or application-authored preview.
            Marshal.ThrowExceptionForHR(item.GetImage(new Size { cx=size, cy=size }, 4, out bitmap));
            BitmapInfo info = new BitmapInfo { size=40 };
            if (GetDIBits(dc, bitmap, 0, 0, null, ref info, 0) == 0) throw new Exception("GetDIBits header failed");
            int w=info.width, h=Math.Abs(info.height);
            info.height=-h; info.planes=1; info.bits=32; info.compression=0; info.imageSize=(uint)(w*h*4);
            byte[] pixels = new byte[w*h*4];
            if (GetDIBits(dc, bitmap, 0, (uint)h, pixels, ref info, 0) == 0) throw new Exception("GetDIBits pixels failed");
            // Some Shell providers return an opaque DIB without alpha.
            bool anyAlpha=false;
            for (int i=3;i<pixels.Length;i+=4) if (pixels[i]!=0) { anyAlpha=true; break; }
            if (!anyAlpha) for (int i=3;i<pixels.Length;i+=4) pixels[i]=255;
            using (Bitmap image = new Bitmap(w,h,PixelFormat.Format32bppArgb)) {
                BitmapData data=image.LockBits(new Rectangle(0,0,w,h),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
                try { for (int y=0;y<h;y++) Marshal.Copy(pixels,y*w*4,IntPtr.Add(data.Scan0,y*data.Stride),w*4); }
                finally { image.UnlockBits(data); }
                image.Save(output,ImageFormat.Png);
            }
            if (w!=size || h!=size) throw new Exception("Shell returned "+w+"x"+h+" for "+size);
            return w+"x"+h+"; IShellItemImageFactory ICONONLY";
        } finally {
            if (bitmap!=IntPtr.Zero) DeleteObject(bitmap);
            ReleaseDC(IntPtr.Zero,dc); Marshal.ReleaseComObject(item);
        }
    }
    public static string WindowIcon(IntPtr window, bool small, string output) {
        IntPtr icon;
        SendMessageTimeout(window,0x7f,new IntPtr(small ? 0 : 1),IntPtr.Zero,2,2000,out icon);
        string source="WM_GETICON";
        if (icon==IntPtr.Zero && small) SendMessageTimeout(window,0x7f,new IntPtr(2),IntPtr.Zero,2,2000,out icon);
        if (icon==IntPtr.Zero) { icon=GetClassLongPtr(window,small ? -34 : -14); source="GetClassLongPtr"; }
        if (icon==IntPtr.Zero) throw new Exception("No window icon handle");
        using (Bitmap image=Icon.FromHandle(icon).ToBitmap()) {
            image.Save(output,ImageFormat.Png); return source+"; "+image.Width+"x"+image.Height;
        }
    }
    public static string Capture(string output, IntPtr window) {
        Rectangle bounds=SystemInformation.VirtualScreen;
        if (window!=IntPtr.Zero) {
            Rect rect; if (!GetWindowRect(window,out rect)) throw new Exception("GetWindowRect failed");
            bounds=Rectangle.Intersect(bounds,Rectangle.FromLTRB(rect.left,rect.top,rect.right,rect.bottom));
        }
        using (Bitmap image=new Bitmap(bounds.Width,bounds.Height)) {
            using (Graphics graphics=Graphics.FromImage(image)) graphics.CopyFromScreen(bounds.Location,Point.Empty,bounds.Size);
            image.Save(output,ImageFormat.Png);
        }
        return bounds.ToString();
    }
}
