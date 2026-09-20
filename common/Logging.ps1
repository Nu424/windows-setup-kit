<#
    画面表示・ログファイル・結果サマリ。
    どの分類もメッセージ出力はこの関数群を通す。

    Level の使い分け:
      INFO 途中経過 / OK 変更した・確認できた / SKIP 何もしなかった
      WARN 続行するが人間の確認が要る / FAIL その項目は失敗した
      DRY  DryRun で実行しなかった / STEP 見出し
    OK / SKIP / WARN / FAIL はサマリに集計される。
#>

$script:SetupResults = [System.Collections.Generic.List[object]]::new()
$script:SetupLogPath = $null
$script:SetupDryRun  = $false

function Initialize-SetupLog {
    param(
        [AllowEmptyString()][string]$LogPath,
        [switch]$DryRun
    )
    $script:SetupLogPath = $LogPath
    $script:SetupDryRun  = [bool]$DryRun
    $script:SetupResults.Clear()

    if ($LogPath) {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Test-DryRun {
    return $script:SetupDryRun
}

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','OK','SKIP','WARN','FAIL','DRY','STEP')][string]$Level = 'INFO'
    )

    $color = @{
        INFO = 'Gray'; OK   = 'Green';  SKIP = 'DarkGray'; WARN = 'Yellow'
        FAIL = 'Red';  DRY  = 'Magenta'; STEP = 'Cyan'
    }[$Level]

    $line = "[{0:HH:mm:ss}] [{1,-4}] {2}" -f (Get-Date), $Level, $Message
    Write-Host $line -ForegroundColor $color

    if ($Level -in 'OK','SKIP','WARN','FAIL') {
        $script:SetupResults.Add([pscustomobject]@{ Level = $Level; Message = $Message })
    }

    if ($script:SetupLogPath) {
        # ログが書けないだけで本処理を止める理由はない
        try { Add-Content -Path $script:SetupLogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

# 「変更した」の定型出力。DryRun のときは実行していないので DRY になる。
function Write-Change {
    param([Parameter(Mandatory)][string]$Message)

    if ($script:SetupDryRun) { Write-Log $Message 'DRY' }
    else                     { Write-Log $Message 'OK'  }
}

function Write-SetupStep {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkCyan
    Write-Log $Title 'STEP'
    Write-Host ('-' * 64) -ForegroundColor DarkCyan
}

function Get-SetupFailureCount {
    return @($script:SetupResults | Where-Object { $_.Level -eq 'FAIL' }).Count
}

function Write-SetupSummary {
    $ok   = @($script:SetupResults | Where-Object { $_.Level -eq 'OK'   }).Count
    $skip = @($script:SetupResults | Where-Object { $_.Level -eq 'SKIP' }).Count
    $warn = @($script:SetupResults | Where-Object { $_.Level -eq 'WARN' }).Count
    $fail = @($script:SetupResults | Where-Object { $_.Level -eq 'FAIL' }).Count

    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor White
    Write-Host '  結果' -ForegroundColor White
    Write-Host ('=' * 64) -ForegroundColor White
    Write-Host ("  OK: {0}   SKIP: {1}   WARN: {2}   FAIL: {3}" -f $ok, $skip, $warn, $fail)

    if ($warn -gt 0 -or $fail -gt 0) {
        Write-Host ''
        Write-Host '  要確認:' -ForegroundColor Yellow
        foreach ($r in $script:SetupResults) {
            if ($r.Level -notin 'WARN','FAIL') { continue }
            $c = if ($r.Level -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host "    [$($r.Level)] $($r.Message)" -ForegroundColor $c
        }
    }

    if ($script:SetupLogPath) {
        Write-Host ''
        Write-Host "  ログ: $($script:SetupLogPath)" -ForegroundColor DarkGray
    }
}
