using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace CodexDual {
    // Explicit Unicode Shell API; WScript.Shell can reject paths outside the system code page.
    // https://learn.microsoft.com/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishelllinkw
    public static class UnicodeShortcut {
        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int capacity, IntPtr findData, uint flags);
            void GetIDList(out IntPtr value);
            void SetIDList(IntPtr value);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetHotkey(out ushort value);
            void SetHotkey(ushort value);
            void GetShowCmd(out int value);
            void SetShowCmd(int value);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity, out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string value, int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved);
            void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
        }
        private static object NewLink() { return Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"), true)); }
        public static void Create(string path, string target, string arguments, string directory, string icon) {
            if (File.Exists(path)) throw new IOException("Shortcut already exists; preserved.");
            object value = NewLink();
            try {
                var link = (IShellLinkW)value;
                link.SetPath(target); link.SetArguments(arguments); link.SetWorkingDirectory(directory);
                link.SetIconLocation(icon, 0); link.SetShowCmd(1);
                ((IPersistFile)value).Save(path, true);
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        public static string[] Read(string path) {
            object value = NewLink();
            try {
                ((IPersistFile)value).Load(path, 0);
                var link = (IShellLinkW)value;
                var target = new StringBuilder(32768); var args = new StringBuilder(32768); var directory = new StringBuilder(32768);
                link.GetPath(target, target.Capacity, IntPtr.Zero, 4);
                link.GetArguments(args, args.Capacity); link.GetWorkingDirectory(directory, directory.Capacity);
                return new[] { target.ToString(), args.ToString(), directory.ToString() };
            } finally { Marshal.FinalReleaseComObject(value); }
        }
    }
}
