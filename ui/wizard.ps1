<#
.SYNOPSIS
    微信值守 —— 桌面向导（Windows 11 / PowerShell 5.1 / WinForms）

.DESCRIPTION
    配合 DSH 插件 dsh-wechat-away 使用：
      - 读取状态目录里的 state.json / heartbeat；
      - 通过 requests\req-<13位毫秒>.json 提交开始、结束请求；
      - 把 last-summary.md 显示在窗口里。
    本文件只做界面与 IPC，不改插件本身。

.NOTES
    文件编码必须是 UTF-8 with BOM、CRLF；否则 PowerShell 5.1 会按 GBK 解析中文。
    由 launch.vbs 通过 wscript.exe 隐藏控制台启动。
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ────────────────────────────── 路径与常量 ──────────────────────────────

$script:StateDir = if ($env:DSH_WECHAT_AWAY_HOME) {
    $env:DSH_WECHAT_AWAY_HOME
} else {
    'D:\DeepSeek\DeepSeek harness\工作区\dsh-wechat-away\state'
}
$script:RequestsDir = Join-Path $script:StateDir 'requests'
$script:HeartbeatPath = Join-Path $script:StateDir 'heartbeat'
$script:StatePath = Join-Path $script:StateDir 'state.json'
$script:SummaryPath = Join-Path $script:StateDir 'last-summary.md'

$script:DshExe = 'D:\DeepSeek\DeepSeek harness\DeepSeek harness\DeepSeek Harness.exe'

$script:UiDataDir = 'D:\DeepSeek\DeepSeek harness\工作区\dsh-wechat-away\ui-data'
$script:LastActivityPath = Join-Path $script:UiDataDir 'last-activity.txt'
$script:LogPath = Join-Path $script:UiDataDir 'wizard.log'

$script:HeartbeatFreshSeconds = 15
$script:StartWaitSeconds = 20
$script:StopWaitSeconds = 40
$script:DsHStartWaitSeconds = 90

$script:UiFontName = 'Microsoft YaHei UI'
$script:Busy = $false
$script:SkipSave = $false
$script:IsActive = $false
$script:SummaryText = ''
$script:Pending = $null
$script:PendingUntilAt = $null
$script:LastParse = $null
$script:State = $null

# ────────────────────────────── 小工具 ──────────────────────────────

function Write-UiLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:UiDataDir)) {
            New-Item -ItemType Directory -Path $script:UiDataDir -Force | Out-Null
        }
        $line = '{0} {1}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # 日志失败不能影响界面。
    }
}

function Invoke-UiPulse {
    param([int]$Milliseconds = 120)
    try {
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
    }
    if ($Milliseconds -gt 0) {
        Start-Sleep -Milliseconds $Milliseconds
    }
}

function Get-HumanDurationText {
    param([int]$Minutes)
    if ($Minutes -lt 60) {
        return ('{0} 分钟' -f $Minutes)
    }
    $hours = [math]::Floor($Minutes / 60)
    $rest = $Minutes % 60
    if ($rest -eq 0) {
        return ('{0} 小时' -f $hours)
    }
    return ('{0} 小时 {1} 分钟' -f $hours, $rest)
}

# ────────────────────────────── 时间解析 ──────────────────────────────

function ConvertFrom-CnNumber {
    <#
      把 0–99 的中文数字（含「两」「零」「十」）转成整数；认不出返回 $null。
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $s = $Text.Trim().Replace('两', '二')
    $map = @{
        '零' = 0; '〇' = 0
        '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5
        '六' = 6; '七' = 7; '八' = 8; '九' = 9
    }

    if ($s -match '^\d+$') { return [int]$s }
    if ($s -eq '十') { return 10 }

    if ($s -match '^十([一二三四五六七八九])$') {
        return 10 + [int]$map[$Matches[1]]
    }
    if ($s -match '^([一二三四五六七八九])十([一二三四五六七八九])?$') {
        $tens = [int]$map[$Matches[1]]
        $ones = 0
        if ($Matches[2]) { $ones = [int]$map[$Matches[2]] }
        return ($tens * 10 + $ones)
    }
    if ($s -match '^零([一二三四五六七八九])$') {
        return [int]$map[$Matches[1]]
    }
    if ($s.Length -eq 1 -and $map.ContainsKey($s)) {
        return [int]$map[$s]
    }
    return $null
}

