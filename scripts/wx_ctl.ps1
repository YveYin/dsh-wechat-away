# wx_ctl.ps1 - WeChat 4.x (Weixin) UIA control CLI for Node callers.
# Modes: list | title | probe | read | preflight | send | watch | focus | deselect | markunread
# Contract: result is written ONLY to -Out (UTF-8, no BOM). stdout stays silent.
#           exit 0 = ok, exit 1 = failure. Exceptions become {"ok":false,"error":"<raw>"}.
# UIA first: SelectionItemPattern.Select / InvokePattern.Invoke / ValuePattern.SetValue.
#           Because WeChat 4.x (Qt/MMUI) exposes Select()/Invoke() as no-op stubs, a verified
#           synthetic WM_MOUSEMOVE/LBUTTONDOWN/LBUTTONUP click is used as documented fallback C.
#           No SendKeys except behind -AllowPasteFallback (which writes the clipboard).
# Direction: -Mode read tags every message with dir(in/out/unknown) + cls + greenPx +
#            greenRatio + side, from a PrintWindow bitmap: our own bubble is green, right.
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('list','title','read','send','probe','preflight','watch','focus','deselect','markunread')]
  [string]$Mode,
  [string]$Session = '',
  [string]$Text    = '',
  [int]$Limit      = 10,
  [string]$Out      = '',
  [string]$KindCache = '',
  [string]$Outbox    = '',      # JSON: [{"session":"x","text":"y","sentAt":<epoch-ms|ISO>}]; default <Out dir>\wx_outbox.json
  [string]$ExpectSession = '',  # send guard: refuse unless the switched chat equals this title
  [switch]$AllowPasteFallback,
  [switch]$DryRun,
  [switch]$NoClickFallback,
  [switch]$Scroll,            # probe: walk the WHOLE session list with synthetic wheel messages
  [int]$ScrollDelta = -1170,
  [int]$MaxScrollPasses = 80,
  [int]$ScrollSettleMs = 250,
  [switch]$NoBadge,           # skip the window capture entirely (no unread detection)
  [switch]$AllowFoldToggle,
  [switch]$NoFold,   # let probe click the pinned-fold bar (changes the user's UI state)
  [string]$ShotPath = '',     # optional: keep the analysed window bitmap as a PNG
  [switch]$Idle,              # deselect + bring the window forward + scroll the list to the top
  # markunread: how the context menu is opened. 'mouse' (default) replays WM_RBUTTONDOWN/UP.
  # 'contextmenu' posts one WM_CONTEXTMENU with screen coordinates, but on WeChat 4.2 that was
  # observed to hide the main window and drop the whole UIA tree - experiments only.
  [ValidateSet('contextmenu','mouse')]
  [string]$MenuMethod = 'mouse'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:SW = [System.Diagnostics.Stopwatch]::StartNew()
