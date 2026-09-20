<#
.SYNOPSIS
    Windows のセットアップをまとめて実行する。

.DESCRIPTION
    このファイルは「何をどの順で流すか」だけを持つ。処理の中身は分類ごとに分かれている。
      common\          ... 全分類が使う土台 (ログ / 昇格 / レジストリ / 設定読み込み)
      windows-settings\ ... Windows そのものの設定
      app-install\      ... ソフトのインストール
      app-config\       ... 入れたソフトの設定・ログイン

    設定値はルートの settings.ps1。無ければ既定値で動き、足りない値は実行時に聞く。
    管理者権限は自動で昇格して取り直す (元ユーザーの SID を引き継ぐ)。

.EXAMPLE
    # 普通はこれ (Setup.cmd をダブルクリックしても同じ)
    powershell -ExecutionPolicy Bypass -File .\setup.ps1

.EXAMPLE
    # 何が起きるかだけ見る。実際には変更しない
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -DryRun

.EXAMPLE
    # 一切聞かずに流す。手入力が要るものは全部スキップされる
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Unattended -TailscaleAuthKey 'tskey-auth-xxxx'

.EXAMPLE
    # ソフトのインストールだけやり直す
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SkipWindowsSettings -SkipAppConfig
#>

[CmdletBinding()]
param(
    # 実際には変更せず、何をやるかだけ表示する
    [switch]$DryRun,

    # 一切の対話をせず、手入力が要るものは全部スキップする
    [switch]$Unattended,

    # 分類ごとにまとめて飛ばす
    [switch]$SkipWindowsSettings,
    [switch]$SkipAppInstall,
    [switch]$SkipAppConfig,

    # 項目ごとに飛ばす
    [switch]$SkipWifi,
    [switch]$SkipWinget,
    [switch]$SkipInstallers,
    [switch]$SkipPowerToys,
    [switch]$SkipTailscale,
    [switch]$SkipCrd,
    [switch]$SkipDevTools,

    # settings.ps1 の AppConfig.Tailscale.AuthKey より優先される
    [string]$TailscaleAuthKey,

    # 内部用。昇格時に元ユーザーの SID を引き継ぐ。手で指定する必要はない
    [string]$UserSid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# common を先に読む。以降の分類スクリプトはここで定義した関数を使う
foreach ($relative in @(
    'common\Logging.ps1'
    'common\Elevation.ps1'
    'common\Registry.ps1'
    'common\Environment.ps1'
    'common\Native.ps1'
    'common\Settings.ps1'
    'windows-settings\WindowsSettings.ps1'
    'windows-settings\Wifi.ps1'
    'app-install\WingetApps.ps1'
    'app-install\LocalInstallers.ps1'
    'app-config\PowerToys.ps1'
    'app-config\Tailscale.ps1'
    'app-config\ChromeRemoteDesktop.ps1'
    'app-config\DevTools.ps1'
)) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "[!] $relative が見つからない。フォルダごとコピーできているか確認する。" -ForegroundColor Red
        return
    }
    . $path
}


# ------------------------------------------------------------
#  昇格 (管理者でなければ、元ユーザーの SID を渡して開き直す)
# ------------------------------------------------------------
if (-not (Test-Administrator)) {
    if (-not $PSCommandPath) {
        Write-Host '[!] コンソールに貼り付けた場合は自動昇格できない。setup.ps1 として保存して実行する。' -ForegroundColor Red
        return
    }
    Write-Host '[*] 管理者権限が必要なので昇格して開き直す...' -ForegroundColor Cyan
    if (Start-ElevatedSetup -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -UserSid (Get-CurrentUserSid)) {
        return
    }
    Write-Host '[!] 昇格がキャンセルされた。管理者権限が要るのでここで終了する。' -ForegroundColor Red
    return
}

# 昇格で実行アカウントが変わっていても、ユーザー単位の設定は元のユーザーに入れる
if (-not $UserSid) { $UserSid = Get-CurrentUserSid }


# ------------------------------------------------------------
#  ログの用意 (USB が書き込み禁止のこともあるので TEMP に逃げられるようにする)
# ------------------------------------------------------------
$logName = 'setup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)
$logPath = Join-Path $Root $logName
try {
    [IO.File]::AppendAllText($logPath, '')
} catch {
    $logPath = Join-Path $env:TEMP $logName
}
Initialize-SetupLog -LogPath $logPath -DryRun:$DryRun

Write-Host ''
Write-Host '############################################' -ForegroundColor White
Write-Host '#  Windows セットアップ                    #' -ForegroundColor White
Write-Host '############################################' -ForegroundColor White
if ($DryRun)     { Write-Host '*** DRY RUN : 実際の変更は行わない ***'          -ForegroundColor Magenta }
if ($Unattended) { Write-Host '*** 無人モード : 対話が要るものはスキップする ***' -ForegroundColor Magenta }