function ConvertFrom-AwayTimeInput {
    <#
      把一句人话解析成：时刻（今天）或时长。
      返回对象字段：
        Kind   empty | clock | past | duration | invalid
        Mode   clock | duration | $null
        Valid  是否可以点「开始值守」
        Past   是否是一个今天已经过去的时刻
        Hour/Minute           时刻
        DurationMinutes       时长
        UntilAt               DateTimeOffset
        Preview / Warning / Error
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $raw = if ($null -eq $Text) { '' } else { [string]$Text }
    $r = [ordered]@{
        Input = $raw
        Normalized = ''
        Kind = 'empty'
        Mode = $null
        Valid = $false
        Past = $false
        Hour = $null
        Minute = $null
        DurationMinutes = $null
        UntilAt = $null
        Preview = ''
        Warning = ''
        Error = ''
    }

    $s = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return [pscustomobject]$r
    }

    # 全角数字/冒号/句点，以及零宽字符。
    try { $s = $s.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
    $s = $s.Replace([string][char]0xFEFF, '').Replace([string][char]0x200B, '')
    $s = $s -replace '\s+', ''

    # 去掉礼貌用语和「回来」「左右」等尾巴，允许「今天大概3:45回来吧」。
    for ($i = 0; $i -lt 4; $i++) {
        $before = $s
        $s = $s -replace '^(今天|今晚|今夜|现在|大概|大约|差不多|可能)', ''
        $s = $s -replace '(回来|左右|吧|呢|哦|了)$', ''
        if ($s -eq $before) { break }
    }
    if ([string]::IsNullOrWhiteSpace($s)) {
        return [pscustomobject]$r
    }

    # 上午/下午/晚上。下午、晚上按 12 小时制补 12。
    $pm = $false
    if ($s -match '^(下午|晚上|傍晚|夜里)') {
        $pm = $true
        $s = $s -replace '^(下午|晚上|傍晚|夜里)', ''
    } elseif ($s -match '^(凌晨|早上|上午|清晨)') {
        $s = $s -replace '^(凌晨|早上|上午|清晨)', ''
    }

    # 时长后面的「后 / 以内」不影响含义。
    if ($s -match '小时|钟头|分钟') {
        $s = $s -replace '(以后|之后|后|以内|内)$', ''
    }
    $r['Normalized'] = $s

    $isDuration = $false
    if ($s -match '小时|钟头') {
        $isDuration = $true
    } elseif ($s -match '[0-9]:|[0-9]\.|点') {
        $isDuration = $false
    } elseif ($s -match '(分钟|分)$') {
        $isDuration = $true
    } elseif ($s -match '^\d{1,2}$') {
        $isDuration = $false
    } elseif ($s -match '^[零〇一二三四五六七八九十两]+$') {
        $isDuration = $false
    } else {
        $r['Kind'] = 'invalid'
        $r['Error'] = '没看懂这个时间，试试「3:45」「三点四十五」或「90分钟」'
        $r['Warning'] = $r['Error']
        return [pscustomobject]$r
    }

    $numPattern = '([0-9]{1,4}|[零〇一二三四五六七八九十两]+)'

    if ($isDuration) {
        $total = $null
        $m = [regex]::Match($s, '^(?:(?<h>' + $numPattern + ')(?:个)?)?(?<half>半)?(?:个)?(?<unit>小时|钟头)(?:(?<mm>' + $numPattern + ')(?:分钟|分))?$')
        if ($m.Success) {
            $hours = 0
            if ($m.Groups['h'].Success) {
                $hours = ConvertFrom-CnNumber $m.Groups['h'].Value
                if ($null -eq $hours) { $hours = $null }
            }
            $mins = 0
            $okHalf = $m.Groups['half'].Success
            $okMin = $m.Groups['mm'].Success
            $minsVal = 0
            if ($okMin) {
                $minsVal = ConvertFrom-CnNumber $m.Groups['mm'].Value
            }
            if ($null -eq $hours -or ($okMin -and $null -eq $minsVal)) {
                $r['Kind'] = 'invalid'
                $r['Error'] = '没看懂这个时长，试试「90分钟」或「一个半小时」'
                $r['Warning'] = $r['Error']
                return [pscustomobject]$r
            }
            if ($okHalf) { $mins += 30 }
            if ($okMin) { $mins += [int]$minsVal }
            $total = ([int]$hours * 60) + $mins
        } else {
            $m2 = [regex]::Match($s, '^(?<mm>' + $numPattern + ')(?:分钟|分)$')
            if ($m2.Success) {
                $minsOnly = ConvertFrom-CnNumber $m2.Groups['mm'].Value
                if ($null -ne $minsOnly) { $total = [int]$minsOnly }
            }
        }

        if ($null -eq $total) {
            $r['Kind'] = 'invalid'
            $r['Error'] = '没看懂这个时长，试试「90分钟」或「一个半小时」'
            $r['Warning'] = $r['Error']
            return [pscustomobject]$r
        }
        if ($total -lt 1) {
            $r['Kind'] = 'invalid'
            $r['Error'] = '时长要大于 0 分钟'
            $r['Warning'] = $r['Error']
            return [pscustomobject]$r
        }
        if ($total -gt 1440) {
            $r['Kind'] = 'invalid'
            $r['Error'] = '时长要在 24 小时以内'
            $r['Warning'] = $r['Error']
            return [pscustomobject]$r
        }

        $base = [DateTimeOffset]::new($Now.Year, $Now.Month, $Now.Day, $Now.Hour, $Now.Minute, 0, $Now.Offset)
        $until = $base.AddMinutes([int]$total)
        $dayPrefix = ''
        if ($until.Date -gt $Now.Date) { $dayPrefix = '明天 ' }

        $r['Kind'] = 'duration'
        $r['Mode'] = 'duration'
        $r['Valid'] = $true
        $r['DurationMinutes'] = [int]$total
        $r['UntilAt'] = $until
        $r['Preview'] = '→ {0}后回来，约 {1}{2}（时长）' -f (Get-HumanDurationText $total), $dayPrefix, $until.ToString('HH:mm')
        return [pscustomobject]$r
    }

    # ── 时刻 ──
    $hourRaw = $null
    $minute = 0
    $minuteRaw = $null

    $m = [regex]::Match($s, '^(?<h>[0-9]{1,2})(?<sep>[:.])(?<mi>[0-9]{1,2})$')
    if ($m.Success) {
        if ($m.Groups['sep'].Value -eq '.' -and $m.Groups['mi'].Value.Length -ne 2) {
            $r['Kind'] = 'invalid'
            $r['Error'] = '没看懂这个时间，试试「3:45」「三点四十五」或「90分钟」'
            $r['Warning'] = $r['Error']
            return [pscustomobject]$r
        }
        $hourRaw = $m.Groups['h'].Value
        $minuteRaw = $m.Groups['mi'].Value
    } else {
        $m = [regex]::Match($s, '^(?<h>[0-9]{1,2}|[零〇一二三四五六七八九十两]+)点(?:(?<tail>整|半|一刻|三刻)|(?<mi>[0-9]{1,2}|[零〇一二三四五六七八九十两]+)分?)?$')
        if ($m.Success) {
            $hourRaw = $m.Groups['h'].Value
            if ($m.Groups['tail'].Success) {
                switch ($m.Groups['tail'].Value) {
                    '整' { $minute = 0 }
                    '半' { $minute = 30 }
                    '一刻' { $minute = 15 }
                    '三刻' { $minute = 45 }
                }
            } elseif ($m.Groups['mi'].Success) {
                $minuteRaw = $m.Groups['mi'].Value
            }
        } else {
            $m = [regex]::Match($s, '^(?<h>[0-9]{1,2}|[零〇一二三四五六七八九十两]+)$')
            if ($m.Success) {
                $hourRaw = $m.Groups['h'].Value
            } else {
                $r['Kind'] = 'invalid'
                $r['Error'] = '没看懂这个时间，试试「3:45」「三点四十五」或「90分钟」'
                $r['Warning'] = $r['Error']
                return [pscustomobject]$r
            }
        }
    }

    $hour = ConvertFrom-CnNumber $hourRaw
    if ($null -eq $hour) {
        $r['Kind'] = 'invalid'
        $r['Error'] = '没看懂这个时间，试试「3:45」「三点四十五」或「90分钟」'
        $r['Warning'] = $r['Error']
        return [pscustomobject]$r
    }
    if ($null -ne $minuteRaw) {
        $minute = ConvertFrom-CnNumber $minuteRaw
        if ($null -eq $minute) {
            $r['Kind'] = 'invalid'
            $r['Error'] = '没看懂这个时间，试试「3:45」「三点四十五」或「90分钟」'
            $r['Warning'] = $r['Error']
            return [pscustomobject]$r
        }
    }

    if ($pm -and $hour -ge 1 -and $hour -lt 12) { $hour += 12 }

    if ($hour -lt 0 -or $hour -gt 23) {
        $r['Kind'] = 'invalid'
        $r['Error'] = '小时要在 0–23 之间'
        $r['Warning'] = $r['Error']
        return [pscustomobject]$r
    }
    if ($minute -lt 0 -or $minute -gt 59) {
        $r['Kind'] = 'invalid'
        $r['Error'] = '分钟要在 0–59 之间'
        $r['Warning'] = $r['Error']
        return [pscustomobject]$r
    }

    $target = [DateTimeOffset]::new($Now.Year, $Now.Month, $Now.Day, $hour, $minute, 0, $Now.Offset)
    $nowMinutes = ($Now.Hour * 60) + $Now.Minute
    $targetMinutes = ($hour * 60) + $minute
    $past = $nowMinutes -gt $targetMinutes

    $r['Kind'] = if ($past) { 'past' } else { 'clock' }
    $r['Mode'] = 'clock'
    $r['Hour'] = [int]$hour
    $r['Minute'] = [int]$minute
    $r['Past'] = $past
    $r['UntilAt'] = $target
    $r['Preview'] = '→ 今天 {0} 回来（时刻）' -f $target.ToString('HH:mm')

    if ($past) {
        $r['Warning'] = '{0} 已经过了 {1}:{2} — 你是说今晚，还是明早？' -f $Now.ToString('HH:mm'), $hour, $minute.ToString('00')
        $r['Valid'] = $false
    } else {
        $r['Valid'] = $true
    }

    return [pscustomobject]$r
}

