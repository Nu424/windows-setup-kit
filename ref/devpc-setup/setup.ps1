<#
.SYNOPSIS
    開発用PCの初期セットアップ（Windows 10/11）

.DESCRIPTION
    winget でのアプリ一括インストール、DobotStudio の同梱exeインストール、
    PowerToys 設定の復元、Tailscale / Chromeリモートデスクトップ の初期設定までをまとめて行う。
    何度実行しても壊れないように作ってある（インストール済みはスキップ）。

.EXAMPLE
    # 対話モード（普通はこれ）
    powershell -ExecutionPolicy Bypass -File .\setup.ps1

.EXAMPLE
    # 無人モード。Tailscale も自動ログインさせる
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -TailscaleAuthKey "tskey-auth-xxxx" -Unattended

.EXAMPLE
    # アプリだけ入れて、CRD などの設定はやらない
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SkipCrd -SkipDobot
#>

[CmdletBinding()]
param(
    # Tailscale の Auth key（https://login.tailscale.com/admin/settings/keys で発行）
    [string]$TailscaleAuthKey,

    # 一切の対話をせず、手入力が要るものは全部スキップする
    [switch]$Unattended,

    [switch]$SkipApps,
    [switch]$SkipDobot,
    [switch]$SkipPowerToysConfig,
    [switch]$SkipTailscale,
    [switch]$SkipCrd
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath = Join-Path $Root ("setup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

# ============================================================
#  インストールするアプリ一覧
#    scope: 'machine' = 全ユーザー / 'user' = 自分だけ / $null = winget のお任せ
# ============================================================
$Apps = @(
    @{ Name = 'Google Chrome';  Id = 'Google.Chrome';                Scope = 'machine' }
    @{ Name = 'Tailscale';      Id = 'tailscale.tailscale';          Scope = 'machine' }
    @{ Name = 'PowerToys';      Id = 'Microsoft.PowerToys';          Scope = 'machine' }
    @{ Name = 'Git';            Id = 'Git.Git';                      Scope = 'machine' }
    @{ Name = 'GitHub CLI';     Id = 'GitHub.cli';                   Scope = 'machine' }
    @{ Name = 'uv';             Id = 'astral-sh.uv';                 Scope = $null     }
    @{ Name = 'Volta';          Id = 'Volta.Volta';                  Scope = 'user'    }  # Volta はユーザースコープ必須
    @{ Name = 'VS Code';        Id = 'Microsoft.VisualStudioCode';   Scope = 'machine' }
)

# ============================================================
#  ログ出力まわり
# ============================================================
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $color = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
    $line  = "[{0:HH:mm:ss}] [{1,-5}] {2}" -f (Get-Date), $Level, $Message
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Write-Step {
    param([string]$Title)
    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    Write-Log $Title 'STEP'
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
}

# ============================================================
#  前提チェック
# ============================================================
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host '管理者権限が要るので昇格して再実行する...' -ForegroundColor Yellow

        # 元の引数をそのまま引き継いで昇格起動
        $argList = @('-ExecutionPolicy','Bypass','-File', "`"$($MyInvocation.ScriptName)`"")
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [switch]) {
                if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
            } else {
                $argList += @("-$($kv.Key)", "`"$($kv.Value)`"")
            }
        }
        Start-Process powershell -Verb RunAs -ArgumentList $argList
        exit 0
    }
}

function Assert-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れてから再実行して。' 'ERROR'
        Write-Log 'https://apps.microsoft.com/detail/9nblggh4nns1' 'INFO'
        throw 'winget not found'
    }
    # 規約同意を先に済ませておく（以降のインストールで止まらないように）
    winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    Write-Log ("winget OK ({0})" -f (winget --version)) 'OK'
}