Write-Log ("実行アカウント: {0} / 設定対象ユーザー: {1}" -f (Get-CurrentUserName), (Resolve-UserName -Sid $UserSid))

$Settings = Import-SetupSettings -Root $Root
if ($TailscaleAuthKey) {
    # コマンドラインで渡されたキーは settings.ps1 より優先する
    $Settings.AppConfig.Tailscale.AuthKey = $TailscaleAuthKey
}


# ------------------------------------------------------------
#  分類の実行
# ------------------------------------------------------------
$script:NeedReboot = $false

<#
    1 つの処理を実行する。スキップ指定ならその旨を残して何もしない。
    想定外の例外で残りの分類まで道連れにしないよう、ここで受け止める。
#>
function Invoke-SetupStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Skip,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    if ($Skip) {
        Write-Log "$Name : スキップ指定なので実行しない" 'SKIP'
        return
    }
    try {
        & $Body | Out-Null
    } catch {
        Write-Log "$Name の実行中に想定外のエラー: $($_.Exception.Message)" 'FAIL'
        Write-Log $_.ScriptStackTrace 'INFO'
    }
}

# 1. Windows そのものの設定
Invoke-SetupStage -Name 'Windows の設定' -Skip $SkipWindowsSettings -Body {
    $script:NeedReboot = Invoke-WindowsSettings -Settings $Settings -UserSid $UserSid -Unattended:$Unattended
}
Invoke-SetupStage -Name 'WiFi' -Skip ($SkipWindowsSettings -or $SkipWifi) -Body {
    Invoke-WifiSetup -Settings $Settings -Root $Root -Unattended:$Unattended
}

# 2. ソフトのインストール
Invoke-SetupStage -Name 'winget でのインストール' -Skip ($SkipAppInstall -or $SkipWinget) -Body {
    Invoke-WingetApps -Settings $Settings
}
Invoke-SetupStage -Name '同梱インストーラ' -Skip ($SkipAppInstall -or $SkipInstallers) -Body {
    Invoke-LocalInstallers -Settings $Settings -Root $Root -Unattended:$Unattended
}

# 3. 入れたソフトの設定 (インストール済みが前提なので、必ずこの順で)
Invoke-SetupStage -Name 'PowerToys の設定復元' -Skip ($SkipAppConfig -or $SkipPowerToys) -Body {
    Invoke-PowerToysRestore -Settings $Settings -Root $Root
}
Invoke-SetupStage -Name 'Tailscale' -Skip ($SkipAppConfig -or $SkipTailscale) -Body {
    Invoke-TailscaleSetup -Settings $Settings -Unattended:$Unattended
}
Invoke-SetupStage -Name 'Chrome リモートデスクトップ' -Skip ($SkipAppConfig -or $SkipCrd) -Body {
    Invoke-CrdSetup -Settings $Settings -Unattended:$Unattended
}
Invoke-SetupStage -Name '開発ツールの仕上げ' -Skip ($SkipAppConfig -or $SkipDevTools) -Body {
    Invoke-DevToolsSetup -Settings $Settings -Unattended:$Unattended
}


# ------------------------------------------------------------
#  仕上げ
# ------------------------------------------------------------
Write-SetupSummary

Write-Host ''
Write-Host '  ここから先は手作業 (自動化できない):' -ForegroundColor Yellow
Write-Host '    1. Chrome に Google アカウントでログインして同期をON'
Write-Host '       (拡張機能・ブックマーク・パスワードはこれで降ってくる)'
Write-Host '    2. VS Code の設定同期 (左下のアカウント -> 設定の同期をオン)'
Write-Host '    3. 同梱インストーラで入れたソフトの初回起動確認'
Write-Host '    4. Claude Code: ターミナルで claude を実行してブラウザログイン'
Write-Host ''
Write-Host '  ※ PATH を反映させるため、作業を続けるならターミナルを開き直す。' -ForegroundColor DarkGray

if ($script:NeedReboot) {
    Write-Host ''
    if (Confirm-Setup -Question 'PC名の変更を反映するため今すぐ再起動する?' -Default $false -Unattended:$Unattended) {
        Restart-Computer -Force
    } else {
        Write-Log 'PC名の変更は次回の再起動で反映される' 'INFO'
    }
}

# 昇格で開いた別ウィンドウがそのまま閉じると結果が読めない
if (-not $Unattended) {
    Write-Host ''
    [void](Read-Host '終了するには Enter キーを押す')
}

exit $(if ((Get-SetupFailureCount) -gt 0) { 1 } else { 0 })