# ────────────────────────────── 插件 IPC ──────────────────────────────

function Get-AwayState {
    try {
        if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
        $text = [IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-DshHeartbeatAgeSeconds {
    # 插件每隔 5 秒重写一次 heartbeat；读到一半（空/半截）时重试一次，避免误判 DSH 没运行。
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            if (Test-Path -LiteralPath $script:HeartbeatPath) {
                $text = [IO.File]::ReadAllText($script:HeartbeatPath, [System.Text.Encoding]::UTF8)
                $text = $text.Trim([char]0xFEFF).Trim()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $at = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($text, [ref]$at)) {
                        return ([DateTimeOffset]::Now - $at).TotalSeconds
                    }
                }
            }
        } catch {
        }
        if ($attempt -eq 0) { Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function Test-DshHeartbeat {
    $age = Get-DshHeartbeatAgeSeconds
    if ($null -eq $age) { return $false }
    return ($age -le $script:HeartbeatFreshSeconds -and $age -ge -5)
}

function Write-AwayRequest {
    param($Payload)

    if (-not (Test-Path -LiteralPath $script:RequestsDir)) {
        New-Item -ItemType Directory -Path $script:RequestsDir -Force | Out-Null
    }
    $json = $Payload | ConvertTo-Json -Compress -Depth 6
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $path = Join-Path $script:RequestsDir ('req-{0}.json' -f $ms)
    $tries = 0
    while ((Test-Path -LiteralPath $path) -and $tries -lt 20) {
        Start-Sleep -Milliseconds 3
        $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $path = Join-Path $script:RequestsDir ('req-{0}.json' -f $ms)
        $tries++
    }
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Wait-ForStateActive {
    param([int]$TimeoutSeconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:Form -and $script:Form.IsDisposed) { return $false }
        $st = Get-AwayState
        if ($st -and $st.active -eq $true) { return $true }
        Invoke-UiPulse 300
    }
    return $false
}

function Wait-ForDshHeartbeat {
    param([int]$TimeoutSeconds = 90, [scriptblock]$OnTick = $null)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastSecond = -1
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($script:Form -and $script:Form.IsDisposed) { return $false }
        if (Test-DshHeartbeat) { return $true }
        $sec = [int]$watch.Elapsed.TotalSeconds
        if ($OnTick -and $sec -ne $lastSecond) {
            & $OnTick $sec
            $lastSecond = $sec
        }
        Invoke-UiPulse 300
    }
    return (Test-DshHeartbeat)
}

function Start-DshApp {
    if (-not (Test-Path -LiteralPath $script:DshExe)) {
        return ('找不到 DSH：{0}' -f $script:DshExe)
    }
    try {
        Start-Process -FilePath $script:DshExe -WorkingDirectory (Split-Path -Parent $script:DshExe) | Out-Null
        Write-UiLog 'started DSH'
        return ''
    } catch {
        return $_.Exception.Message
    }
}

function Get-LastActivity {
    try {
        if (Test-Path -LiteralPath $script:LastActivityPath) {
            return ([IO.File]::ReadAllText($script:LastActivityPath, [System.Text.Encoding]::UTF8)).Trim()
        }
    } catch {
    }
    return ''
}

function Save-LastActivity {
    param([string]$Activity)
    if ($script:SkipSave) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:UiDataDir)) {
            New-Item -ItemType Directory -Path $script:UiDataDir -Force | Out-Null
        }
        [IO.File]::WriteAllText($script:LastActivityPath, $Activity, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-UiLog ('save last-activity failed: {0}' -f $_.Exception.Message)
    }
}

# ────────────────────────────── 界面辅助 ──────────────────────────────

function New-UiFont {
    param([double]$Size = 9, [string]$Style = 'Regular')
    $fontStyle = [System.Drawing.FontStyle]$Style
    foreach ($name in @($script:UiFontName, 'Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI')) {
        if (-not $name) { continue }
        try {
            return [System.Drawing.Font]::new($name, [single]$Size, $fontStyle, [System.Drawing.GraphicsUnit]::Point)
        } catch {
        }
    }
    return [System.Drawing.Font]::new([System.Drawing.FontFamily]::GenericSansSerif, [single]$Size, $fontStyle, [System.Drawing.GraphicsUnit]::Point)
}

function Get-UiColor {
    param([string]$Kind)
    switch ($Kind) {
        'muted' { return $script:C.Muted }
        'danger' { return $script:C.Danger }
        'accent' { return $script:C.Accent }
        'success' { return $script:C.Success }
        default { return $script:C.Text }
    }
}

function New-UiLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [double]$Size = 9,
        [string]$Kind = 'text',
        [string]$Style = 'Regular',
        [string]$Align = 'MiddleLeft'
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Bounds = New-Object System.Drawing.Rectangle($X, $Y, $W, $H)
    $label.Font = New-UiFont -Size $Size -Style $Style
    $label.ForeColor = Get-UiColor $Kind
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.AutoSize = $false
    $label.TextAlign = $Align
    $label.UseMnemonic = $false
    return $label
}