function Update-SessionPath {
    # インストール直後、この PowerShell セッションでも新しいコマンドを使えるようにする
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

# ============================================================
#  1. winget 一括インストール
# ============================================================
function Test-AppInstalled {
    param([string]$Id)
    $out = winget list --id $Id --exact --disable-interactivity 2>&1 | Out-String
    return ($out -match [regex]::Escape($Id))
}

function Install-App {
    param([hashtable]$App)

    if (Test-AppInstalled -Id $App.Id) {
        Write-Log "$($App.Name) : インストール済みなのでスキップ" 'OK'
        return $true
    }

    $baseArgs = @(
        'install', '--id', $App.Id, '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    # scope 指定つきでまず試す → ダメなら scope なしでリトライ
    $attempts = @()
    if ($App.Scope) { $attempts += ,($baseArgs + @('--scope', $App.Scope)) }
    $attempts += ,$baseArgs

    foreach ($a in $attempts) {
        Write-Log "$($App.Name) : インストール中..." 'INFO'
        $p = Start-Process winget -ArgumentList $a -Wait -PassThru -NoNewWindow
        # 0x8A15002B = 既にインストール済み / 該当なし
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq -1978335189) {
            Write-Log "$($App.Name) : 完了" 'OK'
            return $true
        }
        Write-Log "$($App.Name) : exit code $($p.ExitCode) で失敗。条件を変えて再試行" 'WARN'
    }

    Write-Log "$($App.Name) : インストールに失敗した。手動で入れて。" 'ERROR'
    return $false
}

function Invoke-AppInstall {
    Write-Step '1. アプリのインストール (winget)'
    $failed = @()
    foreach ($app in $Apps) {
        try {
            if (-not (Install-App -App $app)) { $failed += $app.Name }
        } catch {
            Write-Log "$($app.Name) : 例外 - $($_.Exception.Message)" 'ERROR'
            $failed += $app.Name
        }
    }
    Update-SessionPath
    if ($failed.Count -gt 0) {
        Write-Log ("失敗したもの: {0}" -f ($failed -join ', ')) 'WARN'
    }
    return $failed
}

# ============================================================
#  2. DobotStudio（同梱 exe）
# ============================================================
function Get-InstallerType {
    <#
        exe のバイナリ冒頭を覗いて、どのインストーラー製かを当てる。
        サイレント引数がインストーラーごとに違うので、その判別用。
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $take  = [Math]::Min($bytes.Length, 3MB)
    $head  = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $take)

    if ($head -match 'Nullsoft')                 { return 'NSIS' }
    if ($head -match 'Inno Setup|JR\.Inno')      { return 'Inno' }
    if ($head -match 'InstallShield')            { return 'InstallShield' }
    if ($head -match 'WixBundle|Burn\.')         { return 'Wix' }
    return 'Unknown'
}

function Get-SilentArgs {
    param([string]$Type)
    switch ($Type) {
        'NSIS'         { return @('/S') }
        'Inno'         { return @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') }
        'InstallShield'{ return @('/s','/v"/qn REBOOT=ReallySuppress"') }
        'Wix'          { return @('/quiet','/norestart') }
        default        { return $null }
    }
}

function Invoke-DobotInstall {
    Write-Step '2. DobotStudio のインストール'

    $installerDir = Join-Path $Root 'installers'
    if (-not (Test-Path $installerDir)) {
        Write-Log "installers フォルダが無い。スキップする。" 'WARN'
        return
    }

    $exe = Get-ChildItem -Path $installerDir -Filter '*Dobot*.exe' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $exe) {
        Write-Log "installers\ に DobotStudio の exe が無い。置いてから再実行して。" 'WARN'
        return
    }

    # 既に入ってないか、ざっくり確認
    $installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                                  -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like '*Dobot*' }
    if ($installed) {
        Write-Log "DobotStudio ($($installed[0].DisplayName)) はインストール済み。スキップ。" 'OK'
        return
    }

    $type       = Get-InstallerType -Path $exe.FullName
    $silentArgs = Get-SilentArgs -Type $type
    Write-Log "$($exe.Name) : インストーラー種別 = $type" 'INFO'

    if ($silentArgs) {
        Write-Log "サイレントインストール中... (引数: $($silentArgs -join ' '))" 'INFO'
        $p = Start-Process $exe.FullName -ArgumentList $silentArgs -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            Write-Log 'DobotStudio : 完了' 'OK'
            return
        }
        Write-Log "サイレント失敗 (exit $($p.ExitCode))。GUI にフォールバックする。" 'WARN'
    } else {
        Write-Log 'サイレント引数が判別できなかった。GUI で起動する。' 'WARN'
    }

    if ($Unattended) {
        Write-Log '無人モードなので GUI 起動はしない。あとで手動で入れて。' 'WARN'
        return
    }

    Write-Log 'インストーラーを起動する。ウィザードを最後まで進めて。' 'INFO'
    Start-Process $exe.FullName -Wait
    Write-Log 'DobotStudio : ウィザード終了' 'OK'

    # ドライバ（CH340 など）も同梱してあれば一緒に入れる
    Get-ChildItem -Path $installerDir -Filter '*driver*' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Log "ドライバ $($_.Name) を実行" 'INFO'
            Start-Process $_.FullName -Wait
        }
}