function Get-Ms { try { return [int]$script:SW.ElapsedMilliseconds } catch { return -1 } }
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $env:TEMP 'wx_ctl_out.json' }
function Write-Result($obj, [int]$code) {
  try {
    $json = $obj | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  exit $code
}
$script:Root = $null
$script:RootHwnd = [IntPtr]::Zero
$script:RootPick = $null
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName System.Drawing | Out-Null
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class WxCtl32 {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder c, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT box);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  // Every top-level window owned by one of `pids`, encoded as
  // "hwnd\u0001pid\u0001title\u0001class\u0001width\u0001height\u0001visible". WeChat 4.x also opens a
  // standalone "X和Y的聊天记录" window of the same Qt class; it is a separate top-level
  // window with no session list, so it must never be bound as the main window.
  public static string[] EnumWeixinWindows(uint[] pids) {
    List<string> res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool match = false;
      for (int i = 0; i < pids.Length; i++) { if (pids[i] == pid) { match = true; break; } }
      if (!match) { return true; }
      StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
      StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
      RECT r; GetWindowRect(h, out r);
      res.Add(h.ToInt64().ToString() + "\u0001" + pid.ToString() + "\u0001" + t.ToString() + "\u0001" + c.ToString() + "\u0001" + (r.Right - r.Left).ToString() + "\u0001" + (r.Bottom - r.Top).ToString() + "\u0001" + (IsWindowVisible(h) ? "1" : "0"));
      return true;
    }, IntPtr.Zero);
    return res.ToArray();
  }
  // Qt stores the minimized geometry as (-32000,-32000): the window is "visible" per UIA but
  // every element's BoundingRectangle is then empty, so chat switching is dead until the
  // window is back inside the desktop. Nothing here activates the window.
  public static bool IsOffScreen(IntPtr h) {
    RECT r;
    if (!GetWindowRect(h, out r)) return true;
    if ((r.Right - r.Left) <= 0 || (r.Bottom - r.Top) <= 0) return true;
    return r.Left <= -1000 || r.Top <= -1000 || r.Left >= 10000 || r.Top >= 10000;
  }
  // Move back to x,y with a sane size (a minimized Qt window reports 440x452). SWP_NOZORDER
  // keeps the current z-order (so it cannot jump in front of the agent UI) and SWP_NOACTIVATE
  // keeps the keyboard focus where it is.
  public static bool MoveOnScreen(IntPtr h, int x, int y, int w, int ht) {
    RECT r;
    if (GetWindowRect(h, out r)) {
      int cw = r.Right - r.Left, ch = r.Bottom - r.Top;
      if (cw >= 600) w = cw;
      if (ch >= 500) ht = ch;
    }
    return SetWindowPos(h, IntPtr.Zero, x, y, w, ht, 0x0014);
  }
}
public class WxShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetWindowDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
  const uint PW_RENDERFULLCONTENT = 2;   // Win8.1+: renders an occluded window, no foreground needed
  const uint SRCCOPY = 0x00CC0020;
  // Grab the whole window as a 32bpp bitmap. PrintWindow first, BitBlt second.
  // PW_RENDERFULLCONTENT is what makes a background/covered window work: plain
  // PrintWindow(...,0) and BitBlt of the window DC both come back black here.
  public static Bitmap Grab(IntPtr hwnd, out string method) {
    method = "PrintWindow(PW_RENDERFULLCONTENT)";
    RECT wr;
    if (!GetWindowRect(hwnd, out wr)) throw new Exception("get-window-rect-failed");
    int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
    if (w <= 0 || h <= 0) throw new Exception("window-has-no-area: " + w + "x" + h);
    Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    bool ok = false;
    using (Graphics g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      try { ok = PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT); }
      finally { g.ReleaseHdc(hdc); }
    }
    if (ok && !IsBlank(bmp)) return bmp;
    // Fallback: copy from the window DC. Only correct while the window really is on screen.
    using (Graphics g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      IntPtr wdc = GetWindowDC(hwnd);
      try {
        bool ok2 = BitBlt(hdc, 0, 0, w, h, wdc, 0, 0, SRCCOPY);
        if (ok2) method = ok ? "BitBlt(PrintWindow-blank)" : "BitBlt(PrintWindow-failed)";
        else method = ok ? "PrintWindow-blank" : "printwindow-and-bitblt-failed";
      } finally {
        if (wdc != IntPtr.Zero) ReleaseDC(hwnd, wdc);
        g.ReleaseHdc(hdc);
      }
    }
    return bmp;
  }
  // PrintWindow can return true and still paint nothing; a uniform sample means blank.
  static bool IsBlank(Bitmap bmp) {
    if (bmp.Width < 16 || bmp.Height < 16) return false;
    int first = -1;
    for (int i = 1; i <= 15; i++)
      for (int j = 1; j <= 15; j++) {
        Color c = bmp.GetPixel(bmp.Width * i / 16, bmp.Height * j / 16);
        int k = (c.R << 16) | (c.G << 8) | c.B;
        if (first < 0) first = k;
        else if (k != first) return false;
      }
    return true;
  }
  // UIA rect (screen px) -> pixels inside Grab()'s bitmap. The bitmap starts at the window
  // rect, while ScreenToClient() is relative to the client area, so the client origin inside
  // the bitmap (= the frame border, 8 px left / 0 px top on this Qt window) is added back.
  public static int[] ScreenRectToBitmap(IntPtr hwnd, int sx, int sy, int sw, int sh) {
    RECT wr;
    if (!GetWindowRect(hwnd, out wr)) throw new Exception("get-window-rect-failed");
    POINT a = new POINT(); a.X = sx; a.Y = sy;
    POINT b = new POINT(); b.X = sx + sw; b.Y = sy + sh;
    ScreenToClient(hwnd, ref a);
    ScreenToClient(hwnd, ref b);
    int borderX = (sx - a.X) - wr.Left;
    int borderY = (sy - a.Y) - wr.Top;
    return new int[] { a.X + borderX, a.Y + borderY, b.X - a.X, b.Y - a.Y };
  }
  // Bubble green: nominal WeChat #95EC69 = (149,236,105) +/- 30, but this build/theme paints
  // #9DF29F = (157,242,159) (B=159 is outside the nominal window), so accept a green hue too.
  static bool IsGreen(int r, int g, int b) {
    if (r >= 119 && r <= 179 && g >= 206 && g <= 255 && b >= 75 && b <= 135) return true;
    return g >= 190 && (g - r) >= 30 && (g - b) >= 30 && r >= 90 && b >= 55;
  }
  // Green pixel count inside a bitmap rect (clamped) plus how filled the two 20% edge bands
  // are. Side comes from the bands, not from the green mass: a long own message wraps into a
  // bubble that spans most of the row, and then the mass sits left AND right equally, which
  // is why "right 40% holds >=half the green" mislabels it as inbound. What discriminates an
  // own bubble is the empty strip between the row's left edge and the bubble (left band ~0)
  // together with a filled right band; inbound is the mirror image.
  public static int CountGreen(Bitmap bmp, int x, int y, int w, int h, out int total, out int leftGreen, out int rightGreen, out int leftPixels, out int rightPixels) {
    total = 0;
    leftGreen = 0;
    rightGreen = 0;
    leftPixels = 0;
    rightPixels = 0;
    int bx = x, by = y, bw = w, bh = h;
    if (bx < 0) { bw += bx; bx = 0; }
    if (by < 0) { bh += by; by = 0; }
    if (bx + bw > bmp.Width)  bw = bmp.Width - bx;
    if (by + bh > bmp.Height) bh = bmp.Height - by;
    if (bw <= 0 || bh <= 0) return 0;
    int bandW = bw / 5;
    if (bandW < 1) bandW = 1;
    int rightStart = bw - bandW;
    leftPixels = bandW * bh;
    rightPixels = bandW * bh;
    BitmapData bd = null;
    try {
      int n = 0;
      int stride = bw * 4;
      byte[] buf = new byte[stride * bh];
      for (int rr = 0; rr < bh; rr++) {
        for (int cc = 0; cc < bw; cc++) {
          Color c = bmp.GetPixel(bx + cc, by + rr);
          int ii = rr * stride + cc * 4;
          buf[ii] = c.B; buf[ii + 1] = c.G; buf[ii + 2] = c.R; buf[ii + 3] = c.A;
        }
      }
      for (int row = 0; row < bh; row++) {
        int off = row * stride;
        for (int col = 0; col < bw; col++) {
          int i = off + col * 4;
          int b = buf[i], g = buf[i + 1], r = buf[i + 2];
          if (IsGreen(r, g, b)) { n++; if (col < bandW) leftGreen++; else if (col >= rightStart) rightGreen++; }
        }
      }
      total = bw * bh;
      return n;
    } finally { if (bd != null) { bmp.UnlockBits(bd); } }
  }
  // ---- unread badge (#FA5151 disc with a white digit punched into it) --------------
  // Two masks: "hard" catches the antialiased rim and the darkened digit outline, "fill" is
  // the flat badge colour. A badge is a <= 26 px disc, so the fill mask is also run through a
  // 4-connected component pass: an avatar that merely CONTAINS red (sunset photo, red packet,
  // group mosaic) forms a wide blob and is rejected, which the plain pixel count cannot do.
  // measured false positives on real rows: 母上 avatar 77/0, 大坝 avatar 102/38 with a 29x13 box.
  public static bool IsRedBadge(int r, int g, int b) {
    return r >= 200 && g <= 130 && b <= 130 && (r - g) >= 80 && (r - b) >= 80;
  }
  public static bool IsBadgeFill(int r, int g, int b) {
    return Math.Abs(r - 250) <= 32 && Math.Abs(g - 81) <= 48 && Math.Abs(b - 81) <= 48;
  }
  // Scans one row's strip of the ALREADY captured window bitmap (never re-captures per row).
  // int[14]: 0 hard px | 1 fill px | 2..5 fill bbox x,y,w,h (-1 none) | 6 best disc component
  // area | 7..10 its bbox | 11,12 its centroid | 13 strip pixel count
  public static int[] RedBadge(Bitmap bmp, int x, int y, int w, int h) {
    int[] res = new int[14];
    for (int q = 0; q < 14; q++) { res[q] = -1; }
    res[0] = 0; res[1] = 0; res[6] = 0; res[13] = 0;
    int bx = x, by = y, bw = w, bh = h;
    if (bx < 0) { bw += bx; bx = 0; }
    if (by < 0) { bh += by; by = 0; }
    if (bmp == null) { return res; }
    if (bx + bw > bmp.Width) { bw = bmp.Width - bx; }
    if (by + bh > bmp.Height) { bh = bmp.Height - by; }
    if (bw <= 0 || bh <= 0) { return res; }
    bool[] fill = new bool[bw * bh];
    int hard = 0, fills = 0;
    int minX = 9999, minY = 9999, maxX = -1, maxY = -1;
    int stride = 0;
    byte[] buf = null;
    BitmapData bd = null;
    try {
      stride = bw * 4;
      buf = new byte[stride * bh];
      for (int rr = 0; rr < bh; rr++) {
        for (int cc = 0; cc < bw; cc++) {
          Color c = bmp.GetPixel(bx + cc, by + rr);
          int ii = rr * stride + cc * 4;
          buf[ii] = c.B; buf[ii + 1] = c.G; buf[ii + 2] = c.R; buf[ii + 3] = c.A;
        }
      }
    } finally { if (bd != null) { bmp.UnlockBits(bd); } }
    for (int row = 0; row < bh; row++) {
      int off = row * stride;
      for (int col = 0; col < bw; col++) {
        int i = off + col * 4;
        int b = buf[i], g = buf[i + 1], r = buf[i + 2];
        if (IsRedBadge(r, g, b)) { hard++; }
        if (IsBadgeFill(r, g, b)) {
          fills++; fill[row * bw + col] = true;
          if (col < minX) { minX = col; } if (col > maxX) { maxX = col; }
          if (row < minY) { minY = row; } if (row > maxY) { maxY = row; }
        }
      }
    }
    res[0] = hard; res[1] = fills; res[13] = bw * bh;
    if (maxX >= 0) { res[2] = minX; res[3] = minY; res[4] = maxX - minX + 1; res[5] = maxY - minY + 1; }
    int bestArea = 0, bestX = -1, bestY = -1, bestW = 0, bestH = 0, bestCx = 0, bestCy = 0;
    bool[] seen = new bool[bw * bh];
    int[] stack = new int[bw * bh];
    for (int idx = 0; idx < bw * bh; idx++) {
      if (!fill[idx] || seen[idx]) { continue; }
      int sp = 0; stack[sp++] = idx; seen[idx] = true;
      int area = 0, cx0 = 9999, cy0 = 9999, cx1 = -1, cy1 = -1, sumX = 0, sumY = 0;
      while (sp > 0) {
        int cur = stack[--sp];
        int cy2 = cur / bw, cx2 = cur - cy2 * bw;
        area++; sumX += cx2; sumY += cy2;
        if (cx2 < cx0) { cx0 = cx2; } if (cx2 > cx1) { cx1 = cx2; }
        if (cy2 < cy0) { cy0 = cy2; } if (cy2 > cy1) { cy1 = cy2; }
        if (cx2 > 0 && fill[cur - 1] && !seen[cur - 1]) { seen[cur - 1] = true; stack[sp++] = cur - 1; }
        if (cx2 + 1 < bw && fill[cur + 1] && !seen[cur + 1]) { seen[cur + 1] = true; stack[sp++] = cur + 1; }
        if (cy2 > 0 && fill[cur - bw] && !seen[cur - bw]) { seen[cur - bw] = true; stack[sp++] = cur - bw; }
        if (cy2 + 1 < bh && fill[cur + bw] && !seen[cur + bw]) { seen[cur + bw] = true; stack[sp++] = cur + bw; }
      }
      int cwd = cx1 - cx0 + 1, chg = cy1 - cy0 + 1;
      if (cwd > 26 || chg > 26) { continue; }   // wide red mass = avatar artwork, not a badge
      if (area < 25) { continue; }              // a lone antialiased pixel is not a badge
      if (area > bestArea) {
        bestArea = area; bestX = cx0; bestY = cy0; bestW = cwd; bestH = chg;
        bestCx = sumX / area; bestCy = sumY / area;
      }
    }
    res[6] = bestArea; res[7] = bestX; res[8] = bestY; res[9] = bestW; res[10] = bestH;
    res[11] = bestCx; res[12] = bestCy;
    return res;
  }
  // A chat with "消息免打扰" keeps the red disc but loses the white digit inside it: a normal
  // unread badge is a #FA5151 disc with a white "1"/"9"/"99+" punched in, a muted one is a
  // flat disc. Counting white pixels around the bbox fails (the disc CORNERS are row-white),
  // so flood-fill the red disc and count the NON-red cells it encloses: the digit is a hole
  // in the disc, a muted dot has none. Measured on the live list 2026-11-11:
  //   numeric "1" badge (15x15) -> 10 bright hole px / 10 hole px / 1 strict-white
  //   five muted/service dots (8x8) -> 0 / 0 / 0
  // int[6]: 0 bright hole px (>=190) | 1 hole px | 2 strict white hole px (>=230)
  //       | 3 red px in window | 4 window px | 5 reserved
  public static int[] BadgeWhite(Bitmap bmp, int x, int y, int w, int h, int pad) {
    int[] res = new int[6];
    for (int q = 0; q < 6; q++) { res[q] = 0; }
    if (bmp == null || w <= 0 || h <= 0) { return res; }
    int x0 = x - pad, y0 = y - pad, x1 = x + w + pad, y1 = y + h + pad;
    if (x0 < 0) { x0 = 0; }
    if (y0 < 0) { y0 = 0; }
    if (x1 > bmp.Width) { x1 = bmp.Width; }
    if (y1 > bmp.Height) { y1 = bmp.Height; }
    if (x1 <= x0 || y1 <= y0) { return res; }
    int bw = x1 - x0, bh = y1 - y0;
    byte[] buf = null;
    int stride = 0;
    BitmapData bd = null;
    try {
      stride = bw * 4;
      buf = new byte[stride * bh];
      for (int rr = 0; rr < bh; rr++) {
        for (int cc = 0; cc < bw; cc++) {
          Color c = bmp.GetPixel(x0 + cc, y0 + rr);
          int ii = rr * stride + cc * 4;
          buf[ii] = c.B; buf[ii + 1] = c.G; buf[ii + 2] = c.R; buf[ii + 3] = c.A;
        }
      }
    } finally { if (bd != null) { bmp.UnlockBits(bd); } }
    bool[] red = new bool[bw * bh];
    for (int row = 0; row < bh; row++) {
      int off = row * stride;
      for (int col = 0; col < bw; col++) {
        int i = off + col * 4;
        int b = buf[i], g = buf[i + 1], r = buf[i + 2];
        // loose red: the disc's antialiased rim is pink and must count as disc, not as a hole
        if (r >= 170 && (r - g) >= 60 && (r - b) >= 60) { red[row * bw + col] = true; res[3]++; }
      }
    }
    bool[] outside = new bool[bw * bh];
    int[] stack = new int[bw * bh];
    int sp = 0;
    for (int col = 0; col < bw; col++) {
      int a = col, b2 = (bh - 1) * bw + col;
      if (!red[a] && !outside[a]) { outside[a] = true; stack[sp++] = a; }
      if (!red[b2] && !outside[b2]) { outside[b2] = true; stack[sp++] = b2; }
    }
    for (int row = 0; row < bh; row++) {
      int a = row * bw, b2 = row * bw + bw - 1;
      if (!red[a] && !outside[a]) { outside[a] = true; stack[sp++] = a; }
      if (!red[b2] && !outside[b2]) { outside[b2] = true; stack[sp++] = b2; }
    }
    while (sp > 0) {
      int cur = stack[--sp];
      int cy = cur / bw, cx = cur - cy * bw;
      if (cx > 0) { int n = cur - 1; if (!red[n] && !outside[n]) { outside[n] = true; stack[sp++] = n; } }
      if (cx + 1 < bw) { int n = cur + 1; if (!red[n] && !outside[n]) { outside[n] = true; stack[sp++] = n; } }
      if (cy > 0) { int n = cur - bw; if (!red[n] && !outside[n]) { outside[n] = true; stack[sp++] = n; } }
      if (cy + 1 < bh) { int n = cur + bw; if (!red[n] && !outside[n]) { outside[n] = true; stack[sp++] = n; } }
    }
    for (int row = 0; row < bh; row++) {
      int off = row * stride;
      for (int col = 0; col < bw; col++) {
        int idx = row * bw + col;
        if (red[idx] || outside[idx]) { continue; }
        int i = off + col * 4;
        int b = buf[i], g = buf[i + 1], r = buf[i + 2];
        res[1]++;
        if (r >= 190 && g >= 190 && b >= 190) { res[0]++; }
        if (r >= 230 && g >= 230 && b >= 230) { res[2]++; }
      }
    }
    res[4] = bw * bh;
    return res;
  }
  // ---- muted bell (消息免打扰) ------------------------------------------------
  // A muted chat draws a small struck-through bell at the row's right edge, under the
  // timestamp: a neutral grey glyph (R~G~B) on the row background. Counting it in a small
  // window there is a cheap second opinion that does not depend on the badge colour.
  // WeChat renders each session row as ONE flattened Item, so there is no child element to
  // query for the label - pixels are the only per-row evidence besides the UIA Name.
  // int[8]: 0 neutral px | 1 window px | 2 darkest neutral | 3 brightest neutral
  //       | 4..7 the bbox of the neutral pixels: left, top, right, bottom (bitmap coords)
  // The bbox is what makes this usable: preview TEXT reaching the same spot paints a wide,
  // flat smear (bbox 30x4), while the bell glyph is a compact ~10x11 blob.
  public static int[] NeutralGray(Bitmap bmp, int x, int y, int w, int h, int tol, int lo, int hi) {
    int[] res = new int[8];
    if (bmp == null || w <= 0 || h <= 0) return res;
    int x0 = x, y0 = y, x1 = x + w, y1 = y + h;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > bmp.Width) x1 = bmp.Width;
    if (y1 > bmp.Height) y1 = bmp.Height;
    if (x1 <= x0 || y1 <= y0) return res;
    int bw = x1 - x0, bh = y1 - y0;
    int stride = 0;
    byte[] buf = null;
    BitmapData bd = null;
    try {
      stride = bw * 4;
      buf = new byte[stride * bh];
      for (int rr = 0; rr < bh; rr++) {
        for (int cc = 0; cc < bw; cc++) {
          Color c = bmp.GetPixel(x0 + cc, y0 + rr);
          int ii = rr * stride + cc * 4;
          buf[ii] = c.B; buf[ii + 1] = c.G; buf[ii + 2] = c.R; buf[ii + 3] = c.A;
        }
      }
    } finally { if (bd != null) { bmp.UnlockBits(bd); } }
    for (int row = 0; row < bh; row++) {
      int off = row * stride;
      for (int col = 0; col < bw; col++) {
        int i = off + col * 4;
        int b = buf[i], g = buf[i + 1], r = buf[i + 2];
        int mx = r; if (g > mx) mx = g; if (b > mx) mx = b;
        int mn = r; if (g < mn) mn = g; if (b < mn) mn = b;
        if (mx - mn > tol) continue;
        int v = (r + g + b) / 3;
        if (v < lo || v > hi) continue;
        res[0]++;
        if (res[2] == 0 || v < res[2]) res[2] = v;
        if (v > res[3]) res[3] = v;
        if (res[4] == 0 || x0 + col < res[4]) res[4] = x0 + col;
        if (res[5] == 0 || y0 + row < res[5]) res[5] = y0 + row;
        if (x0 + col > res[6]) res[6] = x0 + col;
        if (y0 + row > res[7]) res[7] = y0 + row;
      }
    }
    res[1] = bw * bh;
    return res;
  }
}
'@ -ErrorAction SilentlyContinue
  $AE  = [System.Windows.Automation.AutomationElement]
  $TS  = [System.Windows.Automation.TreeScope]
  $CT  = [System.Windows.Automation.ControlType]
  # Chinese literals built from code points: a GBK mis-parse of this file cannot corrupt them.
  $L_WX     = [string]([char]0x5FAE) + [char]0x4FE1                              # 微信
  $L_SESS   = [string]([char]0x4F1A) + [char]0x8BDD                              # 会话
  $L_MSG    = [string]([char]0x6D88) + [char]0x606F                              # 消息
  $L_SEND   = [string]([char]0x53D1) + [char]0x9001                              # 发送
  $L_PINNED = [string]([char]0x5DF2) + [char]0x7F6E + [char]0x9876               # 已置顶
  $L_CHATLOG = [string]([char]0x7684) + [char]0x804A + [char]0x5929 + [char]0x8BB0 + [char]0x5F55  # 的聊天记录（独立聊天记录窗口的标题后缀）
  $L_MUTED  = [string]([char]0x6D88) + [char]0x606F + [char]0x514D + [char]0x6253 + [char]0x6270    # 消息免打扰
  # Typed static patterns. AutomationPattern::LookupById() returns $null for several ids here.
  $PAT_INVOKE = [System.Windows.Automation.InvokePattern]::Pattern
  $PAT_VALUE  = [System.Windows.Automation.ValuePattern]::Pattern
  $PAT_SELIT  = [System.Windows.Automation.SelectionItemPattern]::Pattern
  # The MAIN window is the Weixin top-level window that actually contains the session list
  # (AutomationId session_list, or a List named 会话). WeChat 4.x can also open a standalone
  # "X和Y的聊天记录" window with the same Qt class but no session list: binding it made
  # watch fail with "sessions-list-not-found". So enumerate EVERY visible Weixin window,
  # probe each one with UIA, and bind only the one that owns the list. When UIA probing
  # fails (provider busy / window just shown) fall back to title="微信", then largest area.
  function Test-SessionListIn($el) {
    if ($el -eq $null) { return $false }
    try {
      $ca = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::AutomationIdProperty, 'session_list')
      if ($el.FindFirst($TS::Descendants, $ca) -ne $null) { return $true }
      $c1 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::ControlTypeProperty, $CT::List)
      $c2 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::NameProperty, $L_SESS)
      $and = New-Object System.Windows.Automation.AndCondition -ArgumentList @(,([System.Windows.Automation.Condition[]]@($c1, $c2)))
      if ($el.FindFirst($TS::Descendants, $and) -ne $null) { return $true }
    } catch { }
    return $false
  }
  # Diagnostics go to stderr so a manual run shows exactly which window was bound and why.
  function Write-RootLog([string]$m) {
    try { [Console]::Error.WriteLine('[wx_ctl] ' + $m) } catch { }
  }
  function Get-Root {
    if ($script:Root -ne $null) { return $script:Root }
    $pids = @()
    foreach ($p in @([System.Diagnostics.Process]::GetProcessesByName('Weixin'))) { $pids += [uint32]$p.Id }
    $wins = @()
    if ($pids.Count -gt 0) {
      foreach ($rec in [WxCtl32]::EnumWeixinWindows($pids)) {
        $f = $rec -split ([char]1)
        if ($f.Count -lt 7) { continue }
        $wins += [pscustomobject]@{
          hwnd = [IntPtr][int64]$f[0]; pid = [int]$f[1]; title = $f[2]; cls = $f[3]
          w = [int]$f[4]; h = [int]$f[5]; vis = ([int]$f[6] -eq 1)
        }
      }
    }
    # Chat-history windows are NEVER the main window, whatever else they look like.
    $chatlog = @($wins | Where-Object { $_.title -like ('*' + $L_CHATLOG) })
    $wins = @($wins | Where-Object { $_.title -notlike ('*' + $L_CHATLOG) })
    # Drop Tencent helper windows (tray bubble, tooltip save-bits, IME/Sogou, power/display
    # messages): they own no UI, and the 1920x1023 tray bubble would otherwise win the
    # largest-area fallback.
    $wins = @($wins | Where-Object {
      $_.title -ne '' -and
      -not ($_.cls -match 'WxTrayIcon|ToolSaveBits|PowerMessageWindow|SystemMessageWindow|MSCTFIME|IME$|Sogou|SoPY')
    })
    # Prefer windows the user can see; when WeChat is minimised to the tray EVERY window is
    # hidden, and the session list still has to be found (the restore step shows it again).
    $visible = @($wins | Where-Object { $_.vis })
    if ($visible.Count -gt 0) {
      $wins = $visible
    } else {
      $wins = @($wins | Where-Object { $_.w -gt 200 -and $_.h -gt 200 })
      if ($wins.Count -gt 0) { Write-RootLog 'all Weixin windows are hidden (tray): probing the hidden main window' }
    }
    if ($wins.Count -eq 0) {
      $only = (@($chatlog | ForEach-Object { $_.title }) -join ', ')
      $tail = $(if ($only -ne '') { ' (only chat-history windows: ' + $only + ')' } else { '' })
      throw ('wechat-window-not-found: no visible Weixin main window' + $tail)
    }
    # Preference order keeps the old behaviour: title 微信, Chrome_WidgetWin_1, Qt QWindowIcon, rest.
    $ordered = @()
    $ordered += @($wins | Where-Object { $_.title -eq $L_WX })
    $ordered += @($wins | Where-Object { $_.title -ne $L_WX -and $_.cls -eq 'Chrome_WidgetWin_1' })
    $ordered += @($wins | Where-Object { $_.title -ne $L_WX -and $_.cls -like '*QWindowIcon*' })
    $ordered += @($wins | Where-Object { $_.title -ne $L_WX })
    $probes = @()
    $tried = @{}
    foreach ($cd in $ordered) {
      if ($tried.ContainsKey($cd.hwnd)) { continue }
      $tried[$cd.hwnd] = $true
      $hasList = $false
      $el = $null
      try {
        $el = $AE::FromHandle($cd.hwnd)
        $hasList = Test-SessionListIn $el
      } catch { $hasList = $false }
      $probes += ('{0}|{1}|{2}x{3}|sessionList={4}' -f $cd.title, $cd.cls, $cd.w, $cd.h, $hasList)
      if ($hasList) {
        $script:Root = $el
        $script:RootHwnd = $cd.hwnd
        $script:RootPick = 'session-list'
        Write-RootLog ('selected by 会话 list: title="{0}" class="{1}" size={2}x{3} hwnd={4}' -f $cd.title, $cd.cls, $cd.w, $cd.h, $cd.hwnd)
        Write-RootLog ('candidates: ' + ($probes -join ' ; '))
        return $el
      }
    }
    # UIA could not prove the list: fall back to geometry/title, and say so loudly.
    $pick = @($ordered | Where-Object { $_.title -eq $L_WX }) | Select-Object -First 1
    $how = 'title=微信'
    if ($pick -eq $null) {
      $mhs = @()
      foreach ($pp in @([System.Diagnostics.Process]::GetProcessesByName('Weixin'))) {
        try { if ($pp.MainWindowHandle -ne [IntPtr]::Zero) { $mhs += $pp.MainWindowHandle } } catch { }
      }
      $pick = @($wins | Where-Object { $mhs -contains $_.hwnd }) | Select-Object -First 1
      $how = 'main-window-handle'
    }
    if ($pick -eq $null) {
      $pick = @($wins | Sort-Object -Property @{Expression = { $_.w * $_.h }} -Descending) | Select-Object -First 1
      $how = 'largest-area'
    }
    if ($pick -eq $null) { $pick = $ordered[0]; $how = 'first-candidate' }
    if ($pick -eq $null) { throw 'wechat-window-not-found: no visible Weixin main window could be bound via UIA' }
    $el2 = $null
    try { $el2 = $AE::FromHandle($pick.hwnd) } catch { }
    if ($el2 -eq $null) { throw 'wechat-window-not-found: UIA could not bind the fallback window' }
    $script:Root = $el2
    $script:RootHwnd = $pick.hwnd
    $script:RootPick = $how
    Write-RootLog ('selected by fallback ({0}): title="{1}" class="{2}" size={3}x{4} hwnd={5}' -f $how, $pick.title, $pick.cls, $pick.w, $pick.h, $pick.hwnd)
    Write-RootLog ('candidates: ' + ($probes -join ' ; '))
    return $el2
  }
  function Get-RootHwnd { [void](Get-Root); return $script:RootHwnd }
  # AutomationId first (stable across renames / emoji / i18n), Chinese Name as fallback.
  function Find-List([string]$aid, [string]$name) {
    $root = Get-Root
    if (-not [string]::IsNullOrWhiteSpace($aid)) {
      $ca = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::AutomationIdProperty, $aid)
      $hit = $root.FindFirst($TS::Descendants, $ca)
      if ($hit -ne $null) { return $hit }
    }
    return (Find-ListByName $name)
  }
  function Find-ListByName([string]$name) {
    $root = Get-Root
    $c1 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::ControlTypeProperty, $CT::List)
    $c2 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::NameProperty, $name)
    $and = New-Object System.Windows.Automation.AndCondition -ArgumentList @(,([System.Windows.Automation.Condition[]]@($c1, $c2)))
    return $root.FindFirst($TS::Descendants, $and)
  }
  function Get-Children($el) {
    $out = @()
    if ($el -eq $null) { return $out }
    $w = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ch = $w.GetFirstChild($el)
    while ($ch -ne $null) { $out += $ch; $ch = $w.GetNextSibling($ch) }
    return $out
  }
  function Get-SessionItems {
    $list = Find-List 'session_list' $L_SESS
    if ($list -eq $null) { throw "sessions-list-not-found: no List named '$L_SESS'" }
    return @(Get-Children $list)
  }
  # ListItem.Name is "title\n[已置顶\n]preview\ntime". 已置顶 is optional -> must not shift fields.
  function Split-SessionName([string]$raw) {
    $parts = @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $title = ''; $pinned = $false; $preview = ''; $time = ''
    if ($parts.Count -gt 0) { $title = $parts[0] }
    $i = 1
    if ($parts.Count -gt $i -and $parts[$i] -eq $L_PINNED) { $pinned = $true; $i++ }
    if ($parts.Count -gt $i) { $time = $parts[$parts.Count - 1] }
    if ($parts.Count -gt ($i + 1)) { $preview = ($parts[$i..($parts.Count - 2)] -join "`n") }
    return [pscustomobject]@{ title = $title; pinned = $pinned; preview = $preview; time = $time }
  }
  function Get-IsSelected($el) {
    try {
      $si = $null
      if ($el.TryGetCurrentPattern($PAT_SELIT, [ref]$si) -and $si -ne $null) {
        # no [bool] cast: "[bool]$si.Current.IsSelected" mis-binds in PS 5.1
        if ($si.Current.IsSelected) { return $true } else { return $false }
      }
    } catch { }
    return $false
  }
  function Get-InputEdit {
    $root = Get-Root
    $c = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::AutomationIdProperty, 'chat_input_field')
    $el = $root.FindFirst($TS::Descendants, $c)
    if ($el -ne $null) { return $el }
    $c2 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::ControlTypeProperty, $CT::Edit)
    return $root.FindFirst($TS::Descendants, $c2)
  }
  function Get-SendButton {
    $root = Get-Root
    $c1 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::ControlTypeProperty, $CT::Button)
    $c2 = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::NameProperty, $L_SEND)
    $and = New-Object System.Windows.Automation.AndCondition -ArgumentList @(,([System.Windows.Automation.Condition[]]@($c1, $c2)))
    return $root.FindFirst($TS::Descendants, $and)
  }
  function Get-ButtonEnabled($btn) {
    if ($btn -ne $null -and $btn.Current.IsEnabled) { return $true }
    return $false
  }
  # A conversation is "open" only while chat_message_list exists: after collapsing the panel
  # (click the selected row again, or Esc) the Edit survives with an EMPTY Name, so the Edit is
  # not a reliable open/closed signal. Its Name is still the open chat's title while open.
  function Test-ChatOpen {
    $hwnd = Get-RootHwnd
    $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'chat_message_list')
    $el = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    return ($el -ne $null)
  }
  function Get-ChatNameOfEdit {
    $e = Get-InputEdit
    if ($e -eq $null) { return $null }
    return $e.Current.Name
  }
  # ---- chat title bar: title text + "(N)" member count ----------------------
  # A group chat's title bar renders "群名称(49)"; a 1:1 chat renders only the
  # name. That is a much stronger kind signal than counting "sender: " prefixes:
  # a group always carries the member count, a person never does. The bar text is
  # NOT the input field's Name (chat_input_field.Name is the bare chat name), so
  # the bar's own element has to be found. We avoid hard-coding one widget class:
  # a candidate is any VISIBLE element whose Name is exactly the open chat's name
  # with an optional trailing "(N)"/"（N）" - nothing else qualifies, so the
  # multi-line session rows never match. The title-bar container class is tried
  # first (small subtree, fast); the whole window is the fallback.
  $script:TitleBarClasses = @('mmui::ChatTitleBarMasterView', 'mmui::ChatTitleBarView', 'mmui::ChatHeaderView')
  $script:GroupCountPat   = '[\(（]\s*(\d{1,4})\s*[\)）]\s*$'
  # -> @{ isGroup; confidence('high'|'low'); count; reason }
  function Get-TitleKind([string]$title) {
    $res = [pscustomobject]@{ isGroup = $false; confidence = 'low'; count = 0; reason = 'empty' }
    if ([string]::IsNullOrWhiteSpace($title)) { return $res }
    $t = $title.Trim()
    $m = [regex]::Match($t, $script:GroupCountPat)
    if ($m.Success) {
      $n = 0
      try { $n = [int]$m.Groups[1].Value } catch { $n = 0 }
      $res.count = $n
      # WeChat groups cap at 500 members: "(2)".."(500)" is a member count; "(1)"
      # or "(2024)" is far more likely a nickname/year, so keep those ambiguous
      # (low confidence) and let the caller fall back to the preview heuristic.
      if ($n -ge 2 -and $n -le 500) {
        $res.isGroup = $true; $res.confidence = 'high'; $res.reason = 'member-count'
      } else {
        $res.isGroup = $false; $res.confidence = 'low'; $res.reason = 'ambiguous-count'
      }
      return $res
    }
    # a truncated bar ("一个很长的群名称…") can hide the count: never turn that
    # into a confident "private"
    if ($t.EndsWith([string][char]0x2026) -or $t.EndsWith('...')) {
      $res.reason = 'truncated'
      return $res
    }
    $res.confidence = 'high'; $res.reason = 'no-count'
    return $res
  }
  function Get-ChatTitleInfoCore {
    $none = [pscustomobject]@{
      title = ''; source = 'none'; isGroup = $false; confidence = 'low'
      count = 0; reason = 'chat-closed'; element = $null
    }
    $editName = $null
    try { $editName = Get-ChatNameOfEdit } catch { $editName = $null }
    if ([string]::IsNullOrWhiteSpace($editName)) { return $none }
    $none.reason = 'title-element-not-found'
    # geometry anchors: the bar sits above the message list, inside the chat panel
    $msgTop = -1; $panelLeft = -1
    try {
      $msgList = Find-List 'chat_message_list' $L_MSG
      if ($msgList -ne $null) {
        $mr = $msgList.Current.BoundingRectangle
        if ($mr.Width -gt 0 -and $mr.Height -gt 0) { $msgTop = [int]$mr.Y; $panelLeft = [int]$mr.X }
      }
    } catch { }
    $root = Get-Root
    $scopes = @()
    foreach ($cn in $script:TitleBarClasses) {
      try {
        $cond = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::ClassNameProperty, $cn)
        $hit = $root.FindFirst($TS::Descendants, $cond)
        if ($hit -ne $null) { $scopes += $hit; break }
      } catch { }
    }
    $titleBarScope = $null
    if ($scopes.Count -gt 0) { $titleBarScope = $scopes[0] }
    $best = $null; $bestScore = 0
    $scanScopes = @()
    if ($titleBarScope -ne $null) { $scanScopes += $titleBarScope }
    $scanScopes += $root
    foreach ($scope in $scanScopes) {
      # inside the title-bar container the title must exist; from the root the
      # exact-name requirement is what keeps this from matching anything else
      $list = @()
      try { $list = @($scope.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) } catch { $list = @() }
      if ($scope -ne $root) { $list = @($scope) + $list }
      foreach ($el in $list) {
        try {
          $nm = [string]$el.Current.Name
          if ([string]::IsNullOrWhiteSpace($nm)) { continue }
          $nm = $nm.Trim()
          if ($nm.Contains("`n")) { continue }
          $r = $el.Current.BoundingRectangle
          if ($r.Width -le 0 -or $r.Height -le 0) { continue }
          $m = [regex]::Match($nm, $script:GroupCountPat)
          $base = $nm
          if ($m.Success) { $base = $nm.Substring(0, $nm.Length - $m.Length).Trim() }
          if ($base -ne $editName) { continue }
          $cls = ''
          try { $cls = [string]$el.Current.ClassName } catch { }
          $score = 0
          if ($m.Success) { $score += 40 } else { $score += 30 }
          if ($cls -match 'ChatTitleBar|ChatTitle|TitleBar|ChatHeader') { $score += 20 }
          $cx = $r.X + $r.Width / 2
          if ($msgTop -ge 0 -and $r.Y -lt $msgTop -and $cx -gt $panelLeft) { $score += 20 }
          if ($score -gt $bestScore) {
            $aid = ''
            try { $aid = [string]$el.Current.AutomationId } catch { }
            $bestScore = $score
            $best = [pscustomobject]@{
              title = $nm; cls = $cls; aid = $aid
              x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height
              hasCount = [bool]$m.Success; scope = $scope
            }
          }
        } catch { }
      }
      # the title-bar subtree is enough; only fall through to the whole window
      # when nothing qualified there
      if ($best -ne $null -and $bestScore -ge 50) { break }
    }
    if ($best -eq $null -or $bestScore -lt 50) { return $none }
    # The name and the "(N)" count can be two separate labels. Only trust this
    # inside a known title-bar container (never on the whole-window scan, where a
    # stray number could be anything).
    if (-not $best.hasCount -and $titleBarScope -ne $null) {
      try {
        $all2 = @($titleBarScope.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
        foreach ($e2 in $all2) {
          try {
            $n2 = ([string]$e2.Current.Name).Trim()
            if ($n2 -notmatch '^[\(（]?\s*\d{1,4}\s*[\)）]?$') { continue }
            $v = [int]([regex]::Match($n2, '\d{1,4}').Value)
            if ($v -lt 2 -or $v -gt 500) { continue }
            $r2 = $e2.Current.BoundingRectangle
            if ($r2.Width -le 0 -or $r2.Height -le 0) { continue }
            $yOverlap = ($r2.Y -lt ($best.y + $best.h + 4)) -and (($r2.Y + $r2.Height) -gt ($best.y - 4))
            $xNear    = ($r2.X -ge ($best.x + $best.w - 4)) -and ($r2.X -le ($best.x + $best.w + 80))
            if ($yOverlap -and $xNear) {
              $best.title = $best.title + '(' + $v.ToString() + ')'
              $best.hasCount = $true
              break
            }
          } catch { }
        }
      } catch { }
    }
    $k = Get-TitleKind $best.title
    return [pscustomobject]@{
      title = $best.title; source = 'titlebar'; isGroup = $k.isGroup
      confidence = $k.confidence; count = $k.count; reason = $k.reason
      element = [ordered]@{
        cls = $best.cls; aid = $best.aid; score = $bestScore
        x = $best.x; y = $best.y; w = $best.w; h = $best.h
      }
    }
  }
  # Never throws: the title is a bonus signal, so a UIA hiccup must not break
  # -Mode read / preflight (message reading has to keep working regardless).
  function Get-ChatTitleInfo {
    try { return (Get-ChatTitleInfoCore) }
    catch {
      return [pscustomobject]@{
        title = ''; source = 'none'; isGroup = $false; confidence = 'low'
        count = 0; reason = 'title-lookup-error'; element = $null
      }
    }
  }
  function Get-EditValue($edit) {
    try {
      $v = $null
      if ($edit.TryGetCurrentPattern($PAT_VALUE, [ref]$v) -and $v -ne $null) { return [string]$v.Current.Value }
    } catch { }
    return $null
  }
  function Set-EditValue($edit, [string]$value) {
    $v = $null
    if (-not ($edit.TryGetCurrentPattern($PAT_VALUE, [ref]$v) -and $v -ne $null)) {
      throw 'value-pattern-unsupported: Edit has no ValuePattern'
    }
    $v.SetValue($value)
  }
  # All top-level windows of the Weixin process, INCLUDING the ones with an empty title.
  # The context-menu popup is such a window (Qt popup, no title), so Get-Root - which
  # requires a non-empty title and a session list - can never be used to find it.
  function Get-WeixinWindowList {
    $pids = @()
    foreach ($p in @([System.Diagnostics.Process]::GetProcessesByName('Weixin'))) { $pids += [uint32]$p.Id }
    $out = @()
    if ($pids.Count -eq 0) { return $out }
    foreach ($rec in [WxCtl32]::EnumWeixinWindows($pids)) {
      $f = $rec -split ([char]1)
      if ($f.Count -lt 7) { continue }
      $h = [IntPtr][int64]$f[0]
      $wr = New-Object WxCtl32+RECT
      $ok = $false
      try { $ok = [WxCtl32]::GetWindowRect($h, [ref]$wr) } catch { $ok = $false }
      $out += [pscustomobject]@{
        hwnd = $h; pid = [int]$f[1]; title = $f[2]; cls = $f[3]
        w = [int]$f[4]; h = [int]$f[5]; vis = ([int]$f[6] -eq 1)
        x = $(if ($ok) { [int]$wr.Left } else { 0 }); y = $(if ($ok) { [int]$wr.Top } else { 0 })
      }
    }
    return $out
  }
  # Synthetic click at a SCREEN point, posted into $hwnd's client coordinates.
  # Same no-cursor / no-focus rule as Click-ElementCenter; 'right' opens the row context menu,
  # and both are used on the popup itself (which would ignore a click posted to the main window).
  function Click-ScreenPoint($hwnd, [int]$sx, [int]$sy, [string]$button = 'left') {
    if ($null -eq $hwnd) { throw 'click-target-window-is-null' }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'click-target-window-is-zero' }
    $pt = New-Object WxCtl32+POINT
    $pt.X = $sx; $pt.Y = $sy
    [void][WxCtl32]::ScreenToClient($hwnd, [ref]$pt)
    $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    [void][WxCtl32]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, $lp)
    Start-Sleep -Milliseconds 50
    if ($button -eq 'right') {
      [void][WxCtl32]::PostMessage($hwnd, 0x0204, [IntPtr]2, $lp)
      Start-Sleep -Milliseconds 70
      [void][WxCtl32]::PostMessage($hwnd, 0x0205, [IntPtr]::Zero, $lp)
    } else {
      [void][WxCtl32]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp)
      Start-Sleep -Milliseconds 60
      [void][WxCtl32]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, $lp)
    }
    return ($pt.X.ToString() + ',' + $pt.Y.ToString())
  }
  # Walk up to the TOP-LEVEL automation element that owns $el and return its window handle;
  # an element inside a Qt popup does not report the popup's hwnd itself.
  function Get-TopLevelHwndOf($el, $fallback) {
    if ($el -eq $null) { return $fallback }
    $w = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $el
    for ($i = 0; $i -lt 40 -and $cur -ne $null; $i++) {
      $p = $null
      try { $p = $w.GetParent($cur) } catch { }
      if ($p -eq $null) { break }
      try { if ($p -eq [System.Windows.Automation.AutomationElement]::RootElement) { break } } catch { }
      $cur = $p
    }
    $h = [IntPtr]::Zero
    try { $h = [IntPtr]$cur.Current.NativeWindowHandle } catch { }
    if ($h -eq [IntPtr]::Zero) { return $fallback }
    return $h
  }
  # Find a menu entry by Name. Menu popups are their own top-level windows (often with an
  # empty title), so every Weixin window is probed; the bound main window is the last resort.
  # The click on a popup entry MUST be posted into the popup window itself: a click posted to
  # the main window is converted to main-client coordinates (far off-screen) and only dismisses
  # the menu - the measured failure mode of the first implementation.
  # So: search the SMALLEST visible Weixin windows first (a menu popup is a few hundred px),
  # and use the rect of the window that actually yielded the element.
  function Find-MenuItemByName([string]$name, $wins, $mainHwnd) {
    $cond = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::NameProperty, $name)
    $ordered = @(@($wins) | Where-Object {
        $_.vis -and -not ($_.hwnd -eq $mainHwnd) -and ($_.w -lt 700) -and ($_.h -lt 700)
      } | Sort-Object { [int]$_.w * [int]$_.h })
    foreach ($w in $ordered) {
      $el = $null
      try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($w.hwnd) } catch { }
      if ($el -eq $null) { continue }
      $cand = @()
      try { $cand = @($el.FindAll($TS::Descendants, $cond)) } catch { }
      foreach ($hit in $cand) {
        $ir = $null
        try { $ir = $hit.Current.BoundingRectangle } catch { }
        if ($ir -eq $null -or $ir.Width -le 0 -or $ir.Height -le 0) { continue }
        # the element must actually lie inside the window we are going to post into
        $inside = ($ir.X -ge $w.x - 2 -and $ir.Y -ge $w.y - 2 -and
                   ($ir.X + $ir.Width) -le ($w.x + $w.w + 2) -and
                   ($ir.Y + $ir.Height) -le ($w.y + $w.h + 2))
        return [pscustomobject]@{ element = $hit; hwnd = $w.hwnd; win = $w; inside = $inside; count = $cand.Count }
      }
    }
    return $null
  }
  # Smallest visible Weixin window whose rect contains the screen point (the popup under the
  # menu entry); falls back to $null.
  function Get-WindowAtPoint($wins, [int]$sx, [int]$sy, $mainHwnd) {
    $best = $null
    foreach ($w in @($wins)) {
      if (-not $w.vis) { continue }
      if ($w.hwnd -eq $mainHwnd) { continue }
      if ($sx -lt $w.x -or $sy -lt $w.y -or $sx -ge ($w.x + $w.w) -or $sy -ge ($w.y + $w.h)) { continue }
      if ($best -eq $null -or ([int]$w.w * [int]$w.h) -lt ([int]$best.w * [int]$best.h)) { $best = $w }
    }
    return $best
  }
  # Scroll-to-find a session row WITHOUT selecting it: top of the list first, then one
  # viewport down at a time. Same walk as -Mode focus, factored out so -Mode read and
  # -Mode markunread can reach a chat that is not in the first viewport.
  function Find-SessionRowScrolled([string]$title, [int]$maxScreens = 14) {
    $passes = 0
    $barSeen = $false
    $hit = $null
    $trace = @()
    $topInfo = Scroll-ListToTop 140 20
    for ($i = 0; $i -lt $maxScreens -and $hit -eq $null; $i++) {
      $items = @(Get-SessionItems)
      $first = ''
      $last = ''
      if ($items.Count -gt 0) {
        $first = (Split-SessionName ([string]$items[0].Current.Name)).title
        $last = (Split-SessionName ([string]$items[$items.Count - 1].Current.Name)).title
      }
      if ($trace.Count -lt 24) { $trace += ('s' + $i + ':' + $items.Count + ' rows [' + $first + ' .. ' + $last + ']') }
      foreach ($it in $items) {
        $cls = ''
        try { $cls = [string]$it.Current.ClassName } catch { }
        if ($cls -eq 'mmui::ChatStickyFoldCell') { $barSeen = $true; continue }
        $sp = Split-SessionName ([string]$it.Current.Name)
        if ($sp.title -eq $title) { $hit = $it; break }
      }
      if ($hit -eq $null -and $i -lt ($maxScreens - 1)) {
        Send-ListWheel -780
        Start-Sleep -Milliseconds 170
        $passes++
      }
    }
    return [pscustomobject]@{ item = $hit; passes = $passes; barSeen = $barSeen; trace = $trace; topPasses = $topInfo.passes; topStable = $topInfo.stable }
  }
  # Synthetic click on an element centre, posted to the top-level window in client coordinates.
  # No cursor movement and no focus steal; the caller MUST verify the effect afterwards.
  function Click-ElementCenter($item) {
    $hwnd = Get-RootHwnd
    $br = $item.Current.BoundingRectangle
    if ($br.Width -le 0 -or $br.Height -le 0) { throw 'element-has-no-bounding-rect' }
    $cx = [int]($br.X + $br.Width / 2)
    $cy = [int]($br.Y + $br.Height / 2)
    $pt = New-Object WxCtl32+POINT
    $pt.X = $cx; $pt.Y = $cy
    [void][WxCtl32]::ScreenToClient($hwnd, [ref]$pt)
    $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    [void][WxCtl32]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, $lp)
    Start-Sleep -Milliseconds 60
    [void][WxCtl32]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp)
    Start-Sleep -Milliseconds 40
    [void][WxCtl32]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, $lp)
    return ($cx.ToString() + ',' + $cy.ToString())
  }
  function Test-ChatTitleMatches([string]$wantTitle) {
    $now = ''
    try { $now = Get-ChatNameOfEdit } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($now)) { return $false }
    if ($now -eq $wantTitle) { return $true }
    $short = $wantTitle.TrimEnd([char]0x2026, [char]0x2E, [char]0x20)
    if ($short.Length -ge 2 -and $now.StartsWith($short)) { return $true }
    if ($now.Length -ge 2 -and $wantTitle.StartsWith($now)) { return $true }
    return $false
  }
  function Invoke-SelectSession($item, [string]$wantTitle) {
    $tried = @()
    # A: SelectionItemPattern.Select
    try {
      $si = $null
      if ($item.TryGetCurrentPattern($PAT_SELIT, [ref]$si) -and $si -ne $null) {
        $si.Select()
        Start-Sleep -Milliseconds 300
        if ((Get-IsSelected $item) -or (Test-ChatTitleMatches $wantTitle)) { return 'SelectionItemPattern.Select' }
        $tried += 'SelectionItemPattern.Select(no-op)'
      } else { $tried += 'SelectionItemPattern(unavailable)' }
    } catch { $tried += ('SelectionItemPattern.Select(error: ' + $_.Exception.Message + ')') }
    # B: InvokePattern.Invoke
    try {
      $iv = $null
      if ($item.TryGetCurrentPattern($PAT_INVOKE, [ref]$iv) -and $iv -ne $null) {
        $iv.Invoke()
        Start-Sleep -Milliseconds 300
        if ((Get-IsSelected $item) -or (Test-ChatTitleMatches $wantTitle)) {
          return ('InvokePattern.Invoke (after ' + ($tried -join '; ') + ')')
        }
        $tried += 'InvokePattern.Invoke(no-op)'
      } else { $tried += 'InvokePattern(unavailable)' }
    } catch { $tried += ('InvokePattern.Invoke(error: ' + $_.Exception.Message + ')') }
    # C: verified synthetic click
    try {
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        $pt = Click-ElementCenter $item
        Start-Sleep -Milliseconds (500 + 300 * $attempt)
        if (Test-ChatTitleMatches $wantTitle) {
          return ('SyntheticClick@' + $pt + ' (attempt ' + $attempt + ', after ' + ($tried -join '; ') + ')')
        }
        $tried += ('SyntheticClick@' + $pt + '(no-op)')
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 200 }
      }
    } catch { $tried += ('SyntheticClick(error: ' + $_.Exception.Message + ')') }
    $observed = ''
    try { $observed = Get-ChatNameOfEdit } catch { }
    throw ('session-select-failed: none of Select/Invoke/Click switched the chat. wanted=' + $wantTitle + ' observed=' + $observed + ' tried: ' + ($tried -join '; '))
  }
  # Minimized-window self-rescue: a minimized WeChat keeps a valid UIA tree, but every
  # Select/Invoke/PostMessage lands as a no-op, so switching chats fails while the window
  # is iconic. Restore it (SW_RESTORE only: no SetForegroundWindow, no moving/resizing,
  # so an overlap or z-order is harmless) and retry the same A/B/C sequence once.
  function Select-Session($item, [string]$wantTitle) {
    $script:RestoredWindow = $false
    $script:MovedOnScreen = $false
    $firstError = $null
    try { return (Invoke-SelectSession $item $wantTitle) } catch { $firstError = $_.Exception.Message }
    $hwnd = [IntPtr]::Zero
    try { $hwnd = Get-RootHwnd } catch { }
    if ($hwnd -ne [IntPtr]::Zero -and [WxCtl32]::IsIconic($hwnd)) {
      [void][WxCtl32]::ShowWindow($hwnd, 9)
      Start-Sleep -Milliseconds 400
      $script:RestoredWindow = $true
    }
    # SW_RESTORE alone is not enough: Qt keeps the minimized geometry (-32000,-32000), so the
    # window is "not iconic" yet every element has an empty BoundingRectangle. Move it back.
    if ($hwnd -ne [IntPtr]::Zero -and [WxCtl32]::IsOffScreen($hwnd)) {
      try {
        [void][WxCtl32]::MoveOnScreen($hwnd, 80, 80, 900, 700)
        Start-Sleep -Milliseconds 300
        $script:MovedOnScreen = $true
        $script:RestoredWindow = $true
      } catch { }
    }
    if ($script:MovedOnScreen -or $script:RestoredWindow) {
      $fresh = $null
      try { $fresh = Find-Session $wantTitle } catch { }
      if ($fresh -eq $null) { $fresh = $item }
      try { return (Invoke-SelectSession $fresh $wantTitle) }
      catch {
        $script:RestoredWindow = $false
        throw ($firstError + ' | after-restore-retry: ' + $_.Exception.Message)
      }
    }
    throw $firstError
  }
  function Get-Messages([int]$max, $bmp = $null) {
    $list = Find-List 'chat_message_list' $L_MSG
    if ($list -eq $null) { throw "messages-list-not-found: no List named '$L_MSG'" }
    $kids = @(Get-Children $list)
    $n = $kids.Count
    $take = [Math]::Min($max, $n)
    $rows = @()
    # WeChat renders "昨天 18:20" / "15:52" as standalone rows between messages; remember the
    # most recent marker and stamp it onto every following row so each message carries a time.
    $lastTime = $null
    for ($j = $n - $take; $j -lt $n; $j++) {
      $el = $kids[$j]
      $r = $el.Current.BoundingRectangle
      $cls = ''
      try { $cls = [string]$el.Current.ClassName } catch { }
      $text = [string]$el.Current.Name
      if ($text -match '^\s*(\d{1,2}:\d{2}|昨天|前天|星期|周[一二三四五六日]|\d{1,2}月\d{1,2}日|\d{4}年)') {
        $lastTime = $text.Trim()
      }
      # dir/greenPx/greenRatio/side stay neutral until Add-MessageDirections has a bitmap
      $rows += [pscustomobject]@{
        text = $text; time = $lastTime; y = [int]$r.Y; x = [int]$r.X; w = [int]$r.Width; h = [int]$r.Height
        cls = $cls; dir = 'unknown'; greenPx = -1; greenRatio = 0; side = 'none'; leftFill = 0; rightFill = 0
      }
    }
    return [pscustomobject]@{ rows = $rows; total = $n }
  }
  # ---- pixel-based message direction --------------------------------------
  # Every message ListItem has the same x/w (the whole row), so left/right cannot be inferred
  # from the rect: only the bubble colour can tell. Green bubble = our own message ("out");
  # a near-white bubble = the other side ("in"). A green avatar on the left of an inbound
  # message is the one false positive, hence the right-hand-band corroboration (side).
  function Get-WindowBitmap {
    $hwnd = Get-RootHwnd
    $method = ''
    $bmp = [WxShot]::Grab($hwnd, [ref]$method)
    return [pscustomobject]@{ bmp = $bmp; method = $method; hwnd = $hwnd }
  }
  # Rows that are not a chat bubble at all: the timestamp separator and system notices
  # ("you recalled a message"). Their colour says nothing about direction.
  function Test-NonBubbleRow([string]$cls) {
    if ([string]::IsNullOrWhiteSpace($cls)) { return $true }
    if ($cls -match 'ChatSystemInfoItemView') { return $true }
    if ($cls -match '::ChatItemView$') { return $true }
    return $false
  }
  # Media bubbles: an inbound one is plain white, exactly like inbound text, and an outbound
  # image/video thumbnail can carry no green fill either -> colour alone cannot decide.
  function Test-MediaRow([string]$cls) {
    return ($cls -match 'Image|Voice|Video|File|Emoji|App|Link|Card|Merged|Note|Refer')
  }
  # Mutates each row in place: dir = out|in|unknown, greenPx, greenRatio, side = right|left|none.
  function Add-MessageDirections($rows, $bmp) {
    if ($bmp -eq $null) { return }
    $hwnd = Get-RootHwnd
    foreach ($row in @($rows)) {
      $row.dir = 'unknown'
      $row.greenPx = -1
      $row.greenRatio = 0
      $row.side = 'none'
      if (Test-NonBubbleRow $row.cls) { $row.greenPx = 0; continue }
      $rc = $null
      try { $rc = [WxShot]::ScreenRectToBitmap($hwnd, [int]$row.x, [int]$row.y, [int]$row.w, [int]$row.h) } catch { continue }
      $tot = 0
      $lg = 0
      $rg = 0
      $lp = 0
      $rp = 0
      $g = 0
      try { $g = [WxShot]::CountGreen($bmp, $rc[0], $rc[1], $rc[2], $rc[3], [ref]$tot, [ref]$lg, [ref]$rg, [ref]$lp, [ref]$rp) } catch { continue }
      $row.greenPx = $g
      if ($tot -le 0) { continue }
      $row.greenRatio = [Math]::Round($g / $tot, 4)
      $row.leftFill = $(if ($lp -gt 0) { [Math]::Round($lg / $lp, 4) } else { 0 })
      $row.rightFill = $(if ($rp -gt 0) { [Math]::Round($rg / $rp, 4) } else { 0 })
      # an own bubble is right-aligned: empty left band, filled right band; inbound mirrors it
      if ($row.leftFill -lt 0.10 -and $row.rightFill -ge 0.15) { $row.side = 'right' }
      elseif ($row.rightFill -lt 0.10 -and $row.leftFill -ge 0.15) { $row.side = 'left' }
      elseif ($row.leftFill -ge 0.15 -and $row.rightFill -ge 0.15) { $row.side = 'both' }
      # 'both' means a bubble wide enough to reach both edges: only a solid green fill counts
      if ($g -gt 0 -and $row.greenRatio -ge 0.01 -and $row.side -eq 'right') { $row.dir = 'out' }
      elseif ($g -gt 0 -and $row.greenRatio -ge 0.10 -and $row.side -eq 'both') { $row.dir = 'out' }
      elseif (Test-MediaRow $row.cls) { $row.dir = 'unknown' }
      else { $row.dir = 'in' }
    }
  }
  # pinned chats can be folded behind the bottom_sticky_folder button
  function Expand-PinnedFolder {
    $root = Get-Root
    $c = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::AutomationIdProperty, 'bottom_sticky_folder')
    $btn = $root.FindFirst($TS::Descendants, $c)
    if ($btn -eq $null) { return $null }
    try {
      $pt = Click-ElementCenter $btn
      Start-Sleep -Milliseconds 500
      return $pt
    } catch { return "error: " + $_.Exception.Message }
  }
  function Find-Session($title) {
    $hit = Find-SessionRaw $title
    if ($hit -ne $null) { return $hit }
    # not in the visible list -> pinned chats may be folded away; expand once and retry
    $pt = Expand-PinnedFolder
    if ($pt -eq $null) { return $null }
    $script:FolderExpanded = $true
    $script:FolderPoint = $pt
    return (Find-SessionRaw $title)
  }
  function Find-SessionRaw($title) {
    $list = Find-List 'session_list' $L_SESS
    if ($list -eq $null) { return $null }
    $aid = 'session_item_' + $title
    $ca = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::AutomationIdProperty, $aid)
    $hit = $list.FindFirst($TS::Descendants, $ca)
    if ($hit -ne $null) { return $hit }
    foreach ($it in @(Get-Children $list)) {
      if ($it.Current.AutomationId -eq $aid) { return $it }
      $sp = Split-SessionName $it.Current.Name
      if ($sp.title -eq $title) { return $it }
    }
    return $null
  }
  # ---- probe helpers: conservative group/private detection from the preview text only ----
  # Returns the "sender: " prefix when the preview looks like "sender: text", else ''.
  # Known false positive: our own message text that contains a colon ("A:B") looks identical
  # to a group preview, because WeChat renders our own messages without a sender prefix.
  function Get-PreviewPrefix([string]$preview) {
    if ([string]::IsNullOrWhiteSpace($preview)) { return '' }
    $colon  = [char]0xFF1A
    $draft  = [string][char]0x8349 + [char]0x7A3F
    $recall = [string][char]0x64A4 + [char]0x56DE
    if ($preview.StartsWith('[' + $draft + ']')) { return '' }
    if ($preview.Contains($recall)) { return '' }
    $pat = '^([^\s' + $colon + ':]{1,20})[' + $colon + ':]\s?(\S)'
    $m = [regex]::Match($preview, $pat)
    if (-not $m.Success) { return '' }
    $pfx = $m.Groups[1].Value.Trim()
    $proto = @('http','https','www','ftp','ftps','file','ws','wss','mailto','tel','magnet','data')
    if ($proto -contains $pfx.ToLowerInvariant()) { return '' }
    if ($pfx -match '^\d+$') { return '' }
    return $pfx
  }
  function Get-PreviewKind([string]$preview) {
    if ([string]::IsNullOrWhiteSpace($preview)) { return 'unknown' }
    $draft  = [string][char]0x8349 + [char]0x7A3F
    $recall = [string][char]0x64A4 + [char]0x56DE
    if ($preview.StartsWith('[' + $draft + ']')) { return 'unknown' }
    if ($preview.Contains($recall)) { return 'unknown' }
    $pfx = Get-PreviewPrefix $preview
    if ($pfx -ne '') { return 'group' }
    if ($preview.Contains(':') -or $preview.Contains([char]0xFF1A)) { return 'unknown' }
    return 'private'
  }
  function Get-KindCache([string]$path) {
    $map = @{}
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
      try {
        $o = ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        foreach ($pp in $o.PSObject.Properties) { $map[$pp.Name] = [string]$pp.Value }
      } catch { }
    }
    return $map
  }
  function Save-KindCache([string]$path, $map) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
      $obj = [ordered]@{}
      foreach ($k in $map.Keys) { $obj[$k] = $map[$k] }
      [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    } catch { }
  }
  # ---- outbox (texts we sent recently) + echo suppression -------------------
  # All outbox rows live in $obRows (NOT $outbox: that name is the [string] parameter, and an
  # assignment to it would be coerced to a string).
  function Resolve-OutboxPath {
    if (-not [string]::IsNullOrWhiteSpace($Outbox)) { return $Outbox }
    if (-not [string]::IsNullOrWhiteSpace($Out)) { return (Join-Path (Split-Path -Parent $Out) 'wx_outbox.json') }
    return ''
  }
  # Emits one hashtable per entry: @{ session = ''; text = ''; sentAt = <epoch-ms> }.
  # Plain hashtables on purpose: an earlier version accumulated [pscustomobject] rows in an
  # array that came back from the function as a single $null element, so echo never matched.
  function Get-Outbox([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not (Test-Path -LiteralPath $path)) { return }
    $raw = $null
    try { $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $o = $null
    try { $o = $raw | ConvertFrom-Json } catch { return }
    foreach ($e in @($o)) {
      $s = ''; $tx = ''; $st = [int64]0
      if ($e -is [string]) {
        $tx = [string]$e
      } else {
        foreach ($pp in $e.PSObject.Properties) {
          $n = ('' + $pp.Name).ToLower()
          if ($n -eq 'session') { $s = [string]$pp.Value }
          elseif ($n -eq 'text') { $tx = [string]$pp.Value }
          elseif ($n -eq 'sentat') {
            $v = $pp.Value
            if ($v -is [datetime]) {
              $st = [int64]((([datetime]$v).ToUniversalTime()) - [datetime]'1970-01-01').TotalMilliseconds
            } elseif (('' + $v) -match '^\d+$') {
              $st = [int64]$v
            } else {
              try { $st = [int64]((([datetime]$v).ToUniversalTime()) - [datetime]'1970-01-01').TotalMilliseconds } catch { $st = [int64]0 }
            }
          }
        }
      }
      if ($tx -eq '') { continue }
      @{ session = $s; text = $tx; sentAt = $st }
    }
  }
  # true when the preview / message text is our own recently sent text coming back.
  function Test-Echo([string]$session, [string]$preview, $outbox) {
    if ([string]::IsNullOrWhiteSpace($preview)) { return $false }
    $now = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    $window = 600000   # 10 minutes
    $p = ($preview -replace '^\[[^\]]*\]\s*', '').Trim()
    foreach ($e in @($outbox)) {
      if ($null -eq $e) { continue }
      $tx = ('' + $e['text']).Trim()
      if ($tx -eq '') { continue }
      $st = [int64]($e['sentAt'])
      if ($st -gt 0 -and (($now - $st) -gt $window)) { continue }
      $es = '' + $e['session']
      if ($es -ne '' -and $es -ne $session) { continue }
      if ($p -eq $tx) { return $true }
      # long text is shortened by WeChat to "abc..." with a single ellipsis char
      if ($p.EndsWith([string][char]0x2026) -or $p.EndsWith('...')) {
        $core = $p.TrimEnd([char]0x2026).TrimEnd('.')
        if ($core.Length -ge 8 -and $tx.StartsWith($core)) { return $true }
      }
      if ($p.Length -ge 12 -and $tx.Length -gt $p.Length -and $tx.StartsWith($p)) { return $true }
    }
    return $false
  }
  # group hint from the chat history: a group shows "sender: text" lines, a 1:1 does not.
  function Get-KindHint($texts, $outbox, [string]$session) {
    $colon = [char]0xFF1A
    $pat = '^([^\s' + $colon + ':]{1,4})[' + $colon + ':]\s?\S'
    $hits = 0
    foreach ($tx in @($texts)) {
      if ([string]::IsNullOrWhiteSpace($tx)) { continue }
      if (Test-Echo $session $tx $outbox) { continue }
      $m = [regex]::Match($tx, $pat)
      if (-not $m.Success) { continue }
      $pfx = $m.Groups[1].Value
      if ($pfx -match '^(https?|www|ftp)$') { continue }
      if ($pfx -match '^\d+$') { continue }
      # bare timestamps ("15:31") look like "sender: text" to the regex, so drop them first
      if ($tx.Trim() -match '^(\d{1,2}[:：]\d{2}|\d{4}[-/]\d{1,2}[-/]\d{1,2}( \d{1,2}[:：]\d{2}([:：]\d{2})?)?)$') { continue }
      $hits++
    }
    if ($hits -ge 2) { return 'group' }
    if ($hits -eq 0) { return 'private' }
    return 'unknown'
  }
  # ---- session list: wheel scrolling + unread red badge -----------------------------
  # WM_MOUSEWHEEL lParam is SCREEN coordinates, unlike WM_MOUSEMOVE/WM_LBUTTONDOWN where it is
  # client coordinates. Measured on this build: posting the ScreenToClient() point is silently
  # dropped (0 rows move), the screen point scrolls exactly one 65 px row per 120 units. The
  # message is posted to the top-level window, so the cursor never moves and focus is untouched.
  # session_list has NO ScrollPattern (TryGetCurrentPattern returns false), the wheel is the only
  # way to reach the ~55 rows; un-scrolled reads only ever see the rows the user scrolled to.
  $script:WheelPoint  = [IntPtr]::Zero
  $script:WheelAnchor = ''
  $script:WheelX = 0
  $script:WheelY = 0
  function Get-ListWheelPoint {
    $list = Find-List 'session_list' $L_SESS
    if ($list -eq $null) { throw "sessions-list-not-found: no List named '$L_SESS'" }
    $r = $list.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { throw 'session-list-has-no-area (minimised or offscreen?)' }
    $x = [int]($r.X + $r.Width / 2)
    # 55% down the viewport: the bottom strip of ChatSessionList is covered by the
    # 「折叠置顶聊天」 bar once pinned chats overflow, and a wheel posted over that bar is
    # swallowed (the list looked frozen). The middle of the viewport is always a real row.
    $y = [int]($r.Y + $r.Height * 0.55)
    $script:WheelPoint  = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
    $script:WheelAnchor = $x.ToString() + ',' + $y.ToString()
    $script:WheelX = $x
    $script:WheelY = $y
    return $script:WheelAnchor
  }
  function Send-ListWheel([int]$delta) {
    $hwnd = Get-RootHwnd
    if ($script:WheelPoint -eq [IntPtr]::Zero) { [void](Get-ListWheelPoint) }
    # Qt routes a wheel message to the widget under the pointer position it last saw. With the
    # real cursor parked over another window (the user, or our own GUI), a lone posted
    # WM_MOUSEWHEEL is silently dropped and the list looks frozen. A posted WM_MOUSEMOVE puts
    # the synthetic pointer on the list first - no cursor movement, no hover state to clean up.
    try {
      $pt = New-Object WxCtl32+POINT
      $pt.X = [int]$script:WheelX
      $pt.Y = [int]$script:WheelY
      [void][WxCtl32]::ScreenToClient($hwnd, [ref]$pt)
      $mlp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
      [void][WxCtl32]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, $mlp)
    } catch { }
    $wp = [IntPtr](([int]$delta) -shl 16)
    [void][WxCtl32]::PostMessage($hwnd, 0x020A, $wp, $script:WheelPoint)
  }
  function Get-FirstSessionName {
    $items = @(Get-SessionItems)
    if ($items.Count -eq 0) { return '' }
    $sp = Split-SessionName $items[0].Current.Name
    return $sp.title
  }
  # One row per visible session, badges included. The caller passes ONE window bitmap that is
  # reused for every row (PrintWindow costs ~20 ms; a per-row capture would cost 12x that and
  # could tear between rows). $bmp = $null simply skips the badge pass (-NoBadge).
  function Read-SessionRows($bmp, [int]$stripW = 80) {
    $hwnd = Get-RootHwnd
    $rows = @()
    foreach ($it in @(Get-SessionItems)) {
      $cls = ''
      try { $cls = [string]$it.Current.ClassName } catch { }
      $r  = $it.Current.BoundingRectangle
      $rawName = ''
      try { $rawName = [string]$it.Current.Name } catch { }
      $sp = Split-SessionName $rawName
      # 有未读时微信把 Name 里的「消息免打扰」整行抹掉（实测同一群 17:35/17:46 不一致），
      # 所以这一项只是「无未读时可信」的正向证据，false 不能当成「不是免打扰」。
      $mutedMark = ($rawName -match $L_MUTED)
      # the collapsed 已置顶 bar has an empty Name and is not a chat: key it separately
      $isFold = ($cls -match 'StickyFold')
      if ([string]::IsNullOrWhiteSpace($sp.title)) { $isFold = $true }
      $badgePx = 0; $badgeTight = 0; $redRatio = 0; $area = 0; $box = ''; $badgeZone = $false
      $badgeWhitePx = 0; $badgeWhiteSoftPx = 0; $badgeWhiteRatio = 0.0; $badgeDigit = $false
      $bbx = -1; $bby = -1; $bbw = 0; $bbh = 0
      $rowH = [int]$r.Height
      if ($bmp -ne $null -and $r.Width -gt 0 -and $rowH -gt 0) {
        try {
          $rc = [WxShot]::ScreenRectToBitmap($hwnd, [int]$r.X, [int]$r.Y, [int]$r.Width, $rowH)
          $st = [WxShot]::RedBadge($bmp, $rc[0], $rc[1], $stripW, $rc[3])
          $badgePx    = [int]$st[0]
          $badgeTight = [int]$st[1]
          $area       = [int]$st[6]
          if ([int]$st[9] -gt 0) {
            $bx = [int]$st[11]; $by = [int]$st[12]; $bw = [int]$st[9]; $bh = [int]$st[10]
            # $bx/$by are the component CENTROID; the digit window must start at the bbox origin (st[7]/st[8]).
            $bbx = $rc[0] + [int]$st[7]; $bby = $rc[1] + [int]$st[8]; $bbw = $bw; $bbh = $bh
            $box = $bx.ToString() + ',' + $by.ToString() + ' ' + $bw.ToString() + 'x' + $bh.ToString()
            # zone test: a real unread badge sits on the avatar's TOP-RIGHT corner. Measured on
            # badged rows land on "47,13 8x8" (numeric 15x15, muted 8x8) in an avatar spanning ~12..52 px;
            # the rejects were "67,22" (x past the avatar = red glyphs in the name column) and
            # "23,37" (low centre of the avatar = a red icon inside the artwork).
            $badgeZone = ($bx -ge 28 -and $bx -le 64 -and $by -ge 2 -and $by -le 32 -and $bw -le 18 -and $bh -le 18)
          }
          $den = $stripW * $rowH
          if ($den -gt 0) { $redRatio = [Math]::Round($badgePx / [double]$den, 4) }
        } catch { }
      }
      # badgePx alone is not enough: a sunset avatar scored 77 and a red-packet avatar 102 hard
      # pixels while carrying no badge. A real badge is a compact #FA5151 disc (fill colour,
      # <= 26 px box, >= 25 px area) at the avatar top-right; the component test rejects the
      # wide blobs those avatars produce, without a hand-tuned ROI.
      $unread = ($badgePx -ge 40 -and $badgeTight -ge 25 -and $area -ge 25 -and $badgeZone)
      # ---- muted chat (消息免打扰) --------------------------------------------
      # Numeric badges measure 15x15, muted/service dots 8x8 (both at "47,13"); the white
      # digit is punched into the disc. A muted chat keeps the red disc but the digit is
      # gone. Measured 2026-11-11: digit "1" -> 10 bright hole px; five pure dots -> 0.
      # Threshold: bright hole >= 3 (digit glyphs are 2-10 px; a dot has no hole at all).
      if ($unread -and $bmp -ne $null -and $bbw -gt 0) {
        try {
          $wt = [WxShot]::BadgeWhite($bmp, $bbx, $bby, $bbw, $bbh, 2)
          $badgeWhitePx     = [int]$wt[0]
          $badgeWhiteSoftPx = [int]$wt[1]
          if ([int]$wt[3] -gt 0) { $badgeWhiteRatio = [Math]::Round($badgeWhitePx / [double]$wt[3], 3) }
          $badgeDigit = ($badgeWhitePx -ge 3)
        } catch { }
      }
      # ---- muted bell: 行右侧、时间下方那枚带斜杠的小铃铛（中性灰）------------
      # 免打扰行在预览文字右侧留出一列：x ∈ [W-40, W-6]、y ∈ [0.45H, H-2]。
      # 阈值来自真机实测（见 RESUME.md）：命中 >= 8 个中性灰像素算有铃铛。
      $mutedByBell = $false
      $bellPx = 0
      $bellBox = ''
      $bellNear = 0
      if ($bmp -ne $null -and $r.Width -gt 60 -and $rowH -gt 24) {
        try {
          $bx0 = [int]$r.X + [int]$r.Width - 40
          $by0 = [int]$r.Y + [int]($rowH * 0.45)
          $bw0 = 34
          $bh0 = [int]($rowH - [int]($rowH * 0.45) - 2)
          $rc3 = [WxShot]::ScreenRectToBitmap($hwnd, $bx0, $by0, $bw0, $bh0)
          $ng = [WxShot]::NeutralGray($bmp, $rc3[0], $rc3[1], $rc3[2], $rc3[3], 18, 110, 190)
          $bellPx = [int]$ng[0]
          $blobW = 0; $blobH = 0
          if ($bellPx -gt 0) {
            $blobW = [int]$ng[6] - [int]$ng[4] + 1
            $blobH = [int]$ng[7] - [int]$ng[5] + 1
          }
          # A bell is a compact glyph; text reaching the same column paints a wide flat smear.
          # Measured on the real list (see RESUME.md): bell 9..12 px wide, 8..12 high.
          $mutedByBell = ($bellPx -ge 12 -and $blobW -ge 5 -and $blobW -le 16 -and $blobH -ge 5 -and $blobH -le 16)
          $bellBox = ($bx0.ToString() + ',' + $by0.ToString() + ' ' + $bw0.ToString() + 'x' + $bh0.ToString() + ' blob=' + $blobW.ToString() + 'x' + $blobH.ToString())
        } catch { }
      }
      $note = $null
      if ($unread) { $note = 'unread-by-badge' }
      if ($mutedByBell) { $note = $(if ($note -eq $null) { 'muted-by-bell' } else { $note + ';muted-by-bell' }) }
      $rows += [pscustomobject]@{
        name       = $sp.title
        title      = $sp.title
        preview    = $sp.preview
        time       = $sp.time
        pinned     = $sp.pinned
        foldBar    = $isFold
        cls        = $cls
        aid        = $(if ($isFold) { '' } else { [string]$it.Current.AutomationId })
        selected   = (Get-IsSelected $it)
        y          = [int]$r.Y
        h          = $rowH
        unread     = $unread
        badgePx    = $badgePx
        badgeTight = $badgeTight
        badgeBox   = $box
        badgeZone  = $badgeZone
        redRatio   = $redRatio
        badgeWhitePx     = $badgeWhitePx
        badgeWhiteSoftPx = $badgeWhiteSoftPx
        badgeWhiteRatio  = $badgeWhiteRatio
        badgeDigit       = $badgeDigit
        mutedByName      = $mutedMark
        mutedByBell      = [bool]$mutedByBell
        bellPx           = $bellPx
        bellBox          = $bellBox
        note       = $note
        visible    = $true
        yStale     = $false
      }
    }
    return $rows
  }
  # Merges one view into the accumulator. Keyed by title because the list reorders live (a chat
  # that just got a message jumps to the top) and index/session_item_N ids are not stable.
  function Add-SessionView($map, $order, $view) {
    foreach ($rr in @($view)) {
      $k = $rr.name
      if ($rr.foldBar) { $k = '<fold>' }
      if (-not $map.ContainsKey($k)) { [void]$order.Add($k) }
      $map[$k] = $rr
    }
  }
  # A minimized WeChat still exposes a complete (stale) UIA tree, so probe would happily
  # report rows and y coordinates while every posted wheel message lands as a no-op - the
  # list looks frozen and a scroll walk silently returns the 12 rows of the last layout.
  # Restore it (SW_RESTORE + the known-good geometry) before any capture or wheel post.
  # Only the main window is touched: the pinned fold bar is never clicked.
  function Restore-WindowForCapture {
    $hwnd = [IntPtr]::Zero
    try { $hwnd = Get-RootHwnd } catch { return $false }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $did = $false
    if ([WxCtl32]::IsIconic($hwnd)) {
      [void][WxCtl32]::ShowWindow($hwnd, 9)
      Start-Sleep -Milliseconds 400
      $did = $true
    }
    if (-not [WxCtl32]::IsWindowVisible($hwnd)) {
      [void][WxCtl32]::ShowWindow($hwnd, 5)
      Start-Sleep -Milliseconds 400
      # The UIA tree of a hidden window has no children, so the cached root cannot see the
      # session list. Drop it and resolve again now that the window is on screen.
      $script:Root = $null; $script:RootHwnd = [IntPtr]::Zero; $script:RootPick = $null
      try { [void](Get-Root) } catch { }
      $did = $true
    }
    if ([WxCtl32]::IsOffScreen($hwnd)) {
      try {
        [void][WxCtl32]::MoveOnScreen($hwnd, 220, 288, 879, 919)
        Start-Sleep -Milliseconds 300
        $did = $true
      } catch { }
    }
    if ($did) { $script:RestoredWindow = $true; Start-Sleep -Milliseconds 150 }
    return $did
  }
  # Full-list walk: settle at the TOP first, wheel down until 2 consecutive passes add no new
  # title (max 20), then wheel back to the top so every y returned by a later Find-Session is
  # trustworthy again. $firstBmp lets the caller donate the bitmap it already captured.
  # Coarse "go to the top": 1200 units = 10 rows per pass, so the 55-row list is ~6 passes
  # away. Stops as soon as the first title stops changing (already at the top = one wasted pass).
  function Scroll-ListToTop([int]$settleMs = 200, [int]$maxPasses = 30) {
    $passes = 0
    $stable = $false
    while ($passes -lt $maxPasses) {
      $before = Get-FirstSessionName
      Send-ListWheel 1200
      Start-Sleep -Milliseconds $settleMs
      $passes++
      $after = Get-FirstSessionName
      # a 10-row wheel step that changes nothing can only mean the list is clamped at the top.
      # Comparing names is not enough on its own: a chat that just received a message can
      # reorder the head of the list while we are already sitting at the top.
      if ($after -eq $before) { $stable = $true; break }
    }
    return [pscustomobject]@{ passes = $passes; stable = $stable }
  }
  # Full-list walk. Normalises to the TOP first (otherwise the collection starts at whichever
  # slice the user left on screen), wheels down until 2 consecutive passes add no new title
  # (max 20), then goes back to the top and re-reads it, so every y a later Find-Session sees
  # belongs to the unscrolled list. $firstBmp lets the caller donate a bitmap it already has.
  function Scroll-SessionList($firstBmp, [int]$passDelta = -360, [int]$settleMs = 250, [int]$maxPasses = 20, [int]$noNewLimit = 2) {
    [void](Restore-WindowForCapture)
    [void](Get-ListWheelPoint)
    $map   = @{}
    $order = New-Object System.Collections.ArrayList
    $captures = 0; $capMs = 0; $method = ''
    $passes = 0; $noNew = 0; $upPasses = 0; $atTop = $false
    $topInfo = Scroll-ListToTop 200
    $topPasses = $topInfo.passes
    $bmp = $firstBmp
    if ($bmp -eq $null) {
      $t = [System.Diagnostics.Stopwatch]::StartNew()
      try { $bmp = [WxShot]::Grab((Get-RootHwnd), [ref]$method) } catch { $bmp = $null }
      $capMs += [int]$t.ElapsedMilliseconds; $captures++
    }
    Add-SessionView $map $order @(Read-SessionRows $bmp)
    $first0 = ''
    if ($order.Count -gt 0) { $first0 = $map[$order[0]].name }
    $prevKey = (@($order | ForEach-Object { $map[$_].title }) -join '|')
    if ($bmp -ne $firstBmp -and $bmp -ne $null) { try { $bmp.Dispose() } catch { } }
    # every pass re-reads the freshly scrolled view: a badge must come from the frame that shows
    # that row, so one capture per pass, never one per row.
    for ($i = 0; $i -lt $maxPasses; $i++) {
      Send-ListWheel $passDelta
      Start-Sleep -Milliseconds $settleMs
      $nb = $null; $method = ''
      $t = [System.Diagnostics.Stopwatch]::StartNew()
      try { $nb = [WxShot]::Grab((Get-RootHwnd), [ref]$method) } catch { $nb = $null }
      $capMs += [int]$t.ElapsedMilliseconds; $captures++
      $view = @(Read-SessionRows $nb)
      if ($nb -ne $null) { try { $nb.Dispose() } catch { } }
      $before = $map.Count
      Add-SessionView $map $order $view
      $passes++
      if (($map.Count - $before) -le 0) { $noNew++ } else { $noNew = 0 }
      # the wheel clamps at the bottom: an identical view means nothing moved, so we are there
      $viewKey = (@($view | ForEach-Object { $_.title }) -join '|')
      $clamped = ($viewKey -eq $prevKey)
      $prevKey = $viewKey
      if ($noNew -ge $noNewLimit -or $clamped) { break }
    }
    # ---- back to the top: later Find-Session y coordinates must be valid again ----
    # No name-equality fine-tuning here: the head of the list reorders live, so chasing a
    # remembered first name burns passes forever. "The 10-row step moved nothing" is the real
    # proof of being clamped at the top.
    $upMax = [Math]::Max(30, ($passes * 2) + 10)
    $upInfo = Scroll-ListToTop $settleMs $upMax
    $upPasses = $upInfo.passes
    $atTop = $upInfo.stable
    # authoritative final read at the top: fresh y coordinates + badges for the visible rows
    $fb = $null; $method = ''
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    try { $fb = [WxShot]::Grab((Get-RootHwnd), [ref]$method) } catch { $fb = $null }
    $capMs += [int]$t.ElapsedMilliseconds; $captures++
    $finalView = @(Read-SessionRows $fb)
    if ($fb -ne $null) { try { $fb.Dispose() } catch { } }
    Add-SessionView $map $order $finalView
    # only rows present in the final top view have an authoritative y; the rest carry the y of
    # the pass that happened to show them, which a later click must NOT trust.
    $topNames = @{}
    foreach ($v in $finalView) { if ($v.title) { $topNames[$v.title] = $true } }
    $rows = @()
    foreach ($k in $order) {
      $r = $map[$k]
      if ($r.title -and $topNames.ContainsKey($r.title)) { $r.visible = $true; $r.yStale = $false }
      else { $r.visible = $false; $r.yStale = $true }
      $rows += $r
    }
    $chats = @($rows | Where-Object { -not $_.foldBar })
    $firstAtEnd = ''
    if ($finalView.Count -gt 0) { $firstAtEnd = $finalView[0].name }
    return [pscustomobject]@{
      rows           = $rows
      scrolled       = ($passes -gt 0)
      scrollPasses   = $passes
      scrollUpPasses = $upPasses
      topPasses      = $topPasses
      totalSessions  = $rows.Count
      chatCount      = $chats.Count
      atTop          = $atTop
      firstAtStart   = $first0
      firstAtEnd     = $firstAtEnd
      captures       = $captures
      captureMs      = $capMs
      wheelPoint     = $script:WheelAnchor
    }
  }
  # ---- the collapsed 已置顶 bar ------------------------------------------------------
  # ClassName mmui::ChatStickyFoldCell, empty Name/AutomationId, ~48 px tall. It is virtualised:
  # scrolled out of view it is not in the UIA tree at all, so an off-screen bar cannot be
  # reported (with the pinned group expanded the 12 visible rows usually push it just below).
  function Get-FoldBarItem {
    $list = Find-List 'session_list' $L_SESS
    if ($list -eq $null) { return $null }
    foreach ($it in @(Get-Children $list)) {
      $cls = ''
      try { $cls = [string]$it.Current.ClassName } catch { }
      if ($cls -match 'StickyFold') { return $it }
    }
    return $null
  }
  # Toggling the pinned fold area changes the user's UI state, so it is NEVER implicit: probe
  # only calls this with -AllowFoldToggle and only when the bar itself is badged.
  function Invoke-FoldBarToggle([int]$settleMs = 700) {
    $hwnd = Get-RootHwnd
    $bar = Get-FoldBarItem
    if ($bar -eq $null) { throw 'fold-bar-not-found: no visible child with ClassName ~ ChatStickyFoldCell' }
    $r = $bar.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { throw 'fold-bar-has-no-area' }
    $sx = [int]($r.X + 30)                    # 30 px left of centre: away from the chevron
    $sy = [int]($r.Y + $r.Height / 2)
    $pt = New-Object WxCtl32+POINT
    $pt.X = $sx; $pt.Y = $sy
    [void][WxCtl32]::ScreenToClient($hwnd, [ref]$pt)
    $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    [void][WxCtl32]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, $lp)
    Start-Sleep -Milliseconds 60
    [void][WxCtl32]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp)
    Start-Sleep -Milliseconds 40
    [void][WxCtl32]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, $lp)
    Start-Sleep -Milliseconds $settleMs
    return ($sx.ToString() + ',' + $sy.ToString())
  }
  # ============================== MODE: preflight ==============================
  # Switch the chat and report what a send would target. NEVER writes the input box.
  if ($Mode -eq 'preflight') {
    if ([string]::IsNullOrWhiteSpace($Session)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Session is required for -Mode preflight'; ms = (Get-Ms) }) 1
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectSession) -and $ExpectSession -ne $Session) {
      Write-Result ([ordered]@{
        ok = $false; error = ("expect-session-mismatch: -ExpectSession '$ExpectSession' vs -Session '$Session'")
        session = $Session; ms = (Get-Ms)
      }) 1
    }
    $obRows = @(Get-Outbox (Resolve-OutboxPath))
    $target = Find-Session $Session
    if ($target -eq $null) {
      Write-Result ([ordered]@{ ok = $false; error = "session-not-found: '$Session'"; session = $Session; ms = (Get-Ms) }) 1
    }
    $selMethod = Select-Session $target $Session
    $editName  = Get-ChatNameOfEdit
    if ($editName -ne $Session) {
      Write-Result ([ordered]@{
        ok = $false; error = "session-switch-failed: chat is still '$editName' but '$Session' was requested"
        session = $Session; editName = $editName; selectMethod = $selMethod; ms = (Get-Ms)
      }) 1
    }
    $msg   = Get-Messages 5 $null
    $texts = @($msg.rows | ForEach-Object { $_.text })
    # Kind: the title bar is the strong signal (a group renders "群名(成员数)", a
    # 1:1 chat renders just the name). Only a high-confidence real title-bar read
    # may decide "private" - the fallback (chat_input Name) never carries the
    # count, so trusting it blindly would label every group as a private chat.
    $ti = Get-ChatTitleInfo
    $kindSource = 'preview'
    $kindHint = $null
    if ($ti.source -eq 'titlebar' -and -not [string]::IsNullOrWhiteSpace($ti.title) -and $ti.confidence -eq 'high') {
      $kindHint = $(if ($ti.isGroup) { 'group' } else { 'private' })
      $kindSource = 'title'
    } else {
      $kindHint = Get-KindHint $texts $obRows $Session
    }
    Write-Result ([ordered]@{
      ok           = $true
      session      = $Session
      editName     = $editName
      selectMethod = $selMethod
      restoredWindow = [bool]$script:RestoredWindow
      movedOnScreen  = [bool]$script:MovedOnScreen
      total        = $msg.total
      kindHint     = $kindHint
      kindSource   = $kindSource
      chatTitle    = $ti.title
      isGroupTitle = [bool]$ti.isGroup
      titleKindConfidence = $ti.confidence
      titleSource  = $ti.source
      titleReason  = $ti.reason
      titleElement = $ti.element
      tail         = $texts
      inputTouched = $false
      ms           = (Get-Ms)
    }) 0
  }
  # ============================== MODE: probe ==============================
  # Lightweight poll: session title + preview + time + selected + kind. No clicking, no writes.
  if ($Mode -eq 'probe') {
    $cachePath = $KindCache
    if ([string]::IsNullOrWhiteSpace($cachePath) -and -not [string]::IsNullOrWhiteSpace($Out)) {
      $cachePath = Join-Path (Split-Path -Parent $Out) 'wx_kind_cache.json'
    }
    # The cache is READ-ONLY for the probe: it only carries group titles that were confirmed
    # out of band (e.g. by the caller through the contacts/group list). Auto-learning from the
    # preview text was removed on purpose: our own message "A:B" looks exactly like a group
    # preview, so learning would permanently label that 1:1 chat as a group.
    $cache  = Get-KindCache $cachePath
    $outboxPath = Resolve-OutboxPath
    $obRows = @(Get-Outbox $outboxPath)
    # ---- one window capture, then (optionally) walk the whole list ----------------
    # PrintWindow(PW_RENDERFULLCONTENT) costs ~20 ms and returns the entire window, so ONE
    # bitmap serves every visible row: an unread badge is just a crop of the row's left 80 px
    # strip. Per-row captures would cost 12x that and could tear between rows.
    [void](Restore-WindowForCapture)
    $cap = $null; $capMethod = ''; $capErr = $null
    $tCap = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $NoBadge) {
      try { $cap = [WxShot]::Grab((Get-RootHwnd), [ref]$capMethod) } catch { $capErr = '' + $_.Exception.Message }
    }
    $capMs = [int]$tCap.ElapsedMilliseconds
    if ($ShotPath -ne '' -and $cap -ne $null) {
      try { $cap.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png) }
      catch { $capErr = ('' + $capErr) + ' shot-save-failed: ' + $_.Exception.Message }
    }
    # -Scroll normalises to the top first, walks the list and returns to the top, so the result
    # is the whole list instead of whichever slice the user happened to leave on screen.
    $scrollInfo = $null
    if ($Scroll) {
      $scrollInfo = Scroll-SessionList $cap $ScrollDelta $ScrollSettleMs $MaxScrollPasses
      $raw = @($scrollInfo.rows)
      $capMs  = $scrollInfo.captureMs
      $capMethod = 'per-view'
    } else {
      $raw = @(Read-SessionRows $cap)
    }
    if ($cap -ne $null) { try { $cap.Dispose() } catch { } ; $cap = $null }
    $rows = @()
    foreach ($it in $raw) {
      $pfx  = Get-PreviewPrefix $it.preview
      $echo = Test-Echo $it.name $it.preview $obRows
      $kind = Get-PreviewKind $it.preview
      $src  = 'preview'
      $note = $it.note
      if ($echo) {
        # our own message coming back: never inbound, and it must not vote on the kind
        $kind = 'unknown'; $src = 'echo-suppressed'
        $note = 'echo of a message we sent within the last 10 minutes (outbox)'
      } elseif ($it.name -ne '' -and $cache.ContainsKey($it.name) -and $cache[$it.name] -eq 'group') {
        $kind = 'group'; $src = 'cache'
      } elseif ($kind -eq 'group') {
        $hint = 'sender prefix "' + $pfx + '" - verify before trusting (our own message text can look the same)'
        if ([string]::IsNullOrEmpty($note)) { $note = $hint } else { $note = $hint + '; ' + $note }
      }
      $rows += [pscustomobject]@{
        name       = $it.name
        title      = $it.title
        preview    = $it.preview
        time       = $it.time
        selected   = $it.selected
        kind       = $kind
        kindSource = $src
        echo       = $echo
        senderHint = $pfx
        unread     = $it.unread
        badgePx    = $it.badgePx
        badgeTight = $it.badgeTight
        badgeBox   = $it.badgeBox
        badgeZone  = $it.badgeZone
        redRatio   = $it.redRatio
        badgeWhitePx     = $it.badgeWhitePx
        badgeWhiteSoftPx = $it.badgeWhiteSoftPx
        badgeWhiteRatio  = $it.badgeWhiteRatio
        badgeDigit       = $it.badgeDigit
        mutedByName      = $it.mutedByName
        mutedByBell      = $it.mutedByBell
        bellPx           = $it.bellPx
        bellBox          = $it.bellBox
        foldBar    = $it.foldBar
        cls        = $it.cls
        note       = $note
        aid        = $it.aid
        pinned     = $it.pinned
        y          = $it.y
        visible    = $(if ($null -ne $it.visible) { [bool]$it.visible } else { $true })
        yStale     = $(if ($null -ne $it.yStale) { [bool]$it.yStale } else { $false })
        lastDir    = $null
      }
    }
    $unreadRows = @($rows | Where-Object { $_.unread })
    $foldRow = $null
    foreach ($r0 in $rows) { if ($r0.foldBar) { $foldRow = $r0; break } }
    $foldNote = $null
    if ($foldRow -eq $null) {
      $foldNote = 'fold-bar-not-in-view: the 已置顶 bar is virtualised out of the UIA tree when scrolled away'
    }
    # Expand-probe-collapse, opt-in only: the user asked for the fold state to be left alone, so
    # this runs only on -AllowFoldToggle AND only when the bar itself carries a badge.
    $foldToggle = $null
    if ($AllowFoldToggle) {
      $foldToggle = [ordered]@{
        attempted = $false; expanded = $false; collapsedBack = $false
        point = $null; error = $null; pinnedCount = 0; pinnedUnread = @()
      }
      if ($foldRow -eq $null) {
        $foldToggle.error = 'fold-bar-not-in-view'
      } elseif (-not $foldRow.unread) {
        $foldToggle.error = 'fold-bar-not-badged: expansion is only allowed for a badged bar'
      } else {
        $foldToggle.attempted = $true
        try {
          $foldToggle.point = Invoke-FoldBarToggle 700
          $foldToggle.expanded = $true
          $b2 = $null; $m2 = ''
          try { $b2 = [WxShot]::Grab((Get-RootHwnd), [ref]$m2) } catch { }
          $pin = @(Read-SessionRows $b2)
          if ($b2 -ne $null) { try { $b2.Dispose() } catch { } }
          $foldToggle.pinnedCount = $pin.Count
          $foldToggle.pinnedUnread = @($pin | Where-Object { $_.unread } | ForEach-Object {
            [ordered]@{ name = $_.name; preview = $_.preview; time = $_.time; badgePx = $_.badgePx; badgeTight = $_.badgeTight; badgeBox = $_.badgeBox }
          })
        } catch { $foldToggle.error = '' + $_.Exception.Message }
        try {
          [void](Invoke-FoldBarToggle 700)
          $foldToggle.collapsedBack = $true
        } catch {
          $e2 = 'collapse-failed: ' + $_.Exception.Message
          if ([string]::IsNullOrEmpty([string]$foldToggle.error)) { $foldToggle.error = $e2 } else { $foldToggle.error = $foldToggle.error + '; ' + $e2 }
        }
      }
    }
    $res = [ordered]@{ ok = $true; count = $rows.Count; cachePath = $cachePath; outboxPath = $outboxPath; outboxRows = $obRows.Count; ms = (Get-Ms) }
    $res['unreadCount']  = $unreadRows.Count
    $res['unreadNames']  = @($unreadRows | ForEach-Object { $_.name })
    $res['badgeCapture'] = $(if ($capErr -ne $null) { $capErr } else { $capMethod })
    $res['captureMs']    = $capMs
    $res['window']       = $script:RootPick
    $res['totalSessions'] = $rows.Count
    $res['restoredWindow'] = [bool]$script:RestoredWindow
    $res['foldBar']      = $foldRow
    $res['foldNote']     = $foldNote
    $res['scroll']       = $null
    if ($scrollInfo -ne $null) {
      $res['scroll'] = [ordered]@{
        scrolled       = $scrollInfo.scrolled
        scrollPasses   = $scrollInfo.scrollPasses
        scrollUpPasses = $scrollInfo.scrollUpPasses
        topPasses      = $scrollInfo.topPasses
        totalSessions  = $scrollInfo.totalSessions
        chatCount      = $scrollInfo.chatCount
        atTop          = $scrollInfo.atTop
        scrollRestored = $scrollInfo.atTop
        firstAtStart   = $scrollInfo.firstAtStart
        firstAtEnd     = $scrollInfo.firstAtEnd
        captures       = $scrollInfo.captures
        captureMs      = $scrollInfo.captureMs
        wheelPoint     = $scrollInfo.wheelPoint
      }
    }
    if ($AllowFoldToggle) { $res['foldToggle'] = $foldToggle }
    $res['sessions'] = $rows
    Write-Result $res 0
  }
  # ============================== MODE: watch ==============================
  # One-minute away-mode poll. The user's resting state is "pinned area COLLAPSED", so the
  # viewport is the fold bar plus the non-pinned chats: a new message in a pinned chat can then
  # only surface as a badge on the fold bar, which the caller expands on demand. Read-only
  # except for that fold toggle, which the user explicitly asked for as the default state.
  # Budget: a couple of wheel posts + two UIA reads, well under 1.5 s once the list is at rest.
  if ($Mode -eq 'watch') {
    $restored = [bool](Restore-WindowForCapture)
    [void](Get-ListWheelPoint)
    $foldToggle = $null
    $reads = 0
    $capMethod = ''
    # One capture -> all 12 visible rows. PrintWindow is ~10 ms; the UIA tree read dominates.
    $readView = {
      $b = $null; $m = ''
      $t = [System.Diagnostics.Stopwatch]::StartNew()
      try { $b = [WxShot]::Grab((Get-RootHwnd), [ref]$m) } catch { $b = $null }
      if ($ShotPath -ne '' -and $b -ne $null) {
        try { $b.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
      }
      $capMsLocal = [int]$t.ElapsedMilliseconds
      $v = @()
      if ($b -ne $null) { try { $v = @(Read-SessionRows $b) } finally { $b.Dispose() } }
      [pscustomobject]@{ view = $v; captureMs = $capMsLocal; method = $m }
    }
    # "collapsed" = the fold bar sits at the very top with no pinned chat under it.
    # "expanded"  = pinned chats are listed first (the bar is then just below the viewport).
    # Measured layouts (879x919 window, 12 rows of 65 px):
    #   collapsed -> [maybe 1 pinned row] + fold bar near the top + non-pinned rows after it
    #   expanded  -> pinned rows fill the viewport and the bar sits at the END of that block
    # So the discriminator is "how many pinned rows are above the bar", not just "is it seen".
    $stateOf = {
      param($v)
      $bi = -1
      for ($i = 0; $i -lt $v.Count; $i++) { if ($v[$i].foldBar) { $bi = $i; break } }
      $pinnedAbove = 0; $pinnedTotal = 0
      for ($i = 0; $i -lt $v.Count; $i++) {
        if ($v[$i].pinned) { $pinnedTotal++; if ($bi -lt 0 -or $i -lt $bi) { $pinnedAbove++ } }
      }
      if ($bi -ge 0) {
        if ($pinnedAbove -le 2 -and $pinnedTotal -le 3) { return 'collapsed' }
        return 'expanded'
      }
      if ($pinnedTotal -gt 0) { return 'expanded' }
      return 'unknown'
    }
    $topInfo = Scroll-ListToTop 140 6
    if (-not $topInfo.stable) { $topInfo = Scroll-ListToTop 120 40 }
    $r1 = & $readView; $reads++
    $view = @($r1.view); $capMs = $r1.captureMs
    if ($r1.method) { $capMethod = $r1.method }
    $foldState = & $stateOf $view
    # ---- force the resting state: collapsed ----
    if ($foldState -ne 'collapsed' -and -not $NoFold) {
      $foldToggle = [ordered]@{ attempted = $false; point = $null; error = $null; before = $foldState; after = $foldState; passes = 0 }
      $barItem = $null
      try { $barItem = Get-FoldBarItem } catch { }
      # The bar is the LAST element of the pinned block and this user has ~50 pinned chats, so
      # it can be 40+ rows below the top; Qt only materialises it while it is on screen.
      # 6.5 rows per step (780) cannot skip a 48 px bar inside a 780 px viewport.
      for ($i = 0; $i -lt 10 -and $barItem -eq $null; $i++) {
        if ($i -gt 0) {
          Send-ListWheel -780
          Start-Sleep -Milliseconds 200
          $foldToggle['passes'] = $i
        }
        try { $barItem = Get-FoldBarItem } catch { }
      }
      if ($barItem -eq $null) {
        $foldToggle['error'] = 'fold-bar-not-visible'
      } else {
        $foldToggle['attempted'] = $true
        try { $foldToggle['point'] = Invoke-FoldBarToggle 300 }
        catch { $foldToggle['error'] = '' + $_.Exception.Message }
        [void](Scroll-ListToTop 140 6)
        $r2 = & $readView; $reads++
        $view = @($r2.view); $capMs = $r2.captureMs
        if ($r2.method) { $capMethod = $r2.method }
        $foldState = & $stateOf $view
        $foldToggle['after'] = $foldState
      }
      # whatever happened, leave the list where the caller expects it: at the top
      if ($foldState -ne 'collapsed') { [void](Scroll-ListToTop 140 8) }
    }
    # ---- project the viewport ----
    $rows = @()
    $barRow = $null
    foreach ($it in $view) {
      if ($it.foldBar -and $barRow -eq $null) { $barRow = $it }
      $rows += [ordered]@{
        name       = $it.name
        preview    = $it.preview
        time       = $it.time
        y          = $it.y
        pinned     = $it.pinned
        selected   = $it.selected
        foldBar    = $it.foldBar
        unread     = $it.unread
        badgePx    = $it.badgePx
        badgeTight = $it.badgeTight
        badgeBox   = $it.badgeBox
        badgeZone  = $it.badgeZone
        redRatio   = $it.redRatio
        badgeWhitePx     = $it.badgeWhitePx
        badgeWhiteSoftPx = $it.badgeWhiteSoftPx
        badgeWhiteRatio  = $it.badgeWhiteRatio
        badgeDigit       = $it.badgeDigit
        mutedByName      = $it.mutedByName
        mutedByBell      = $it.mutedByBell
        bellPx           = $it.bellPx
        bellBox          = $it.bellBox
      }
    }
    # The fold bar is a 48 px strip of stacked avatars, so the 65 px row zone test does not
    # apply: report its raw counts plus a coarse verdict the caller can check.
    $foldRow = [ordered]@{ visible = $false; y = -1; badgePx = 0; badgeTight = 0; badgeBox = ''; unread = $false }
    if ($barRow -ne $null) {
      $foldRow = [ordered]@{
        visible    = $true
        y          = $barRow.y
        badgePx    = $barRow.badgePx
        badgeTight = $barRow.badgeTight
        badgeBox   = $barRow.badgeBox
        unread     = ($barRow.badgePx -ge 40 -and $barRow.badgeTight -ge 25)
      }
    }
    $unreadRows = @($rows | Where-Object { $_.unread })
    # A surfaced pinned chat takes the y=368 slot and pushes the fold bar one row (65 px) down,
    # so "the first row" alone is ambiguous once the fold is involved: report the topmost badged
    # chat explicitly, ignoring the bar row (the bar carries no name and is never "unread" here).
    $topUnread = $null
    if ($unreadRows.Count -gt 0) {
      $topUnread = ($unreadRows | Sort-Object { [int]$_.y } | Select-Object -First 1).name
    }
    # Fallback signal for the chat that is OPEN: WeChat marks it read on arrival, so it never
    # grows a badge. The caller compares preview/time against the previous round.
    # NOTE: only rows inside the viewport can be reported here; a pinned chat swallowed by the
    # folded bar is invisible, which is why openChat (from the input field's Name) is also
    # reported - that one is always the currently open conversation.
    $chatOpen = $false
    try { $chatOpen = Test-ChatOpen } catch { }
    $selectedRow = $null
    $selRow = @($rows | Where-Object { $_.selected }) | Select-Object -First 1
    if ($chatOpen -and $selRow -ne $null) {
      $selectedRow = [ordered]@{ name = $selRow.name; preview = $selRow.preview; time = $selRow.time; unread = $selRow.unread }
    }
    $openChat = $null
    if ($chatOpen) { try { $openChat = Get-ChatNameOfEdit } catch { } }
    if ([string]::IsNullOrEmpty($openChat)) { $openChat = $null }
    $res = [ordered]@{
      ok             = $true
      mode           = 'watch'
      ms             = (Get-Ms)
      foldState      = $foldState
      foldRow        = $foldRow
      foldToggle     = $foldToggle
      restoredWindow = $restored
      atTop          = [bool]$topInfo.stable
      topPasses      = $topInfo.passes
      reads          = $reads
      captureMs      = $capMs
      window         = $script:RootPick
      badgeCapture   = $capMethod
      count          = $rows.Count
      unreadCount    = $unreadRows.Count
      unreadNames    = @($unreadRows | ForEach-Object { $_.name })
      topUnread      = $topUnread
      chatOpen       = [bool]$chatOpen
      selectedRow    = $selectedRow
      openChat       = $openChat
      rows           = $rows
    }
    Write-Result $res 0
  }
  # ============================== MODE: title ==============================
  # Read-only title probe for manual verification: report what the title bar says for the chat
  # the USER already has open. Touches nothing - no session switch, no click, no wheel, no
  # window restore, no capture - so it is safe to run while the user is working.
  if ($Mode -eq 'title') {
    $editName = $null
    try { $editName = Get-ChatNameOfEdit } catch { }
    $ti = Get-ChatTitleInfo
    Write-Result ([ordered]@{
      ok                  = $true
      mode                = 'title'
      editName            = $editName
      chatTitle           = $ti.title
      isGroupTitle        = [bool]$ti.isGroup
      titleCount          = $ti.count
      titleKindConfidence = $ti.confidence
      titleReason         = $ti.reason
      titleSource         = $ti.source
      titleElement        = $ti.element
      ms                  = (Get-Ms)
    }) 0
  }
  # ============================== MODE: list ==============================
  if ($Mode -eq 'list') {
    $rows = @()
    foreach ($it in @(Get-SessionItems)) {
      $r  = $it.Current.BoundingRectangle
      $sp = Split-SessionName $it.Current.Name
      $rows += [pscustomobject]@{
        name     = $it.Current.Name
        title    = $sp.title
        preview  = $sp.preview
        time     = $sp.time
        pinned   = $sp.pinned
        selected = (Get-IsSelected $it)
        y        = [int]$r.Y
      }
    }
    Write-Result ([ordered]@{ ok = $true; count = $rows.Count; ms = (Get-Ms); sessions = $rows }) 0
  }
  # ============================== MODE: deselect ==============================
  # Collapse the conversation panel so the window looks like "no chat selected" (the left list
  # plus the WeChat logo). Reason: WeChat marks the OPEN chat read the moment a message lands in
  # it, so a chat left open after a reply can never grow a red badge and badge detection is blind
  # to that person. Closing the panel restores the badge for everyone.
  # Success = chat_message_list disappears. Never sends, never writes the input box.
  if ($Mode -eq 'deselect') {
    $restored = Restore-WindowForCapture
    # -Idle：值守开始时把微信摆成用户期望的“闲置态”＝窗口在屏幕上、列表回到顶部、没有打开的会话。
    # 只在这一步抢一次前台，巡检期间不碰焦点。
    if ($Idle) {
      $ih = Get-RootHwnd
      if ($ih -ne [IntPtr]::Zero) {
        try { [void][WxCtl32]::ShowWindow($ih, 9) } catch { }
        try { [void][WxCtl32]::SetForegroundWindow($ih) } catch { }
        Start-Sleep -Milliseconds 250
        try { Scroll-ListToTop -settleMs 200 | Out-Null } catch { }
      }
    }
    $hwnd = Get-RootHwnd
    $wasOpen = Test-ChatOpen
    $before = $null
    try { $before = Get-ChatNameOfEdit } catch { }
    $method = $null
    $closed = (-not $wasOpen)
    # a) click the already-selected row again: WeChat toggles the panel shut
    if (-not $closed) {
      foreach ($it in @(Get-SessionItems)) {
        $cls = ''
        try { $cls = [string]$it.Current.ClassName } catch { }
        if ($cls -eq 'mmui::ChatStickyFoldCell') { continue }
        if (-not (Get-IsSelected $it)) { continue }
        try {
          [void](Click-ElementCenter $it)
          Start-Sleep -Milliseconds 600
        } catch { }
        if (-not (Test-ChatOpen)) { $closed = $true; $method = 'click-selected-row' }
        break
      }
    }
    # b) Esc
    if (-not $closed) {
      $lp = [IntPtr]0x00010001
      [void][WxCtl32]::PostMessage($hwnd, 0x0100, [IntPtr]0x1B, $lp)
      Start-Sleep -Milliseconds 80
      [void][WxCtl32]::PostMessage($hwnd, 0x0101, [IntPtr]0x1B, [IntPtr]0xC0010001)
      Start-Sleep -Milliseconds 500
      if (-not (Test-ChatOpen)) { $closed = $true; $method = 'escape' }
    }
    # c) click blank space at the bottom of the message area
    if (-not $closed) {
      try {
        $mc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'chat_message_list')
        $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $ml = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $mc)
        if ($ml -ne $null) {
          $r = $ml.Current.BoundingRectangle
          $bx = [int]($r.X + $r.Width / 2)
          $by = [int]($r.Y + $r.Height - 20)
          $pt = New-Object WxCtl32+POINT
          $pt.X = $bx; $pt.Y = $by
          [void][WxCtl32]::ScreenToClient($hwnd, [ref]$pt)
          $lp2 = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
          [void][WxCtl32]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, $lp2)
          Start-Sleep -Milliseconds 60
          [void][WxCtl32]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp2)
          Start-Sleep -Milliseconds 40
          [void][WxCtl32]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, $lp2)
          Start-Sleep -Milliseconds 600
          if (-not (Test-ChatOpen)) { $closed = $true; $method = 'click-blank' }
        }
      } catch { }
    }
    $after = $null
    try { $after = Get-ChatNameOfEdit } catch { }
    if ([string]::IsNullOrEmpty($after)) { $after = $null }
    $errOut = $null
    if (-not $closed) { $errOut = 'deselect-failed: chat_message_list is still present' }
    $res = [ordered]@{
      ok              = [bool]$closed
      mode            = 'deselect'
      changed         = [bool]($wasOpen -and $closed)
      method          = $method
      wasOpen         = [bool]$wasOpen
      chatOpen        = [bool](-not $closed)
      openChatBefore  = $before
      openChatAfter   = $after
      error           = $errOut
      restoredWindow  = [bool]$restored
      ms              = (Get-Ms)
    }
    if ($closed) { Write-Result $res 0 } else { Write-Result $res 1 }
  }
  # ============================== MODE: focus ==============================
  # Switch the open conversation and stop there: no transcript read, no input-box write,
  # no send, and no fold change. Needed after a reply, because WeChat marks the OPEN chat
  # read the instant a message lands in it: while the person we just answered stays open,
  # their next message never grows a red badge and badge-based detection is blind to it.
  # Moving the focus to a neutral chat (文件传输助手) restores the badge for them.
  if ($Mode -eq 'focus') {
    if ([string]::IsNullOrWhiteSpace($Session)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Session is required for -Mode focus'; ms = (Get-Ms) }) 1
    }
    $restored = Restore-WindowForCapture
    [void](Scroll-ListToTop 140 20)
    $passes = 0
    $found = $null
    $barSeen = $false
    for ($i = 0; $i -lt 14 -and $found -eq $null; $i++) {
      foreach ($it in @(Get-SessionItems)) {
        $cls = ''
        try { $cls = [string]$it.Current.ClassName } catch { }
        if ($cls -eq 'mmui::ChatStickyFoldCell') { $barSeen = $true; continue }
        $sp = Split-SessionName $it.Current.Name
        if ($sp.title -eq $Session) { $found = $it; break }
      }
      if ($found -eq $null -and $i -lt 13) {
        Send-ListWheel -780
        Start-Sleep -Milliseconds 170
        $passes++
      }
    }
    if ($found -eq $null) {
      $back = Scroll-ListToTop 140 40
      $err = 'session-not-visible: not found in the first ' + ($passes + 1) + ' screens of the list'
      if ($barSeen) { $err = 'session-hidden-by-folded-pinned-group: it sits behind the 已置顶 bar; use a non-pinned chat or expand the fold first' }
      Write-Result ([ordered]@{
        ok             = $false
        mode           = 'focus'
        session        = $Session
        selected       = $false
        error          = $err
        restoredWindow = [bool]$restored
        passes         = $passes
        scrollRestored = [bool]$back.stable
        ms             = (Get-Ms)
      }) 1
    }
    $before = $null
    try { $before = Get-ChatNameOfEdit } catch { }
    $method = ''
    $selError = ''
    try { $method = Select-Session $found $Session } catch { $selError = '' + $_.Exception.Message }
    Start-Sleep -Milliseconds 250
    $open = $null
    try { $open = Get-ChatNameOfEdit } catch { }
    # A posted click is sometimes swallowed (list still settling); re-read the row and click once
    # more before declaring failure. The rect is re-read, so the second click cannot go stale.
    if ([string]::IsNullOrEmpty($open) -or -not ($open -eq $Session -or $open -like ($Session + '*'))) {
      foreach ($it in @(Get-SessionItems)) {
        $cls = ''
        try { $cls = [string]$it.Current.ClassName } catch { }
        if ($cls -eq 'mmui::ChatStickyFoldCell') { continue }
        $sp2 = Split-SessionName $it.Current.Name
        if ($sp2.title -ne $Session) { continue }
        try {
          $pt2 = Click-ElementCenter $it
          Start-Sleep -Milliseconds 700
          $method = ($method + ' | retry SyntheticClick@' + $pt2)
        } catch { }
        break
      }
      try { $open = Get-ChatNameOfEdit } catch { }
    }
    $selected = $false
    if (-not [string]::IsNullOrEmpty($open)) {
      if ($open -eq $Session -or $open -like ($Session + '*')) { $selected = $true }
    }
    if (-not $selected) { try { $selected = (Get-IsSelected $found) } catch { } }
    $back = Scroll-ListToTop 140 40
    $errOut = $null
    if (-not $selected) {
      $errOut = 'focus-verify-failed: chat is still ' + $open
      if (-not [string]::IsNullOrEmpty($selError)) { $errOut = $errOut + ' (' + $selError + ')' }
    }
    $res = [ordered]@{
      ok             = [bool]$selected
      mode           = 'focus'
      session        = $Session
      selected       = [bool]$selected
      openChat       = $open
      before         = $before
      method         = $method
      error          = $errOut
      restoredWindow = [bool]$restored
      passes         = $passes
      scrollRestored = [bool]$back.stable
      ms             = (Get-Ms)
    }
    if ($selected) { Write-Result $res 0 } else { Write-Result $res 1 }
  }
  # ============================== MODE: read ===============================
  if ($Mode -eq 'read') {
    if ([string]::IsNullOrWhiteSpace($Session)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Session is required for -Mode read' }) 1
    }
    $target = Find-Session $Session
    $scrollPasses = 0
    $alreadyOpen = $false
    if ($target -eq $null) {
      # Not in the viewport. The record-only path asks for chats far down the list, so walk
      # the list the same way -Mode focus does instead of failing with session-not-found.
      $walk = Find-SessionRowScrolled $Session 14
      $scrollPasses = $walk.passes
      if ($walk.item -ne $null) {
        $target = $walk.item
      } else {
        $curName = $null
        try { $curName = Get-ChatNameOfEdit } catch { }
        if ($curName -eq $Session) {
          # the chat is already open, just scrolled out of the list viewport
          $alreadyOpen = $true
        } else {
          $err = 'session-not-visible: not found in the first ' + ($scrollPasses + 1) + ' screens of the list'
          if ($walk.barSeen) { $err = 'session-hidden-by-folded-pinned-group: it sits behind the 已置顶 bar; expand the fold first' }
          Write-Result ([ordered]@{ ok = $false; error = $err; session = $Session; scrollPasses = $scrollPasses }) 1
        }
      }
    }
    $selMethod = 'already-open'
    if (-not $alreadyOpen) {
      $selMethod = Select-Session $target $Session
    }
    $editName  = Get-ChatNameOfEdit
    if ($editName -ne $Session) {
      Write-Result ([ordered]@{
        ok = $false
        error = "session-switch-failed: chat is still '$editName' but '$Session' was requested"
        session = $Session; currentChat = $editName; selectMethod = $selMethod
      }) 1
    }
    $msg = Get-Messages ([Math]::Max(1, $Limit)) $null
    # Screenshot AFTER the chat switch: the bitmap must show this conversation and the UIA
    # rects above must still be valid for it. A capture failure degrades to dir=unknown.
    $cap    = $null
    $capErr = $null
    try {
      $cap = Get-WindowBitmap
      Add-MessageDirections $msg.rows $cap.bmp
    } catch { $capErr = $_.Exception.Message }
    finally { if ($cap -ne $null -and $cap.bmp -ne $null) { try { $cap.bmp.Dispose() } catch { } } }
    $capMethod = $null
    if ($cap -ne $null) { $capMethod = $cap.method }
    $outCount     = @($msg.rows | Where-Object { $_.dir -eq 'out' }).Count
    $unknownCount = @($msg.rows | Where-Object { $_.dir -eq 'unknown' }).Count
    # Title bar read: chatTitle is the bar text as rendered (e.g. "群名(189)"),
    # isGroupTitle is true only when a member count is present. Read AFTER the
    # screenshot so a title lookup failure can never spoil the capture path.
    $ti = Get-ChatTitleInfo
    Write-Result ([ordered]@{
      ok              = $true
      session         = $Session
      selectMethod    = $selMethod
      restoredWindow  = [bool]$script:RestoredWindow
      movedOnScreen   = [bool]$script:MovedOnScreen
      confirmedByEdit = $editName
      chatTitle       = $ti.title
      isGroupTitle    = [bool]$ti.isGroup
      titleKindConfidence = $ti.confidence
      titleSource     = $ti.source
      titleReason     = $ti.reason
      titleElement    = $ti.element
      total           = $msg.total
      capture         = $capMethod
      captureError    = $capErr
      outCount        = $outCount
      unknownCount    = $unknownCount
      messages        = $msg.rows
      ms              = (Get-Ms)
    }) 0
  }
  # ============================== MODE: foldtest =============================
  # Diagnostic only: toggle the 已置顶 fold bar and report what changed.
  if ($Mode -eq 'foldtest') {
    $bar = Get-FoldBarItem
    $barInfo = $null
    if ($bar -ne $null) {
      $r = $bar.Current.BoundingRectangle
      $barInfo = ('{0}x{1}@{2},{3}' -f [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y)
    }
    $err = $null
    $at = $null
    try { $at = Invoke-FoldBarToggle 900 } catch { $err = $_.Exception.Message }
    $afterBar = Get-FoldBarItem
    $afterInfo = $null
    if ($afterBar -ne $null) {
      $r2 = $afterBar.Current.BoundingRectangle
      $afterInfo = ('{0}x{1}@{2},{3}' -f [int]$r2.Width, [int]$r2.Height, [int]$r2.X, [int]$r2.Y)
    }
    Write-Result ([ordered]@{
      ok = ($err -eq $null); barBefore = $barInfo; clickedAt = $at; error = $err; barAfter = $afterInfo
      foldStateAfter = $(if ($afterBar -eq $null) { 'expanded' } else { 'collapsed' }); ms = (Get-Ms)
    }) $(if ($err -eq $null) { 0 } else { 1 })
  }
  # ============================== MODE: markunread =========================
  # Put the red badge BACK on a chat the caller just opened to read it (record-only path).
  # WeChat clears the badge the moment a chat is opened, so without this the user comes back
  # to a silent list and never sees the messages we decided not to answer.
  # Everything is posted (right click -> find 标为未读 -> left click the popup item): no real
  # cursor movement and no focus steal, so the user can keep using the machine.
  if ($Mode -eq 'markunread') {
    if ([string]::IsNullOrWhiteSpace($Session)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Session is required for -Mode markunread'; ms = (Get-Ms) }) 1
    }
    $MENU_LABEL = '标为未读'
    # Get-RootHwnd can return $null while wx rebuilds its window; passing that into an [IntPtr]
    # parameter throws a bare "Cannot convert null to type System.IntPtr" with no context, so
    # bind it once and fail with a structured error instead.
    $mainHwnd = Get-RootHwnd
    if ($null -eq $mainHwnd -or $mainHwnd -eq [IntPtr]::Zero) {
      Write-Result ([ordered]@{
        ok = $false; changed = $false; session = $Session; method = 'context-menu'
        menuFound = $false; rowUnreadAfter = $null; error = 'menu-hwnd-null: main-window'
        window = $script:RootPick; ms = (Get-Ms)
      }) 1
    }
    $restored = [bool](Restore-WindowForCapture)
    $readRowsNow = {
      $b = $null
      try { $b = [WxShot]::Grab($mainHwnd, [ref]$null) } catch { $b = $null }
      $rows = @()
      if ($b -ne $null) { try { $rows = @(Read-SessionRows $b) } catch { } finally { $b.Dispose() } }
      return $rows
    }
    $pickRow = {
      param($rows)
      return (@($rows | Where-Object { -not $_.foldBar -and $_.title -eq $Session }) | Select-Object -First 1)
    }
    # ---- 1. locate the row (scroll walk, top first) ----
    $walk = Find-SessionRowScrolled $Session 14
    # A pinned chat without a badge lives INSIDE the collapsed 已置顶 group, so the list
    # walk cannot see it. Only when the caller explicitly allows it do we unfold, mark, and
    # fold back again - toggling the fold is user-visible state, never implicit.
    $expandedFold = $false
    if ($walk.item -eq $null -and $walk.barSeen -and $AllowFoldToggle) {
      try {
        [void](Invoke-FoldBarToggle 800)
        $expandedFold = $true
        $walk = Find-SessionRowScrolled $Session 14
      } catch { }
    }
    if ($walk.item -eq $null) {
      $err = 'session-not-visible: not found in the first ' + ($walk.passes + 1) + ' screens of the list'
      if ($walk.barSeen) { $err = 'session-hidden-by-folded-pinned-group: it sits behind the 已置顶 bar; expand the fold first' }
      Write-Result ([ordered]@{
        ok = $false; changed = $false; session = $Session; method = 'context-menu'
        menuFound = $false; rowUnreadAfter = $null; error = $err
        passes = $walk.passes; trace = $walk.trace; topPasses = $walk.topPasses; topStable = $walk.topStable
        restoredWindow = $restored; window = $script:RootPick; ms = (Get-Ms)
      }) 1
    }
    # ---- 2. already unread? then nothing to do (the menu would offer 标为已读!) ----
    $rowsBefore = & $readRowsNow
    $pre = & $pickRow $rowsBefore
    if ($pre -ne $null -and $pre.unread) {
      Write-Result ([ordered]@{
        ok = $true; changed = $false; session = $Session; method = 'already-unread'; menuMethod = $MenuMethod
        menuFound = $false; rowUnreadAfter = $true; badgeDigit = [bool]$pre.badgeDigit
        badgeBox = $pre.badgeBox; restoredWindow = $restored; window = $script:RootPick; ms = (Get-Ms)
      }) 0
    }
    $rowUnreadBefore = $(if ($pre -eq $null) { $null } else { [bool]$pre.unread })
    # ---- 3. right click the row, then look for the menu entry ----
    $menuFound = $false
    $menuAttempts = 0
    $menuError = $null
    $rightAt = $null
    $hit = $null
    $winsAtFailure = @()
    while ($menuAttempts -lt 2 -and -not $menuFound) {
      $menuAttempts++
      $w = Find-SessionRowScrolled $Session 14
      if ($w.item -eq $null) { $menuError = 'session-lost-before-right-click'; break }
      $br = $null
      try { $br = $w.item.Current.BoundingRectangle } catch { }
      if ($br -eq $null -or $br.Width -le 0 -or $br.Height -le 0) { $menuError = 'element-has-no-bounding-rect'; break }
      # right click the row's text column: 55% of the width clears the avatar and its badge
      $cx = [int]($br.X + $br.Width * 0.55)
      $cy = [int]($br.Y + $br.Height / 2)
      try {
        if ($MenuMethod -eq 'mouse') {
          $rightAt = Click-ScreenPoint $mainHwnd $cx $cy 'right'
        } else {
          # WM_CONTEXTMENU (0x007B): lParam is SCREEN coordinates ((y << 16) | (x & 0xFFFF)),
          # wParam is the handle of the window the menu belongs to. One message instead of a
          # button down/up pair, and no pressed-button state for Qt to unwind.
          $clp = [IntPtr](((($cy -band 0xFFFF) -shl 16) -bor ($cx -band 0xFFFF)))
          [void][WxCtl32]::PostMessage($mainHwnd, 0x007B, $mainHwnd, $clp)
          $rightAt = ('contextmenu@{0},{1}' -f $cx, $cy)
        }
      }
      catch { $menuError = 'right-click: ' + $_.Exception.Message; break }
      Start-Sleep -Milliseconds 400
      $wins = @(Get-WeixinWindowList)
      $hit = Find-MenuItemByName $MENU_LABEL $wins $mainHwnd
      if ($hit -ne $null) { $menuFound = $true; break }
      $menuError = 'menu-item-not-found: ' + $MENU_LABEL
      $winsAtFailure = $wins
      # close whatever we opened before the retry (Esc only goes to the main window)
      try {
        [void][WxCtl32]::PostMessage($mainHwnd, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
        [void][WxCtl32]::PostMessage($mainHwnd, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
      } catch { }
      Start-Sleep -Milliseconds 350
    }
    if (-not $menuFound) {
      if ($expandedFold) { try { [void](Invoke-FoldBarToggle 400) } catch { } }
      if ($winsAtFailure.Count -eq 0) { try { $winsAtFailure = @(Get-WeixinWindowList) } catch { } }
      $info = @()
      foreach ($wn in $winsAtFailure) {
        $info += ([string]$wn.title + ' | ' + [string]$wn.cls + ' | ' + $wn.w.ToString() + 'x' + $wn.h.ToString() + ' | visible=' + $wn.vis.ToString())
      }
      Write-Result ([ordered]@{
        ok = $false; changed = $false; session = $Session; method = 'context-menu'
        menuFound = $false; rowUnreadAfter = $null; rowUnreadBefore = $rowUnreadBefore
        error = $menuError; rightClickAt = $rightAt; menuAttempts = $menuAttempts; menuMethod = $MenuMethod
        windows = $info; restoredWindow = $restored; window = $script:RootPick; ms = (Get-Ms)
      }) 1
    }
    # ---- 4. click the popup item (posted left click into the popup's own window) ----
    $menuHwnd = $hit.hwnd
    if ($null -eq $mainHwnd -or $mainHwnd -eq [IntPtr]::Zero) { $mainHwnd = Get-RootHwnd }
    $ix = 0; $iy = 0
    $itemRect = ''
    try {
      $ir = $hit.element.Current.BoundingRectangle
      $ix = [int]($ir.X + $ir.Width / 2)
      $iy = [int]($ir.Y + $ir.Height / 2)
      $itemRect = ('{0},{1} {2}x{3}' -f [int]$ir.X, [int]$ir.Y, [int]$ir.Width, [int]$ir.Height)
    } catch { }
    # Diagnostics: which window we are posting into, whether it is the main window (then the
    # client-point conversion lands outside the popup and the menu just closes) and what the
    # popup actually contains, so a mis-hit on a neighbouring entry is visible.
    $menuHwndIsMain = ($menuHwnd -eq $mainHwnd)
    $menuWinInfo = ''
    if ($hit.win -ne $null) {
      $menuWinInfo = ('{0}|{1}|{2},{3} {4}x{5}|vis={6}' -f [string]$hit.win.title, [string]$hit.win.cls, [int]$hit.win.x, [int]$hit.win.y, [int]$hit.win.w, [int]$hit.win.h, [string]$hit.win.vis)
    }
    # last safety net: if the menu entry does not sit inside the window we picked, use the
    # smallest window that geometrically contains the entry centre
    $mw = Get-WindowAtPoint (@(Get-WeixinWindowList)) $ix $iy $mainHwnd
    if ($mw -ne $null -and -not $hit.inside) { $menuHwnd = $mw.hwnd; $menuWinInfo = $menuWinInfo + ' | reanchored=' + [string]$mw.cls }
    $menuItemsText = @()
    try {
      $topEl = [System.Windows.Automation.AutomationElement]::FromHandle($menuHwnd)
      $condAll = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @($AE::IsOffscreenProperty, $false)
      foreach ($mi in @($topEl.FindAll($TS::Descendants, $condAll))) {
        if ($menuItemsText.Count -ge 24) { break }
        $mn = ''
        try { $mn = [string]$mi.Current.Name } catch { }
        if ([string]::IsNullOrWhiteSpace($mn)) { continue }
        $mr = $null
        try { $mr = $mi.Current.BoundingRectangle } catch { }
        if ($mr -eq $null -or $mr.Width -le 0) { continue }
        $menuItemsText += ($mn + '@' + [int]($mr.X + $mr.Width / 2) + ',' + [int]($mr.Y + $mr.Height / 2) + ' ' + [int]$mr.Width + 'x' + [int]$mr.Height)
      }
    } catch { }
    if ($null -eq $menuHwnd -or $menuHwnd -eq [IntPtr]::Zero) {
      Write-Result ([ordered]@{
        ok = $false; changed = $false; session = $Session; method = 'context-menu'
        menuFound = $true; rowUnreadAfter = $null; rowUnreadBefore = $rowUnreadBefore
        error = 'menu-hwnd-null: popup'; menuWinInfo = $menuWinInfo; menuItemRect = $itemRect
        restoredWindow = $restored; window = $script:RootPick; ms = (Get-Ms)
      }) 1
    }
    $clicked = $false
    $clickAt = $null
    for ($k = 0; $k -lt 2 -and -not $clicked; $k++) {
      try { $clickAt = Click-ScreenPoint $menuHwnd $ix $iy 'left' }
      catch { $menuError = 'menu-click: ' + $_.Exception.Message; break }
      Start-Sleep -Milliseconds 450
      $still = Find-MenuItemByName $MENU_LABEL (@(Get-WeixinWindowList))
      if ($still -eq $null) { $clicked = $true; break }
      # still open: the item may have re-rendered, re-read its rect once
      try {
        $r2 = $still.element.Current.BoundingRectangle
        if ($r2.Width -gt 0 -and $r2.Height -gt 0) {
          $ix = [int]($r2.X + $r2.Width / 2); $iy = [int]($r2.Y + $r2.Height / 2); $menuHwnd = $still.hwnd
        }
      } catch { }
    }
    if (-not $clicked) {
      if ($expandedFold) { try { [void](Invoke-FoldBarToggle 400) } catch { } }
      $menuError = 'menu-click-no-effect: ' + $MENU_LABEL + ' is still on screen after the click'
      try {
        [void][WxCtl32]::PostMessage($menuHwnd, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
        [void][WxCtl32]::PostMessage($menuHwnd, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
      } catch { }
      Write-Result ([ordered]@{
        ok = $false; changed = $false; session = $Session; method = 'context-menu'
        menuFound = $true; rowUnreadAfter = $null; rowUnreadBefore = $rowUnreadBefore
        error = $menuError; rightClickAt = $rightAt; menuClickAt = $clickAt
        menuHwnd = $menuHwnd.ToInt64(); mainHwnd = $mainHwnd.ToInt64(); menuHwndIsMain = $menuHwndIsMain
        menuWinInfo = $menuWinInfo; menuItemRect = $itemRect; menuItems = $menuItemsText
        restoredWindow = $restored; window = $script:RootPick; ms = (Get-Ms)
      }) 1
    }
    # ---- 5. verify: the row carries a red badge again ----
    Start-Sleep -Milliseconds 250
    $post = & $pickRow (& $readRowsNow)
    if ($post -eq $null) {
      # a brand-new message may have reordered the list: look the row up again
      $w2 = Find-SessionRowScrolled $Session 14
      if ($w2.item -ne $null) { $post = & $pickRow (& $readRowsNow) }
      [void](Scroll-ListToTop 140 40)
    }
    $rowUnreadAfter = $(if ($post -eq $null) { $null } else { [bool]$post.unread })
    if ($expandedFold) { try { [void](Invoke-FoldBarToggle 400) } catch { } }
    $changed = ($rowUnreadBefore -eq $false -and $rowUnreadAfter -eq $true)
    $verified = ($rowUnreadAfter -eq $true)
    $errOut = $null
    if (-not $verified) { $errOut = 'mark-unread-verify-failed: the row still shows no red badge' }
    Write-Result ([ordered]@{
      ok = $verified
      changed = $changed
      session = $Session
      method = 'context-menu'
      menuMethod = $MenuMethod
      menuFound = $true
      menuAttempts = $menuAttempts
      rightClickAt = $rightAt
      menuClickAt = $clickAt
      rowUnreadBefore = $rowUnreadBefore
      rowUnreadAfter = $rowUnreadAfter
      menuHwnd = $menuHwnd.ToInt64(); mainHwnd = $mainHwnd.ToInt64(); menuHwndIsMain = $menuHwndIsMain
      menuWinInfo = $menuWinInfo; menuItemRect = $itemRect; menuItems = $menuItemsText
      badgeDigit = $(if ($post -eq $null) { $null } else { [bool]$post.badgeDigit })
      badgeBox = $(if ($post -eq $null) { '' } else { $post.badgeBox })
      error = $errOut
      restoredWindow = $restored
      window = $script:RootPick
      ms = (Get-Ms)
    }) $(if ($verified) { 0 } else { 1 })
  }
  # ============================== MODE: send ==============================
  if ($Mode -eq 'send') {
    if ([string]::IsNullOrWhiteSpace($Session)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Session is required for -Mode send' }) 1
    }
    if ([string]::IsNullOrEmpty($Text)) {
      Write-Result ([ordered]@{ ok = $false; error = 'missing-parameter: -Text is required for -Mode send' }) 1
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectSession) -and $ExpectSession -ne $Session) {
      Write-Result ([ordered]@{
        ok = $false; sent = $false
        error = ("expect-session-mismatch: -ExpectSession '$ExpectSession' vs -Session '$Session'")
        session = $Session; ms = (Get-Ms)
      }) 1
    }
    $target = Find-Session $Session
    if ($target -eq $null) { Write-Result ([ordered]@{ ok = $false; error = "session-not-found: '$Session'"; sent = $false }) 1 }
    $selMethod = Select-Session $target $Session
    $edit = Get-InputEdit
    if ($edit -eq $null) {
      Write-Result ([ordered]@{ ok = $false; error = 'input-edit-not-found: AutomationId=chat_input_field not present'; sent = $false }) 1
    }
    $editName = $edit.Current.Name
    $wantName = $(if (-not [string]::IsNullOrWhiteSpace($ExpectSession)) { $ExpectSession } else { $Session })
    if ($editName -ne $Session -or $editName -ne $wantName) {
      Write-Result ([ordered]@{
        ok = $false
        error = "session-mismatch: input box belongs to '$editName' but '$wantName' was requested"
        sent = $false; selected = $false; selectMethod = $selMethod; ms = (Get-Ms)
      }) 1
    }
    $attempts = @()
    $btn = Get-SendButton
    $enabledBefore = Get-ButtonEnabled $btn
    $valueBefore = Get-EditValue $edit
    # --- attempt A: ValuePattern.SetValue, no focus change ---
    $errA = $null
    try { Set-EditValue $edit $Text } catch { $errA = $_.Exception.Message }
    Start-Sleep -Milliseconds 400
    $btn = Get-SendButton
    $enA = Get-ButtonEnabled $btn
    $valA = Get-EditValue $edit
    $attempts += [pscustomobject]@{ attempt = 'A:ValuePattern.SetValue'; error = $errA; valueReadBack = $valA; buttonEnabled = $enA }
    # --- attempt B: SetFocus + SetValue (only if A left the button disabled) ---
    if (-not $enA) {
      $errB = $null
      try { $edit.SetFocus() } catch { $errB = 'SetFocus: ' + $_.Exception.Message }
      try { Set-EditValue $edit $Text } catch { $errB = (($errB + ' / ') + 'SetValue: ' + $_.Exception.Message) }
      Start-Sleep -Milliseconds 400
      $btn = Get-SendButton
      $enB = Get-ButtonEnabled $btn
      $attempts += [pscustomobject]@{ attempt = 'B:SetFocus+SetValue'; error = $errB; valueReadBack = (Get-EditValue $edit); buttonEnabled = $enB }
    }
    # --- attempt C: clipboard + Ctrl+V, only with explicit opt-in ---
    if (-not $enA -and -not $enB -and $AllowPasteFallback) {
      $errC = $null
      try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($Text)
        $edit.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 400
      } catch { $errC = $_.Exception.Message }
      $btn = Get-SendButton
      $enC = Get-ButtonEnabled $btn
      $attempts += [pscustomobject]@{ attempt = 'C:Clipboard+^v'; error = $errC; valueReadBack = (Get-EditValue $edit); buttonEnabled = $enC }
    }
    # re-verify the chat right before sending: the human may have switched chats mid-flow
    $chatNow = Get-ChatNameOfEdit
    if ($chatNow -ne $Session) {
      try { Set-EditValue $edit  } catch { }
      Write-Result ([ordered]@{
        ok = $false; error = ("session-changed-mid-send: chat is now $chatNow"); sent = $false
        session = $Session; inputCleared = $true; attempts = $attempts
      }) 1
    }
    $buttonEnabled = Get-ButtonEnabled (Get-SendButton)
    if ($DryRun) {
      if ($valueBefore -ne $null -and $valueBefore -ne '') { Set-EditValue $edit $valueBefore } else { Set-EditValue $edit '' }
      Write-Result ([ordered]@{
        ok = $buttonEnabled
        dryRun = $true
        session = $Session
        selectMethod = $selMethod
        buttonWasEnabledBefore = $enabledBefore
        buttonEnabledAfterSetValue = $buttonEnabled
        attempts = $attempts
        inputCleared = $true
        sent = $false
        ms = (Get-Ms)
      }) 0
    }
    if (-not $buttonEnabled) {
      try { Set-EditValue $edit '' } catch { }
      Write-Result ([ordered]@{
        ok = $false
        error = 'send-button-disabled: input accepted text but the send button stayed disabled'
        valueSet = $true
        session = $Session
        selectMethod = $selMethod
        attempts = $attempts
        inputCleared = $true
        sent = $false
      }) 1
    }
    # --- send: InvokePattern.Invoke() is a no-op stub on WeChat 4.x, so fall back to a verified click ---
    $sendErr = $null
    $sendPath = "InvokePattern.Invoke"
    try {
      $iv = $null
      if (-not ($btn.TryGetCurrentPattern($PAT_INVOKE, [ref]$iv) -and $iv -ne $null)) { throw 'invoke-pattern-unsupported: send Button has no InvokePattern' }
      $iv.Invoke()
    } catch { $sendErr = $_.Exception.Message }
    if ($sendErr -eq $null) {
      Start-Sleep -Milliseconds 700
      $draftProbe = Get-EditValue $edit
      if ($draftProbe -eq $Text) {
        if ($NoClickFallback) {
          $sendErr = 'invoke-no-effect: draft is still in the input box after Invoke()'
        } else {
          # the Qt button swallows Invoke(): post a synthetic click on the button centre instead
          $chatNow2 = Get-ChatNameOfEdit
          if ($chatNow2 -ne $Session) {
            try { Set-EditValue $edit '' } catch { }
            Write-Result ([ordered]@{ ok = $false; error = ("session-changed-before-click: chat is now " + $chatNow2); sent = $false; session = $Session }) 1
          }
          try {
            $bp = Click-ElementCenter $btn
            $sendPath = "SyntheticClick@" + $bp
            $sendErr = $null
          } catch { $sendErr = "synthetic-click: " + $_.Exception.Message }
        }
      }
    }
    if ($sendErr -ne $null) {
      try { Set-EditValue $edit '' } catch { }
      Write-Result ([ordered]@{
        ok = $false; error = ('send-failed: ' + $sendErr); sent = $false
        session = $Session; selectMethod = $selMethod; sendPath = $sendPath; attempts = $attempts
      }) 1
    }
    Start-Sleep -Milliseconds 900
    $tail = Get-Messages 2 $null
    $last = if ($tail.rows.Count -gt 0) { $tail.rows[$tail.rows.Count - 1].text } else { $null }
    $verified = ($last -eq $Text)
    $draftAfter = Get-EditValue $edit
    Write-Result ([ordered]@{
      ok              = $verified
      session         = $Session
      selectMethod    = $selMethod
      restoredWindow  = [bool]$script:RestoredWindow
      movedOnScreen   = [bool]$script:MovedOnScreen
      sent            = $true
      verified        = $verified
      sendPath        = $sendPath
      buttonWasEnabled = $buttonEnabled
      buttonWasEnabledBefore = $enabledBefore
      attempts        = $attempts
      lastMessage     = $last
      draftAfterSend  = $draftAfter
      total           = $tail.total
      ms              = (Get-Ms)
      error           = $(if ($verified) { $null } else { 'verification-failed: last message did not match the text that was sent' })
    }) $(if ($verified) { 0 } else { 1 })
  }
}
catch {
  $msg = $_.Exception.Message
  # line/trace make a raw failure actionable without re-running under a debugger
  $lineNo = 0
  try { $lineNo = [int]$_.InvocationInfo.ScriptLineNumber } catch { }
  $trace = ''
  try { $trace = [string]$_.ScriptStackTrace } catch { }
  if ($trace.Length -gt 400) { $trace = $trace.Substring(0, 400) }
  Write-Result ([ordered]@{ ok = $false; error = $msg; errorLine = $lineNo; trace = $trace; mode = $Mode; window = $script:RootPick; restoredWindow = [bool]$script:RestoredWindow; movedOnScreen = [bool]$script:MovedOnScreen }) 1
}