function Set-UiButtonPalette {
    param($Button, [string]$Kind, [bool]$Enabled)
    $Button.Tag = $Kind
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand

    if (-not $Enabled) {
        $Button.BackColor = $script:C.DisabledBg
        $Button.ForeColor = $script:C.DisabledFg
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = $script:C.DisabledBg
        $Button.FlatAppearance.MouseOverBackColor = $script:C.DisabledBg
        $Button.FlatAppearance.MouseDownBackColor = $script:C.DisabledBg
        return
    }

    switch ($Kind) {
        'primary' {
            $Button.BackColor = $script:C.Accent
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderSize = 0
            $Button.FlatAppearance.MouseOverBackColor = $script:C.AccentHover
            $Button.FlatAppearance.MouseDownBackColor = $script:C.AccentDown
        }
        'secondary' {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = $script:C.Text
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = $script:C.Border
            $Button.FlatAppearance.MouseOverBackColor = $script:C.Hover
            $Button.FlatAppearance.MouseDownBackColor = $script:C.Border
        }
        'danger' {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = $script:C.Danger
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = $script:C.DangerBorder
            $Button.FlatAppearance.MouseOverBackColor = $script:C.DangerSoft
            $Button.FlatAppearance.MouseDownBackColor = $script:C.DangerSoft
        }
        'outline' {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = $script:C.Accent
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = $script:C.Accent
            $Button.FlatAppearance.MouseOverBackColor = $script:C.AccentSoft
            $Button.FlatAppearance.MouseDownBackColor = $script:C.AccentSoft
        }
        default {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = $script:C.Text
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = $script:C.Border
        }
    }
}

function Set-UiEnabled {
    param($Button, [bool]$Enabled)
    $Button.Enabled = $Enabled
    Set-UiButtonPalette -Button $Button -Kind ([string]$Button.Tag) -Enabled $Enabled
}

function New-UiButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [string]$Kind = 'primary',
        [double]$Size = 11
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Bounds = New-Object System.Drawing.Rectangle($X, $Y, $W, $H)
    $button.Font = New-UiFont -Size $Size -Style 'Bold'
    $button.UseMnemonic = $false
    $button.TabStop = $true
    Set-UiButtonPalette -Button $button -Kind $Kind -Enabled $true
    return $button
}

function Get-UiTreeLines {
    param($Control, [int]$Depth = 0)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $text = [string]$Control.Text
    $text = $text.Replace("`r", ' ').Replace("`n", ' / ').Replace('"', "'")
    if ($text.Length -gt 64) { $text = $text.Substring(0, 64) + '…' }
    $bounds = $Control.Bounds
    $line = '{0}{1} name="{2}" text="{3}" visible={4} enabled={5} bounds={6},{7},{8},{9}' -f (
        ('  ' * $Depth), $Control.GetType().Name, $Control.Name, $text,
        $Control.Visible, $Control.Enabled,
        $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height
    )
    $lines.Add($line)
    foreach ($child in $Control.Controls) {
        foreach ($childLine in (Get-UiTreeLines -Control $child -Depth ($Depth + 1))) {
            $lines.Add($childLine)
        }
    }
    return $lines
}

# ────────────────────────────── 界面逻辑 ──────────────────────────────

function Show-UiPanel {
    param([string]$Name)
    foreach ($panel in @($script:PanelHome, $script:PanelStep1, $script:PanelStep2, $script:PanelSummary)) {
        if ($panel) { $panel.Visible = ($panel.Name -eq $Name) }
    }
    $script:CurrentPanel = $Name
}

function Update-Step2 {
    if (-not $script:TxtWhen) { return }
    try {
        $result = ConvertFrom-AwayTimeInput -Text $script:TxtWhen.Text
        $script:LastParse = $result
        $script:BtnOpenDsh.Visible = $false
        $script:LblProgress.Text = ''

        switch ($result.Kind) {
            'empty' {
                $script:LblPreview.Text = '输入一个时间，例如 3:45 或 90分钟'
                $script:LblPreview.ForeColor = $script:C.Muted
                $script:LblWarning.Text = ''
            }
            'invalid' {
                $script:LblPreview.Text = ''
                $script:LblWarning.Text = $result.Error
                $script:LblWarning.ForeColor = $script:C.Danger
            }
            'past' {
                $script:LblPreview.Text = $result.Preview
                $script:LblPreview.ForeColor = $script:C.Muted
                $script:LblWarning.Text = $result.Warning
                $script:LblWarning.ForeColor = $script:C.Danger
            }
            default {
                $script:LblPreview.Text = $result.Preview
                $script:LblPreview.ForeColor = $script:C.Muted
                $script:LblWarning.Text = ''
            }
        }

        $canStart = $result.Valid -and (-not $script:Busy) -and (-not $script:IsActive)
        Set-UiEnabled $script:BtnStepStart $canStart
    } catch {
        Write-UiLog ('update-step2 failed: {0}' -f $_.Exception.Message)
    }
}

function Open-ActivityStep {
    try {
        $script:LblHomeError.Visible = $false
        $saved = Get-LastActivity
        if ([string]::IsNullOrWhiteSpace($script:TxtActivity.Text) -and $saved) {
            $script:TxtActivity.Text = $saved
        }
        Show-UiPanel 'step1'
        $script:TxtActivity.Focus()
        $script:TxtActivity.SelectionStart = $script:TxtActivity.TextLength
    } catch {
        Write-UiLog ('open-activity failed: {0}' -f $_.Exception.Message)
    }
}

function Go-TimeStep {
    try {
        if ([string]::IsNullOrWhiteSpace($script:TxtActivity.Text)) {
            $script:LblStep1Hint.Text = '先说说你去干什么？'
            $script:LblStep1Hint.ForeColor = $script:C.Danger
            $script:TxtActivity.Focus()
            return
        }
        $script:LblStep1Hint.Text = '例如：去上实验课、在开会、手机不在身边'
        $script:LblStep1Hint.ForeColor = $script:C.Muted
        Save-LastActivity $script:TxtActivity.Text.Trim()
        Show-UiPanel 'step2'
        Update-Step2
        $script:TxtWhen.Focus()
        $script:TxtWhen.SelectionStart = $script:TxtWhen.TextLength
    } catch {
        Write-UiLog ('go-time failed: {0}' -f $_.Exception.Message)
    }
}

function Set-SummaryColors {
    # 把每个「◆【名字】」整段染成蓝色粗体，其余文字保持原色。
    $rtb = $script:TxtSummary
    if ($null -eq $rtb) { return }
    $rtb.SelectAll()
    $rtb.SelectionColor = $script:C.Text
    $rtb.SelectionFont = New-UiFont -Size 9.5
    $body = $rtb.Text
    $idx = 0
    while ($idx -lt $body.Length) {
        $m = [regex]::Match($body.Substring($idx), '◆【[^】]+】')
        if (-not $m.Success) { break }
        $start = $idx + $m.Index
        $rtb.Select($start, $m.Length)
        $rtb.SelectionColor = [System.Drawing.Color]::FromArgb(0x1F, 0x6F, 0xD1)
        $rtb.SelectionFont = New-UiFont -Size 9.5 -Style 'Bold'
        $idx = $start + $m.Length
    }
    $rtb.Select(0, 0)
}

