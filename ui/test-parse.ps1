<#
  解析函数回归测试。直接 dot-source wizard.ps1（入口 guard 会跳过界面）。
  运行： powershell -NoProfile -ExecutionPolicy Bypass -File .\test-parse.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wizard = Join-Path $here 'wizard.ps1'
if (-not (Test-Path -LiteralPath $wizard)) {
    Write-Host "找不到 wizard.ps1：$wizard" -ForegroundColor Red
    exit 2
}
. $wizard

$now = [DateTimeOffset]::new(2026, 11, 11, 1, 0, 0, [TimeSpan]::FromHours(8))
$nowLate = [DateTimeOffset]::new(2026, 11, 11, 19, 10, 0, [TimeSpan]::FromHours(8))
$nowNight = [DateTimeOffset]::new(2026, 11, 11, 23, 0, 0, [TimeSpan]::FromHours(8))

$cases = @(
    @{ Text = '3:45'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45; Preview = '→ 今天 03:45 回来（时刻）' }
    @{ Text = '3.45'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '3点45'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '3点45分'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '三点四十五'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '十五点'; Kind = 'clock'; Valid = $true; Hour = 15; Minute = 0 }
    @{ Text = '15'; Kind = 'clock'; Valid = $true; Hour = 15; Minute = 0 }
    @{ Text = '15:30'; Kind = 'clock'; Valid = $true; Hour = 15; Minute = 30 }
    @{ Text = '23:59'; Kind = 'clock'; Valid = $true; Hour = 23; Minute = 59 }
    @{ Text = '3点半'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 30 }
    @{ Text = '3点一刻'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 15 }
    @{ Text = '3点三刻'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '晚上9点'; Kind = 'clock'; Valid = $true; Hour = 21; Minute = 0 }
    @{ Text = '下午3:45'; Kind = 'clock'; Valid = $true; Hour = 15; Minute = 45 }
    @{ Text = '今天3:45'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '3:45回来'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }
    @{ Text = '大概3:45'; Kind = 'clock'; Valid = $true; Hour = 3; Minute = 45 }

    @{ Text = '90分钟'; Kind = 'duration'; Valid = $true; DurationMinutes = 90; Until = '02:30'; Preview = '→ 1 小时 30 分钟后回来，约 02:30（时长）' }
    @{ Text = '一个半小时'; Kind = 'duration'; Valid = $true; DurationMinutes = 90 }
    @{ Text = '两小时'; Kind = 'duration'; Valid = $true; DurationMinutes = 120; Preview = '→ 2 小时后回来，约 03:00（时长）' }
    @{ Text = '两个小时'; Kind = 'duration'; Valid = $true; DurationMinutes = 120 }
    @{ Text = '半小时'; Kind = 'duration'; Valid = $true; DurationMinutes = 30 }
    @{ Text = '1小时20分钟'; Kind = 'duration'; Valid = $true; DurationMinutes = 80 }
    @{ Text = '1小时'; Kind = 'duration'; Valid = $true; DurationMinutes = 60 }
    @{ Text = '2小时30分钟'; Kind = 'duration'; Valid = $true; DurationMinutes = 150 }

    @{ Text = '9:00'; Now = $nowLate; Kind = 'past'; Valid = $false; Hour = 9; Minute = 0; Warning = '19:10 已经过了 9:00 — 你是说今晚，还是明早？'; Preview = '→ 今天 09:00 回来（时刻）' }
    @{ Text = '两小时'; Now = $nowNight; Kind = 'duration'; Valid = $true; DurationMinutes = 120; Until = '01:00'; Preview = '→ 2 小时后回来，约 明天 01:00（时长）' }
    @{ Text = '90分钟'; Now = $nowNight; Kind = 'duration'; Valid = $true; DurationMinutes = 90; Until = '00:30' }

    @{ Text = '25:00'; Kind = 'invalid'; Valid = $false }
    @{ Text = '24:00'; Kind = 'invalid'; Valid = $false }
    @{ Text = '3:75'; Kind = 'invalid'; Valid = $false }
    @{ Text = '3.4'; Kind = 'invalid'; Valid = $false }
    @{ Text = 'abc'; Kind = 'invalid'; Valid = $false }
    @{ Text = ''; Kind = 'empty'; Valid = $false }
    @{ Text = '   '; Kind = 'empty'; Valid = $false }
)

function Get-CaseValue {
    param($Object, [string]$Name)
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

$pass = 0
$fail = 0
$index = 0

foreach ($case in $cases) {
    $index++
    $caseNow = if ($case.ContainsKey('Now')) { $case['Now'] } else { $now }
    $r = ConvertFrom-AwayTimeInput -Text $case['Text'] -Now $caseNow
    $problems = New-Object 'System.Collections.Generic.List[string]'

    foreach ($key in @('Kind', 'Valid', 'Hour', 'Minute', 'DurationMinutes', 'Preview', 'Warning')) {
        if (-not $case.ContainsKey($key)) { continue }
        $expected = $case[$key]
        $actual = Get-CaseValue $r $key
        if ($null -eq $expected) {
            if ($null -ne $actual) { $problems.Add("$key expected <null> got [$actual]") }
        } elseif ("$actual" -ne "$expected") {
            $problems.Add("$key expected [$expected] got [$actual]")
        }
    }

    if ($case.ContainsKey('Until')) {
        $until = Get-CaseValue $r 'UntilAt'
        $actualUntil = if ($until) { $until.ToString('HH:mm') } else { '' }
        if ($actualUntil -ne $case['Until']) {
            $problems.Add(("Until expected [{0}] got [{1}]" -f $case['Until'], $actualUntil))
        }
    }

    if ($case['Kind'] -eq 'invalid' -and [string]::IsNullOrWhiteSpace([string](Get-CaseValue $r 'Error'))) {
        $problems.Add('invalid case has empty Error')
    }

    if ($problems.Count -eq 0) {
        $pass++
        Write-Host ('PASS {0,2}  {1}' -f $index, $case['Text'])
    } else {
        $fail++
        Write-Host ('FAIL {0,2}  {1}' -f $index, $case['Text']) -ForegroundColor Red
        foreach ($problem in $problems) {
            Write-Host ('       - {0}' -f $problem) -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host ('解析用例：PASS {0} / FAIL {1} / 共 {2}' -f $pass, $fail, $cases.Count)
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'
