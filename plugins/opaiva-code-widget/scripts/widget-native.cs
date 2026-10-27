using System;
using System.Text;
using System.Runtime.InteropServices;
namespace ClaudeWidget {
    public static class WinFocus {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int index, int value);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        const int GWL_EXSTYLE = -20;
        const int WS_EX_NOACTIVATE = 0x08000000;
        // On: clicks still reach the buttons, but the window never steals focus
        public static void SetNoActivate(IntPtr h, bool on) {
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            SetWindowLong(h, GWL_EXSTYLE, on ? (ex | WS_EX_NOACTIVATE) : (ex & ~WS_EX_NOACTIVATE));
        }
        public static void DestroyIconHandle(IntPtr h) { DestroyIcon(h); }
        // To the top of the always-on-top windows, without moving, resizing or activating it
        public static void RaiseTopmost(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
        public static IntPtr Foreground() { return GetForegroundWindow(); }
        public static bool Activate(IntPtr h) { return SetForegroundWindow(h); }
        // A session's remembered window (VS Code or terminal), if it still exists
        public static bool FocusHandle(long handle) {
            var h = new IntPtr(handle);
            if (handle == 0 || !IsWindow(h)) return false;
            if (IsIconic(h)) ShowWindow(h, 9);
            return SetForegroundWindow(h);
        }
        public static string Title(IntPtr h) {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            return sb.ToString();
        }
        // Visible windows whose title contains app, topmost first
        public static IntPtr[] FindWindows(string app) {
            var found = new System.Collections.Generic.List<IntPtr>();
            EnumWindows((h, l) => {
                if (IsWindowVisible(h) && Title(h).IndexOf(app, StringComparison.OrdinalIgnoreCase) >= 0) found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }
    }
    public static class HotKeys {
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    }
}