function Update-HomeStatus {
    if (-not $script:StatusLabel) { return }
    if ($script:Busy) { return }
    try {
        $st = Get-AwayState
        $script:State = $st
        $active = [bool]($st -and ($st.active -eq $true))
        $script:IsActive = $active

        if ($active) {
            $activity = [string]$st.activity
            $activity = ($activity -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($activity)) { $activity = '值守中' }

            $untilText = ''
            if ($st.until) {
                try {
                    $untilAt = [DateTimeOffset]::Parse([string]$st.until)
                    $untilText = $untilAt.ToLocalTime().ToString('HH:mm')
                } catch {
                    $untilText = ''
                }
            }

            if ($untilText) {
                $script:StatusLabel.Text = '正在值守：{0} · {1} 提醒' -f $activity, $untilText
            } else {
                $script:StatusLabel.Text = '正在值守：{0} · 无截止时间' -f $activity
            }
            $script:StatusDot.ForeColor = $script:C.Success
        } else {
            $script:StatusLabel.Text = '当前未值守'
            $script:StatusDot.ForeColor = $script:C.Muted
        }

        Set-UiEnabled $script:BtnHomeStart ((-not $active) -and (-not $script:Busy))
        Set-UiEnabled $script:BtnHomeStop ($active -and (-not $script:Busy))

        $canStart = $script:LastParse.Valid -and (-not $active) -and (-not $script:Busy)
        if ($script:PanelStep2 -and $script:PanelStep2.Visible -and $script:TxtWhen.TextLength -gt 0) {
            $nowParse = ConvertFrom-AwayTimeInput -Text $script:TxtWhen.Text
            if ($nowParse.Kind -ne $script:LastParse.Kind) {
                Update-Step2
                return
            }
            $canStart = $nowParse.Valid -and (-not $active) -and (-not $script:Busy)
        }
        Set-UiEnabled $script:BtnStepStart $canStart
    } catch {
        Write-UiLog ('update-status failed: {0}' -f $_.Exception.Message)
    }
}

function Set-UiBusy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $script:TxtActivity.Enabled = -not $Busy
    $script:TxtWhen.Enabled = -not $Busy

    Set-UiEnabled $script:BtnStepNext (-not $Busy)
    Set-UiEnabled $script:BtnStepBack (-not $Busy)
    Set-UiEnabled $script:BtnOpenDsh ((-not $Busy) -and $script:BtnOpenDsh.Visible)
    Set-UiEnabled $script:BtnStepStart ((-not $Busy) -and $script:LastParse.Valid -and (-not $script:IsActive))
    Set-UiEnabled $script:BtnHomeStart ((-not $Busy) -and (-not $script:IsActive))
    Set-UiEnabled $script:BtnHomeStop ((-not $Busy) -and $script:IsActive)
    Set-UiEnabled $script:BtnCopySummary ((-not $Busy) -and ($script:SummaryText -ne ''))
    Set-UiEnabled $script:BtnCloseSummary (-not $Busy)
}

function Show-StartError {
    param([string]$Message)
    if ($script:Form.IsDisposed) { return }
    $script:LblProgress.Text = ''
    $script:LblWarning.Text = $Message
    $script:LblWarning.ForeColor = $script:C.Danger
    $script:BtnOpenDsh.Visible = $false
    Set-UiBusy $false
}

function Show-DshTimeout {
    if ($script:Form.IsDisposed) { return }
    $script:LblProgress.Text = ''
    $script:LblWarning.Text = '没连上 DSH（心跳停了），要不要我先把它打开？'
    $script:LblWarning.ForeColor = $script:C.Danger
    $script:BtnOpenDsh.Visible = $true
    Set-UiBusy $false
    Set-UiEnabled $script:BtnOpenDsh $true
    Write-UiLog 'start timeout / no heartbeat'
}

function Complete-Start {
    param([DateTimeOffset]$UntilAt)
    if ($script:Form.IsDisposed) { return }
    $script:IsActive = $true
    $script:LblProgress.Text = ''
    $script:LblWarning.Text = ''
    $script:StatusDot.ForeColor = $script:C.Success
    if ($UntilAt) {
        $script:StatusLabel.Text = '已开始值守 · {0} 提醒' -f $UntilAt.ToString('HH:mm')
    } else {
        $script:StatusLabel.Text = '已开始值守'
    }
    Show-UiPanel 'home'
    $end = [DateTime]::UtcNow.AddMilliseconds(1500)
    while ([DateTime]::UtcNow -lt $end -and -not $script:Form.IsDisposed) {
        Invoke-UiPulse 100
    }
    if (-not $script:Form.IsDisposed) { $script:Form.Close() }
}

function Start-AwayFlow {
    if ($script:Busy) { return }
    if ($script:IsActive) {
        $script:LblWarning.Text = '已经在值守中了'
        $script:LblWarning.ForeColor = $script:C.Danger
        return
    }
    $parse = ConvertFrom-AwayTimeInput -Text $script:TxtWhen.Text
    $script:LastParse = $parse
    if (-not $parse -or -not $parse.Valid) {
        Update-Step2
        return
    }
    $activity = $script:TxtActivity.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($activity)) {
        $script:LblWarning.Text = '先回到上一步，说说你去干什么。'
        $script:LblWarning.ForeColor = $script:C.Danger
        return
    }

    Save-LastActivity $activity

    $payload = [ordered]@{
        action = 'start'
        activity = $activity
        mode = $parse.Mode
        untilText = $script:TxtWhen.Text.Trim()
    }
    if ($parse.Mode -eq 'clock') {
        $payload['untilAt'] = $parse.UntilAt.ToString("yyyy-MM-dd'T'HH:mm:sszzz")
    } else {
        $payload['durationMinutes'] = [int]$parse.DurationMinutes
    }

    $script:Pending = $payload
    $script:PendingUntilAt = $parse.UntilAt
    $script:BtnOpenDsh.Visible = $false
    $script:LblWarning.Text = ''
    $script:LblProgress.Text = ''
    Set-UiBusy $true

    try {
        if (-not (Test-DshHeartbeat)) {
            $script:LblProgress.Text = 'DSH 没在运行，正在启动…'
            Invoke-UiPulse 120
            $err = Start-DshApp
            if ($err) {
                Show-StartError ('启动 DSH 失败：{0}' -f $err)
                return
            }
            $ok = Wait-ForDshHeartbeat -TimeoutSeconds $script:DsHStartWaitSeconds -OnTick {
                param($sec)
                $script:LblProgress.Text = '正在启动 DSH… 已等待 {0} 秒（最多 90 秒）' -f $sec
            }
            if (-not $ok) {
                Show-DshTimeout
                return
            }
        }

        $script:LblProgress.Text = '正在提交值守请求…'
        Invoke-UiPulse 80
        $requestPath = Write-AwayRequest $payload
        Write-UiLog ('start request: {0}' -f (Split-Path -Leaf $requestPath))

        $script:LblProgress.Text = '正在等 DSH 接管…'
        if (Wait-ForStateActive -TimeoutSeconds $script:StartWaitSeconds) {
            Complete-Start -UntilAt $parse.UntilAt
            return
        }
        Show-DshTimeout
    } catch {
        Write-UiLog ('start failed: {0}' -f $_.Exception.Message)
        Show-StartError ('提交失败：{0}' -f $_.Exception.Message)
    }
}