# ============================================================
#  3. PowerToys 設定の復元
# ============================================================
function Invoke-PowerToysRestore {
    Write-Step '3. PowerToys 設定の復元'

    $src = Join-Path $Root 'config\powertoys'
    if (-not (Test-Path $src) -or -not (Get-ChildItem $src -Force -ErrorAction SilentlyContinue)) {
        Write-Log 'config\powertoys が空。設定の復元はスキップ。' 'WARN'
        Write-Log '移行元PCの %LOCALAPPDATA%\Microsoft\PowerToys の中身をここに入れておくと復元される。' 'INFO'
        return
    }

    $dst = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'

    # 設定を書き換えるので、動いてたら一旦止める
    $wasRunning = $false
    Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue | ForEach-Object {
        $wasRunning = $true
        Write-Log "PowerToys ($($_.ProcessName)) を停止" 'INFO'
        $_ | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning) { Start-Sleep -Seconds 3 }

    # 既存設定はバックアップしてから上書き
    if (Test-Path $dst) {
        $bak = "$dst.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Copy-Item $dst $bak -Recurse -Force
        Write-Log "既存設定を $bak に退避" 'INFO'
    } else {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Write-Log "設定を $dst に復元した" 'OK'

    $ptExe = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
    if (Test-Path $ptExe) {
        Start-Process $ptExe
        Write-Log 'PowerToys を起動した' 'OK'
    }
}

# ============================================================
#  4. Tailscale ログイン
# ============================================================
function Invoke-TailscaleSetup {
    Write-Step '4. Tailscale のセットアップ'

    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $ts)) {
        Write-Log 'tailscale.exe が見つからない。スキップ。' 'WARN'
        return
    }

    $status = & $ts status --json 2>&1 | Out-String
    if ($status -match '"BackendState"\s*:\s*"Running"') {
        Write-Log '既にログイン済み・接続中。スキップ。' 'OK'
        return
    }

    if ($TailscaleAuthKey) {
        Write-Log 'Auth key でログイン中...' 'INFO'
        & $ts up --authkey=$TailscaleAuthKey --unattended
        if ($LASTEXITCODE -eq 0) { Write-Log 'Tailscale : 接続完了' 'OK' }
        else { Write-Log "Tailscale : ログイン失敗 (exit $LASTEXITCODE)" 'ERROR' }
        return
    }

    if ($Unattended) {
        Write-Log 'Auth key が無いのでスキップ。-TailscaleAuthKey を渡すと無人でいける。' 'WARN'
        return
    }

    Write-Log 'ブラウザが開くのでログインして。' 'INFO'
    & $ts up
}

