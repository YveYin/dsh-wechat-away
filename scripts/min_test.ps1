$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MinW {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static IntPtr Target = IntPtr.Zero;
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder c, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public static bool Cb(IntPtr h, IntPtr l){
    var cls = new StringBuilder(256); GetClassName(h, cls, 256);
    var ttl = new StringBuilder(256); GetWindowText(h, ttl, 256);
    if (cls.ToString() == "Qt51514QWindowIcon" && ttl.ToString() == "\u5FAE\u4FE1" && IsWindowVisible(h)) { Target = h; return false; }
    return true;
  }
}
'@
$cb=[MinW+EnumProc]{ param($h,$l) [void][MinW]::Cb($h,$l); return $true }
[void][MinW]::EnumWindows($cb,[IntPtr]::Zero)
$hw=[MinW]::Target
if($hw -eq [IntPtr]::Zero){ throw 'window-not-found' }
"hwnd=$hw"

$sess = [string][char]0x6708 + [char]0x9634 + [char]0x7684 + 'emo' + [char]0x65E5 + [char]0x8BB0
$dir  = Split-Path -Parent $PSCommandPath
$script = Join-Path $dir 'wx_ctl.ps1'
$outList = Join-Path $dir 'min_list.json'
$outRead = Join-Path $dir 'min_read.json'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
"script=$script"

try {
  [void][MinW]::ShowWindow($hw, 6)   # SW_MINIMIZE
  Start-Sleep -Milliseconds 900
  "minimized: IsIconic=$([MinW]::IsIconic($hw)) visible=$([MinW]::IsWindowVisible($hw)) fg=$([MinW]::GetForegroundWindow())"

  Remove-Item $outList,$outRead -ErrorAction SilentlyContinue
  & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Mode list -Out $outList | Out-Null
  "child-list exit=$LASTEXITCODE"
  & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Mode read -Session $sess -Limit 3 -Out $outRead | Out-Null
  "child-read exit=$LASTEXITCODE"
} finally {
  [void][MinW]::ShowWindow($hw, 9)   # SW_RESTORE
  Start-Sleep -Milliseconds 700
  "restored: IsIconic=$([MinW]::IsIconic($hw)) visible=$([MinW]::IsWindowVisible($hw))"
  $r=New-Object MinW+RECT; [void][MinW]::GetWindowRect($hw,[ref]$r)
  "window-rect=$($r.L),$($r.T) $($r.R-$r.L)x$($r.B-$r.T)"
}