function Open-DshAndRetry {
    if ($script:Busy -or $null -eq $script:Pending) { return }
    $script:BtnOpenDsh.Visible = $false
    $script:LblWarning.Text = ''
    $script:LblProgress.Text = ''
    Set-UiBusy $true

    try {
        $err = Start-DshApp
        if ($err) {
            Show-StartError ('启动 DSH 失败：{0}' -f $err)
            return
        }
        $ok = Wait-ForDshHeartbeat -TimeoutSeconds $script:DsHStartWaitSeconds -OnTick {
            param($sec)
            $script:LblProgress.Text = '正在启动 DSH… 已等待 {0} 秒（最多 90 秒）' -f $sec
        }
        if (-not $ok) {
            Show-DshTimeout
            return
        }

        $script:LblProgress.Text = '正在重新提交值守请求…'
        $requestPath = Write-AwayRequest $script:Pending
        Write-UiLog ('retry request: {0}' -f (Split-Path -Leaf $requestPath))

        if (Wait-ForStateActive -TimeoutSeconds $script:StartWaitSeconds) {
            Complete-Start -UntilAt $script:PendingUntilAt
            return
        }
        Show-DshTimeout
    } catch {
        Write-UiLog ('retry failed: {0}' -f $_.Exception.Message)
        Show-StartError ('提交失败：{0}' -f $_.Exception.Message)
    }
}

function Start-StopFlow {
    if ($script:Busy -or -not $script:IsActive) { return }
    $submitAt = [DateTime]::Now

    Show-UiPanel 'home'
    $script:LblHomeError.Visible = $false
    $script:LblHomeProgress.Text = '正在结束值守，等待汇总…'
    $script:LblHomeProgress.Visible = $true
    Set-UiBusy $true

    try {
        $payload = [ordered]@{ action = 'stop' }
        $requestPath = Write-AwayRequest $payload
        Write-UiLog ('stop request: {0}' -f (Split-Path -Leaf $requestPath))

        $deadline = [DateTime]::Now.AddSeconds($script:StopWaitSeconds)
        $summary = $null
        $lastSecond = -1
        while ([DateTime]::Now -lt $deadline) {
            if ($script:Form.IsDisposed) { return }
            if (Test-Path -LiteralPath $script:SummaryPath) {
                try {
                    $mtime = (Get-Item -LiteralPath $script:SummaryPath).LastWriteTime
                    if ($mtime -gt $submitAt) {
                        Start-Sleep -Milliseconds 120
                        $summary = [IO.File]::ReadAllText($script:SummaryPath, [System.Text.Encoding]::UTF8)
                        break
                    }
                } catch {
                }
            }
            $left = [int][math]::Ceiling(($deadline - [DateTime]::Now).TotalSeconds)
            if ($left -ne $lastSecond) {
                $script:LblHomeProgress.Text = '正在结束值守，等待汇总… 还剩 {0} 秒' -f $left
                $lastSecond = $left
            }
            Invoke-UiPulse 300
        }

        if ($null -ne $summary) {
            $script:LblHomeProgress.Visible = $false
            $script:SummaryText = $summary
            $script:TxtSummary.Text = $summary
            Set-SummaryColors
            $script:TxtSummary.SelectionStart = 0
            $script:BtnCopySummary.Text = '复制'
            Show-UiPanel 'summary'
            Set-UiBusy $false
            Update-HomeStatus
            $script:BtnCopySummary.Focus()
            Write-UiLog 'summary shown'
            return
        }

        $script:LblHomeProgress.Visible = $false
        $script:LblHomeError.Text = '没等到汇总（40 秒）。DSH 可能没在运行。'
        $script:LblHomeError.Visible = $true
        Set-UiBusy $false
        Update-HomeStatus
        Write-UiLog 'stop timeout / no summary'
    } catch {
        $script:LblHomeProgress.Visible = $false
        $script:LblHomeError.Text = '结束值守失败：{0}' -f $_.Exception.Message
        $script:LblHomeError.Visible = $true
        Set-UiBusy $false
        Write-UiLog ('stop failed: {0}' -f $_.Exception.Message)
    }
}

function Copy-Summary {
    if ([string]::IsNullOrEmpty($script:SummaryText)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:SummaryText)
        $script:BtnCopySummary.Text = '已复制'
    } catch {
        $script:BtnCopySummary.Text = '复制失败'
    }
}

# ────────────────────────────── 窗口 ──────────────────────────────