# ============================================================
#  5. Chrome リモートデスクトップ（ホスト側）
# ============================================================
function Invoke-CrdSetup {
    Write-Step '5. Chrome リモートデスクトップ'

    if ($Unattended) {
        Write-Log '無人モードではワンタイムコードを取れないのでスキップ。' 'WARN'
        return
    }

    # ホストサービス本体を winget で入れる
    if (-not (Test-AppInstalled -Id 'Google.ChromeRemoteDesktop')) {
        Write-Log 'Chrome Remote Desktop Host をインストール中...' 'INFO'
        Start-Process winget -Wait -NoNewWindow -ArgumentList @(
            'install','--id','Google.ChromeRemoteDesktop','--exact','--source','winget',
            '--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
        ) | Out-Null
    }

    $starter = Get-ChildItem 'C:\Program Files (x86)\Google\Chrome Remote Desktop',
                             'C:\Program Files\Google\Chrome Remote Desktop' `
                             -Filter 'remoting_start_host.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1

    if (-not $starter) {
        Write-Log 'remoting_start_host.exe が見つからない。ホストのインストールに失敗した可能性。' 'ERROR'
        Write-Log '手動なら https://remotedesktop.google.com/access から入れられる。' 'INFO'
        return
    }

    Write-Host ''
    Write-Host '  ブラウザで次のページを開いて、Googleアカウントでログイン:' -ForegroundColor Yellow
    Write-Host '    https://remotedesktop.google.com/headless' -ForegroundColor White
    Write-Host '  「別のパソコンをセットアップ」→ 開始 → 次へ → 承認 と進むと、' -ForegroundColor Yellow
    Write-Host '  Windows(Cmd) 用のコマンドが表示される。その中の --code="..." の中身だけコピー。' -ForegroundColor Yellow
    Write-Host '  (コードは数分で失効するので、コピーしたらすぐ貼って)' -ForegroundColor DarkYellow
    Write-Host ''

    try { Start-Process 'https://remotedesktop.google.com/headless' } catch { }

    $code = Read-Host '  認証コード (空Enterでスキップ)'
    if ([string]::IsNullOrWhiteSpace($code)) {
        Write-Log 'スキップした。あとで手動で設定して。' 'WARN'
        return
    }

    # 丸ごと貼られても救えるようにしておく
    if ($code -match '--code="?([^"\s]+)"?') { $code = $Matches[1] }

    do {
        $pin1 = Read-Host '  接続用PIN (6桁以上)' -AsSecureString
        $pin2 = Read-Host '  もう一度' -AsSecureString
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin1))
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin2))
        if ($p1 -ne $p2)        { Write-Host '  一致しない。もう一回。' -ForegroundColor Red; continue }
        if ($p1.Length -lt 6)   { Write-Host '  6桁以上にして。'        -ForegroundColor Red; continue }
        break
    } while ($true)

    $hostName = $env:COMPUTERNAME
    Write-Log "ホスト登録中... (name=$hostName)" 'INFO'

    & $starter.FullName `
        --code="$code" `
        --redirect-url="https://remotedesktop.google.com/_/oauthredirect" `
        --name="$hostName" `
        --pin="$p1"

    if ($LASTEXITCODE -eq 0) {
        Write-Log 'CRD : 登録完了。remotedesktop.google.com/access に出てくるはず。' 'OK'
        # サービスを自動起動にしておく（手動のままだと再起動後に繋がらないことがある）
        $svc = Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name 'chromoting' -StartupType Automatic
            if ($svc.Status -ne 'Running') { Start-Service 'chromoting' }
            Write-Log 'chromoting サービスを自動起動に設定した' 'OK'
        }
    } else {
        Write-Log "CRD : 登録失敗 (exit $LASTEXITCODE)。コードが失効した可能性が高いので、取り直して再実行して。" 'ERROR'
    }
}

# ============================================================
#  6. 最後の仕上げ
# ============================================================
function Invoke-PostSetup {
    Write-Step '6. 仕上げ'
    Update-SessionPath

    # Volta 経由で Node LTS を入れておく
    if (Get-Command volta -ErrorAction SilentlyContinue) {
        try {
            $installedNode = & volta list node 2>&1 | Out-String
            if ($installedNode -notmatch 'v\d+\.\d+') {
                Write-Log 'volta で Node LTS を導入中...' 'INFO'
                & volta install node@lts
                Write-Log 'Node LTS : 完了' 'OK'
            } else {
                Write-Log 'Node は導入済み' 'OK'
            }
        } catch { Write-Log "volta: $($_.Exception.Message)" 'WARN' }
    }

    # gh のログイン（ブラウザ認証）
    if ((Get-Command gh -ErrorAction SilentlyContinue) -and -not $Unattended) {
        $auth = & gh auth status 2>&1 | Out-String
        if ($auth -match 'not logged in|認証されていません') {
            Write-Host ''
            $ans = Read-Host '  GitHub CLI にログインする? [Y/n]'
            if ($ans -notmatch '^[nN]') { & gh auth login }
        } else {
            Write-Log 'gh : ログイン済み' 'OK'
        }
    }
}

function Show-Summary {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Green
    Write-Host '  セットアップ完了' -ForegroundColor Green
    Write-Host ('=' * 60) -ForegroundColor Green
    Write-Host ''
    Write-Host '  ▼ ここから先は手作業が必要:' -ForegroundColor Yellow
    Write-Host '    1. Chrome を開いて Google アカウントでログイン → 同期をON'
    Write-Host '       (拡張機能・ブックマーク・パスワードはこれで全部降ってくる)'
    Write-Host '    2. git の名前とメール:'
    Write-Host '         git config --global user.name  "Your Name"'
    Write-Host '         git config --global user.email "you@example.com"'
    Write-Host '    3. VS Code の設定同期 (左下のアカウント → 設定の同期をオン)'
    Write-Host '    4. DobotStudio は初回起動時にロボットの接続確認を'
    Write-Host ''
    Write-Host "  ログ: $LogPath" -ForegroundColor DarkGray
    Write-Host '  ※ PATH を反映させるため、ターミナルは開き直して。' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================
#  実行
# ============================================================
try {
    Assert-Admin
    Write-Host ''
    Write-Host '  開発用PC セットアップ' -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  /  $env:COMPUTERNAME  /  $env:USERNAME" -ForegroundColor DarkGray

    Assert-Winget

    if (-not $SkipApps)            { Invoke-AppInstall        | Out-Null }
    if (-not $SkipDobot)           { Invoke-DobotInstall }
    if (-not $SkipPowerToysConfig) { Invoke-PowerToysRestore }
    if (-not $SkipTailscale)       { Invoke-TailscaleSetup }
    if (-not $SkipCrd)             { Invoke-CrdSetup }

    Invoke-PostSetup
    Show-Summary
}
catch {
    Write-Log "致命的エラー: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    exit 1
}