function Start-WizardUi {
    param([switch]$DryRun)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

    if ($DryRun) {
        $script:SkipSave = $true
        try {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {
        }
    }

    $script:C = @{
        Bg = [System.Drawing.ColorTranslator]::FromHtml('#F5F7FA')
        White = [System.Drawing.Color]::White
        Text = [System.Drawing.ColorTranslator]::FromHtml('#111827')
        Muted = [System.Drawing.ColorTranslator]::FromHtml('#6B7280')
        Border = [System.Drawing.ColorTranslator]::FromHtml('#D1D5DB')
        Hover = [System.Drawing.ColorTranslator]::FromHtml('#F3F4F6')
        Accent = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
        AccentHover = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
        AccentDown = [System.Drawing.ColorTranslator]::FromHtml('#1E40AF')
        AccentSoft = [System.Drawing.ColorTranslator]::FromHtml('#EFF6FF')
        Danger = [System.Drawing.ColorTranslator]::FromHtml('#DC2626')
        DangerBorder = [System.Drawing.ColorTranslator]::FromHtml('#FCA5A5')
        DangerSoft = [System.Drawing.ColorTranslator]::FromHtml('#FEF2F2')
        Success = [System.Drawing.ColorTranslator]::FromHtml('#16A34A')
        DisabledBg = [System.Drawing.ColorTranslator]::FromHtml('#E5E7EB')
        DisabledFg = [System.Drawing.ColorTranslator]::FromHtml('#9CA3AF')
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '微信值守'
    $form.ClientSize = New-Object System.Drawing.Size(444, 321)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $script:C.Bg
    $form.Font = New-UiFont -Size 9
    $form.ShowInTaskbar = $true
    $script:Form = $form

    # 顶部一条细蓝色装饰
    $strip = New-Object System.Windows.Forms.Panel
    $strip.Bounds = New-Object System.Drawing.Rectangle(0, 0, 444, 3)
    $strip.BackColor = $script:C.Accent
    $form.Controls.Add($strip)

    # 顶部状态区
    $header = New-Object System.Windows.Forms.Panel
    $header.Bounds = New-Object System.Drawing.Rectangle(0, 3, 444, 73)
    $header.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($header)

    $script:StatusDot = New-UiLabel -Text '●' -X 20 -Y 18 -W 20 -H 30 -Size 13 -Kind 'muted' -Align 'MiddleCenter'
    $header.Controls.Add($script:StatusDot)

    $script:StatusLabel = New-UiLabel -Text '正在读取状态…' -X 44 -Y 12 -W 376 -H 30 -Size 13.5 -Kind 'text' -Style 'Bold'
    $script:StatusLabel.AutoEllipsis = $true
    $header.Controls.Add($script:StatusLabel)

    $subLabel = New-UiLabel -Text '离开电脑时，让 DSH 替你回复微信' -X 44 -Y 41 -W 376 -H 18 -Size 8.5 -Kind 'muted'
    $header.Controls.Add($subLabel)

    $headerLine = New-Object System.Windows.Forms.Panel
    $headerLine.Bounds = New-Object System.Drawing.Rectangle(0, 76, 444, 1)
    $headerLine.BackColor = $script:C.Border
    $form.Controls.Add($headerLine)

    # 内容区
    $content = New-Object System.Windows.Forms.Panel
    $content.Bounds = New-Object System.Drawing.Rectangle(0, 77, 444, 244)
    $content.BackColor = $script:C.Bg
    $content.Padding = New-Object System.Windows.Forms.Padding(26, 13, 26, 13)
    $form.Controls.Add($content)

    # ── 首屏 ──
    $script:PanelHome = New-Object System.Windows.Forms.Panel
    $script:PanelHome.Name = 'home'
    $script:PanelHome.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PanelHome.BackColor = $script:C.Bg
    $content.Controls.Add($script:PanelHome)

    $homeHint = New-UiLabel -Text '离开电脑时，DSH 会替你回复微信，并记录来信。' -X 0 -Y 0 -W 392 -H 22 -Size 9 -Kind 'muted'
    $script:PanelHome.Controls.Add($homeHint)

    $script:BtnHomeStart = New-UiButton -Text '开启值守' -X 0 -Y 30 -W 392 -H 58 -Kind 'primary' -Size 12.5
    $script:PanelHome.Controls.Add($script:BtnHomeStart)

    $script:BtnHomeStop = New-UiButton -Text '结束值守' -X 0 -Y 100 -W 392 -H 48 -Kind 'danger' -Size 11.5
    $script:PanelHome.Controls.Add($script:BtnHomeStop)

    $script:LblHomeProgress = New-UiLabel -Text '' -X 0 -Y 154 -W 392 -H 20 -Size 9 -Kind 'accent'
    $script:LblHomeProgress.Visible = $false
    $script:PanelHome.Controls.Add($script:LblHomeProgress)

    $script:LblHomeError = New-UiLabel -Text '' -X 0 -Y 154 -W 392 -H 42 -Size 9 -Kind 'danger' -Align 'TopLeft'
    $script:LblHomeError.Visible = $false
    $script:PanelHome.Controls.Add($script:LblHomeError)

    $homeFoot = New-UiLabel -Text 'DSH 没在运行时，会自动帮你打开。' -X 0 -Y 197 -W 392 -H 18 -Size 8 -Kind 'muted'
    $script:PanelHome.Controls.Add($homeFoot)

    # ── 第一步 ──
    $script:PanelStep1 = New-Object System.Windows.Forms.Panel
    $script:PanelStep1.Name = 'step1'
    $script:PanelStep1.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PanelStep1.BackColor = $script:C.Bg
    $script:PanelStep1.Visible = $false
    $content.Controls.Add($script:PanelStep1)

    $step1Title = New-UiLabel -Text '你去干什么？' -X 0 -Y 0 -W 392 -H 28 -Size 12.5 -Kind 'text' -Style 'Bold'
    $script:PanelStep1.Controls.Add($step1Title)

    $script:TxtActivity = New-Object System.Windows.Forms.TextBox
    $script:TxtActivity.Bounds = New-Object System.Drawing.Rectangle(0, 36, 392, 30)
    $script:TxtActivity.Font = New-UiFont -Size 12
    $script:TxtActivity.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:TxtActivity.BackColor = [System.Drawing.Color]::White
    $script:TxtActivity.ForeColor = $script:C.Text
    $script:TxtActivity.MaxLength = 80
    $script:PanelStep1.Controls.Add($script:TxtActivity)

    $script:LblStep1Hint = New-UiLabel -Text '例如：去上实验课、在开会、手机不在身边' -X 0 -Y 74 -W 392 -H 20 -Size 8.5 -Kind 'muted'
    $script:PanelStep1.Controls.Add($script:LblStep1Hint)

    $script:BtnStepNext = New-UiButton -Text '下一步' -X 0 -Y 168 -W 392 -H 46 -Kind 'primary' -Size 11.5
    $script:PanelStep1.Controls.Add($script:BtnStepNext)

    # ── 第二步 ──
    $script:PanelStep2 = New-Object System.Windows.Forms.Panel
    $script:PanelStep2.Name = 'step2'
    $script:PanelStep2.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PanelStep2.BackColor = $script:C.Bg
    $script:PanelStep2.Visible = $false
    $content.Controls.Add($script:PanelStep2)

    $step2Title = New-UiLabel -Text '什么时候回来？' -X 0 -Y 0 -W 392 -H 28 -Size 12.5 -Kind 'text' -Style 'Bold'
    $script:PanelStep2.Controls.Add($step2Title)

    $script:TxtWhen = New-Object System.Windows.Forms.TextBox
    $script:TxtWhen.Bounds = New-Object System.Drawing.Rectangle(0, 34, 392, 30)
    $script:TxtWhen.Font = New-UiFont -Size 12
    $script:TxtWhen.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:TxtWhen.BackColor = [System.Drawing.Color]::White
    $script:TxtWhen.ForeColor = $script:C.Text
    $script:TxtWhen.MaxLength = 30
    $script:PanelStep2.Controls.Add($script:TxtWhen)

    $script:LblPreview = New-UiLabel -Text '输入一个时间，例如 3:45 或 90分钟' -X 0 -Y 70 -W 392 -H 22 -Size 9 -Kind 'muted'
    $script:PanelStep2.Controls.Add($script:LblPreview)

    $script:LblWarning = New-UiLabel -Text '' -X 0 -Y 94 -W 392 -H 44 -Size 9 -Kind 'danger' -Align 'TopLeft'
    $script:PanelStep2.Controls.Add($script:LblWarning)

    $script:LblProgress = New-UiLabel -Text '' -X 0 -Y 140 -W 244 -H 20 -Size 9 -Kind 'accent'
    $script:PanelStep2.Controls.Add($script:LblProgress)

    $script:BtnOpenDsh = New-UiButton -Text '打开 DSH' -X 250 -Y 138 -W 142 -H 26 -Kind 'outline' -Size 9
    $script:BtnOpenDsh.Visible = $false
    $script:PanelStep2.Controls.Add($script:BtnOpenDsh)

    $script:BtnStepBack = New-UiButton -Text '上一步' -X 0 -Y 170 -W 118 -H 44 -Kind 'secondary' -Size 10.5
    $script:PanelStep2.Controls.Add($script:BtnStepBack)

    $script:BtnStepStart = New-UiButton -Text '开始值守' -X 130 -Y 170 -W 262 -H 44 -Kind 'primary' -Size 11
    $script:PanelStep2.Controls.Add($script:BtnStepStart)

    # ── 汇总 ──
    $script:PanelSummary = New-Object System.Windows.Forms.Panel
    $script:PanelSummary.Name = 'summary'
    $script:PanelSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PanelSummary.BackColor = $script:C.Bg
    $script:PanelSummary.Visible = $false
    $content.Controls.Add($script:PanelSummary)

    $script:TxtSummary = New-Object System.Windows.Forms.RichTextBox
    $script:TxtSummary.Bounds = New-Object System.Drawing.Rectangle(0, 0, 392, 158)
    $script:TxtSummary.Multiline = $true
    $script:TxtSummary.ReadOnly = $true
    $script:TxtSummary.WordWrap = $true
    $script:TxtSummary.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:TxtSummary.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:TxtSummary.BackColor = [System.Drawing.Color]::White
    $script:TxtSummary.ForeColor = $script:C.Text
    $script:TxtSummary.Font = New-UiFont -Size 9.5
    $script:PanelSummary.Controls.Add($script:TxtSummary)

    $script:BtnCopySummary = New-UiButton -Text '复制' -X 0 -Y 168 -W 118 -H 42 -Kind 'secondary' -Size 10.5
    $script:PanelSummary.Controls.Add($script:BtnCopySummary)

    $script:BtnCloseSummary = New-UiButton -Text '关闭' -X 130 -Y 168 -W 262 -H 42 -Kind 'primary' -Size 11
    $script:PanelSummary.Controls.Add($script:BtnCloseSummary)

    # ── 事件 ──
    $script:BtnHomeStart.add_Click({ Open-ActivityStep })
    $script:BtnHomeStop.add_Click({ Start-StopFlow })

    $script:BtnStepNext.add_Click({ Go-TimeStep })
    $script:BtnStepBack.add_Click({
        Show-UiPanel 'home'
        $script:BtnHomeStart.Focus()
    })

    $script:BtnStepStart.add_Click({ Start-AwayFlow })
    $script:BtnOpenDsh.add_Click({ Open-DshAndRetry })

    $script:BtnCopySummary.add_Click({ Copy-Summary })
    $script:BtnCloseSummary.add_Click({ $script:Form.Close() })

    $script:TxtWhen.add_TextChanged({ Update-Step2 })
    $script:TxtActivity.add_TextChanged({
        $script:LblStep1Hint.Text = '例如：去上实验课、在开会、手机不在身边'
        $script:LblStep1Hint.ForeColor = $script:C.Muted
    })

    $script:TxtActivity.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Go-TimeStep
        }
    })
    $script:TxtWhen.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            if ($script:BtnStepStart.Enabled) { Start-AwayFlow }
        }
    })

    $script:PanelHome.Name = 'home'
    $script:PanelStep1.Name = 'step1'
    $script:PanelStep2.Name = 'step2'
    $script:PanelSummary.Name = 'summary'
    Show-UiPanel 'home'

    $script:LastParse = ConvertFrom-AwayTimeInput -Text ''

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 2000
    $script:Timer.add_Tick({ Update-HomeStatus })

    $form.add_FormClosed({
        try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
        try { if ($script:Timer) { $script:Timer.Dispose() } } catch { }
    })

    Update-HomeStatus

    if ($DryRun) {
        $script:DryLines = New-Object 'System.Collections.Generic.List[string]'
        $script:DryElapsed = 0
        $script:DryStage = 0
        $dryTimer = New-Object System.Windows.Forms.Timer
        $dryTimer.Interval = 100
        $dryTimer.add_Tick({
            $script:DryElapsed += 100
            if ($script:DryStage -eq 0 -and $script:DryElapsed -ge 400) {
                $script:DryLines.Add('=== 1) 首屏 ===')
                foreach ($line in (Get-UiTreeLines -Control $script:Form)) { $script:DryLines.Add($line) }
                Open-ActivityStep
                $script:TxtActivity.Text = '去上实验课'
                $script:DryStage = 1
            } elseif ($script:DryStage -eq 1 -and $script:DryElapsed -ge 900) {
                Go-TimeStep
                $script:TxtWhen.Text = '两小时'
                Update-Step2
                $script:DryLines.Add('=== 2) 第二步（时长预览） ===')
                foreach ($line in (Get-UiTreeLines -Control $script:Form)) { $script:DryLines.Add($line) }
                $script:DryStage = 2
            } elseif ($script:DryStage -eq 2 -and $script:DryElapsed -ge 1500) {
                $script:TxtWhen.Text = '25:00'
                Update-Step2
                $script:DryLines.Add('=== 3) 第二步（非法输入警告） ===')
                foreach ($line in (Get-UiTreeLines -Control $script:Form)) { $script:DryLines.Add($line) }
                $script:DryStage = 3
            } elseif ($script:DryStage -eq 3 -and $script:DryElapsed -ge 2100) {
                $dryTimer.Stop()
                $script:DryLines.Add('=== 4) 窗口自动关闭 ===')
                $script:Form.Close()
            }
        })
        $dryTimer.Start()
        [System.Windows.Forms.Application]::Run($form)
        try { $dryTimer.Dispose() } catch { }
        foreach ($line in $script:DryLines) { Write-Output $line }
        Write-Output 'DRYRUN OK：窗口已自动关闭；未启动 DSH，未写入 requests。'
        $form.Dispose()
        return
    }

    $script:Timer.Start()
    [System.Windows.Forms.Application]::Run($form)
    try { $script:Timer.Stop() } catch { }
    $form.Dispose()
}

# ────────────────────────────── 入口 ──────────────────────────────

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Start-WizardUi -DryRun:$DryRun
    } catch {
        $message = $_.Exception.Message
        Write-UiLog ('FATAL: {0}' -f $message)
        if ($DryRun) {
            Write-Output ('DRYRUN FAILED: {0}' -f $message)
            Write-Output $_.ScriptStackTrace
            throw
        }
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                ('微信值守启动失败：{0}{1}{2}' -f $message, [Environment]::NewLine, $_.ScriptStackTrace),
                '微信值守',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {
        }
        exit 1
    }
}
