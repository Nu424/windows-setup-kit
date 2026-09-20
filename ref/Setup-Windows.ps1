<#
.SYNOPSIS
    Windows の初期設定をまとめて適用する。

.DESCRIPTION
    PC名 / 電源タイムアウト / RDP / 拡張子表示 / 隠しファイル表示 /
    クリップボード履歴 / WiFi / OneDriveスタートアップ無効化 を一括設定する。

    管理者権限が必要な項目と、ユーザー単位(HKCU)の項目が混在するため、
    非管理者で起動された場合は「元のユーザーのSID」を引き継いで自動昇格する。
    これにより、別の管理者アカウントで昇格しても設定が正しいユーザーに入る。

.PARAMETER DryRun
    実際には変更せず、何をやるかだけ表示する。

.PARAMETER UserSid
    内部用。自動昇格時に元ユーザーのSIDを引き継ぐ。手動指定は不要。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-Windows.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File .\Setup-Windows.ps1
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$UserSid
)

# ============================================================
#  設定 : ここだけ書き換えれば OK
#  $null / '' にした項目はスキップされる
# ============================================================
$Config = @{

    # --- PC名 (15文字以内 / 英数字とハイフンのみ) ---
    ComputerName        = 'MY-PC'

    # --- 電源タイムアウト (分 / 0 = 「なし」) ---
    #     AC = 電源接続時, DC = バッテリー駆動時
    MonitorTimeoutAC    = 15
    MonitorTimeoutDC    = 5
    StandbyTimeoutAC    = 0      # 0 = スリープしない
    StandbyTimeoutDC    = 30

    # --- リモートデスクトップ ---
    EnableRdp           = $true
    RdpRequireNla       = $true   # ネットワークレベル認証(推奨)

    # --- エクスプローラ ---
    ShowFileExtensions  = $true
    ShowHiddenFiles     = $true
    ShowSuperHidden     = $false  # 保護されたOSファイルまで出す。普通は $false

    # --- クリップボード履歴 (Win+V) ---
    EnableClipboardHistory = $true

    # --- WiFi ---
    #  A) 既存機からエクスポートしたXMLを使う場合:
    #       netsh wlan export profile name="SSID" key=clear folder="C:\temp"
    #     で出したファイルのパスを WifiProfileXml に指定
    #  B) SSID / パスワード直書き(WPA2-PSK/AES)で生成する場合:
    #     WifiSsid と WifiPassword を指定
    WifiProfileXml      = ''      # 例: 'C:\temp\Wi-Fi-MySSID.xml'
    WifiSsid            = ''      # 例: 'MyHomeWiFi'
    WifiPassword        = ''      # ★平文。Git等に上げないこと
    WifiConnectAfter    = $true   # 設定後に接続を試みる

    # --- スタートアップ無効化 ---
    DisableStartupApps  = @('OneDrive')

    # --- 実行ポリシー (LocalMachine) ---
    #  $null ならいじらない。'RemoteSigned' 等を指定すると恒久変更。
    SetExecutionPolicy  = $null

    # --- 仕上げ ---
    RestartExplorer     = $true   # エクスプローラ設定の即時反映に必要
}
# ============================================================


# ------------------------------------------------------------
#  昇格処理 (元ユーザーのSIDを引き継ぐ)
# ------------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$currentIdentity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        Write-Host '[!] コンソールに直接貼り付けた場合は自動昇格できません。' -ForegroundColor Red
        Write-Host '    .ps1 として保存してから実行してください。' -ForegroundColor Red
        return
    }
    Write-Host '[*] 管理者権限が必要なため昇格します...' -ForegroundColor Cyan
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-UserSid', $currentIdentity.User.Value
    )
    if ($DryRun) { $argList += '-DryRun' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host '[!] 昇格がキャンセルされました。' -ForegroundColor Red
    }
    return
}

# 対象ユーザーのSIDを確定
if (-not $UserSid) { $UserSid = $currentIdentity.User.Value }
$UserHive = "Registry::HKEY_USERS\$UserSid"


# ------------------------------------------------------------
#  ログ用ヘルパー
# ------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()

function Write-Head($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "  [OK]   $msg" -ForegroundColor Green
                            $script:Results.Add([pscustomobject]@{S='OK'   ;M=$msg}) }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray
                            $script:Results.Add([pscustomobject]@{S='SKIP' ;M=$msg}) }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow
                            $script:Results.Add([pscustomobject]@{S='WARN' ;M=$msg}) }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red
                            $script:Results.Add([pscustomobject]@{S='FAIL' ;M=$msg}) }
function Write-Dry ($msg) { Write-Host "  [DRY]  $msg" -ForegroundColor Magenta }

# レジストリ値の設定 (親キーが無ければ作る)
function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','Binary','ExpandString','QWord')]
        [string]$Type = 'DWord'
    )
    if ($DryRun) { Write-Dry "$Path\$Name = $Value"; return }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type `
                     -Force -ErrorAction Stop | Out-Null
}


# ------------------------------------------------------------
#  開始
# ------------------------------------------------------------
Write-Host ''
Write-Host '############################################' -ForegroundColor White
Write-Host '#  Windows 初期設定スクリプト              #' -ForegroundColor White
Write-Host '############################################' -ForegroundColor White
if ($DryRun) {
    Write-Host '*** DRY RUN モード : 実際の変更は行いません ***' -ForegroundColor Magenta
}

# 対象ユーザーの確認
try {
    $targetUser = (New-Object Security.Principal.SecurityIdentifier($UserSid)).
                   Translate([Security.Principal.NTAccount]).Value
} catch { $targetUser = $UserSid }

Write-Host ''
Write-Host "  実行アカウント : $($currentIdentity.Name)"
Write-Host "  設定対象ユーザー: $targetUser"

if (-not (Test-Path $UserHive)) {
    Write-Host ''
    Write-Warn "対象ユーザーのレジストリハイブが読み込まれていません ($UserSid)"
    Write-Warn 'ユーザー単位の設定(拡張子/隠しファイル/クリップボード/スタートアップ)はスキップされます'
    $userHiveOk = $false
} else {
    $userHiveOk = $true
}


# ------------------------------------------------------------
#  1. 実行ポリシー
# ------------------------------------------------------------
Write-Head '実行ポリシー'
if ($Config.SetExecutionPolicy) {
    $cur = Get-ExecutionPolicy -Scope LocalMachine
    if ($cur -eq $Config.SetExecutionPolicy) {
        Write-Skip "既に $cur"
    } elseif ($DryRun) {
        Write-Dry "LocalMachine: $cur -> $($Config.SetExecutionPolicy)"
    } else {
        try {
            Set-ExecutionPolicy -ExecutionPolicy $Config.SetExecutionPolicy `
                                -Scope LocalMachine -Force -ErrorAction Stop
            Write-Ok "LocalMachine: $cur -> $($Config.SetExecutionPolicy)"
        } catch { Write-Fail "実行ポリシー変更に失敗: $($_.Exception.Message)" }
    }
} else {
    Write-Skip '変更しない設定(現状維持)'
}


# ------------------------------------------------------------
#  2. PC名
# ------------------------------------------------------------
Write-Head 'PC名'
$needReboot = $false
if ($Config.ComputerName) {
    $new = $Config.ComputerName
    if ($new -eq $env:COMPUTERNAME) {
        Write-Skip "既に '$new'"
    } elseif ($new.Length -gt 15 -or $new -notmatch '^[A-Za-z0-9\-]+$' -or $new -match '^\d+$') {
        Write-Fail "PC名が不正: '$new' (15文字以内 / 英数字とハイフン / 数字のみ不可)"
    } elseif ($DryRun) {
        Write-Dry "$env:COMPUTERNAME -> $new  (要再起動)"
    } else {
        try {
            Rename-Computer -NewName $new -Force -ErrorAction Stop | Out-Null
            Write-Ok "$env:COMPUTERNAME -> $new  (再起動後に反映)"
            $needReboot = $true
        } catch { Write-Fail "PC名変更に失敗: $($_.Exception.Message)" }
    }
} else { Write-Skip '未指定' }


# ------------------------------------------------------------
#  3. 電源タイムアウト
# ------------------------------------------------------------
Write-Head '電源タイムアウト'
$powerMap = @(
    @{ Key='monitor-timeout-ac'; Val=$Config.MonitorTimeoutAC; Label='画面オフ (電源接続)' }
    @{ Key='monitor-timeout-dc'; Val=$Config.MonitorTimeoutDC; Label='画面オフ (バッテリー)' }
    @{ Key='standby-timeout-ac'; Val=$Config.StandbyTimeoutAC; Label='スリープ (電源接続)' }
    @{ Key='standby-timeout-dc'; Val=$Config.StandbyTimeoutDC; Label='スリープ (バッテリー)' }
)
foreach ($p in $powerMap) {
    if ($null -eq $p.Val) { Write-Skip "$($p.Label) : 未指定"; continue }
    $disp = if ($p.Val -eq 0) { 'なし' } else { "$($p.Val)分" }
    if ($DryRun) { Write-Dry "$($p.Label) -> $disp"; continue }
    try {
        $null = powercfg /change $p.Key $p.Val 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg 終了コード $LASTEXITCODE" }
        Write-Ok "$($p.Label) -> $disp"
    } catch { Write-Fail "$($p.Label) の設定に失敗: $_" }
}


# ------------------------------------------------------------
#  4. リモートデスクトップ
# ------------------------------------------------------------
Write-Head 'リモートデスクトップ'
if ($Config.EnableRdp) {
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($edition -match 'Home') {
        Write-Warn "Home エディションのため RDP サーバー機能は利用できません ($edition)"
    } else {
        try {
            Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
                         -Name 'fDenyTSConnections' -Value 0
            if ($Config.RdpRequireNla) {
                Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                             -Name 'UserAuthentication' -Value 1
            }
            if (-not $DryRun) {
                # 表示名はロケール依存なので、不変のグループIDで指定する
                Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop |
                    Enable-NetFirewallRule -ErrorAction Stop
            }
            if ($DryRun) { Write-Dry 'ファイアウォール: リモートデスクトップ規則を有効化' }
            else { Write-Ok "RDP 有効化 (NLA: $($Config.RdpRequireNla))" }
        } catch { Write-Fail "RDP 有効化に失敗: $($_.Exception.Message)" }
    }
} else { Write-Skip '無効設定のため何もしない' }


# ------------------------------------------------------------
#  5. エクスプローラ表示 (ユーザー単位)
# ------------------------------------------------------------
Write-Head 'エクスプローラ表示'
$advPath = "$UserHive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
if (-not $userHiveOk) {
    Write-Skip 'ユーザーハイブ未読込のためスキップ'
} else {
    try {
        if ($Config.ShowFileExtensions) {
            Set-RegValue -Path $advPath -Name 'HideFileExt' -Value 0
            if (-not $DryRun) { Write-Ok '拡張子を表示' }
        }
        if ($Config.ShowHiddenFiles) {
            Set-RegValue -Path $advPath -Name 'Hidden' -Value 1
            if (-not $DryRun) { Write-Ok '隠しファイルを表示' }
        }
        if ($Config.ShowSuperHidden) {
            Set-RegValue -Path $advPath -Name 'ShowSuperHidden' -Value 1
            if (-not $DryRun) { Write-Ok '保護されたOSファイルも表示' }
        }
    } catch { Write-Fail "エクスプローラ設定に失敗: $($_.Exception.Message)" }
}


# ------------------------------------------------------------
#  6. クリップボード履歴 (ユーザー単位)
# ------------------------------------------------------------
Write-Head 'クリップボード履歴'
if (-not $Config.EnableClipboardHistory) {
    Write-Skip '無効設定のため何もしない'
} elseif (-not $userHiveOk) {
    Write-Skip 'ユーザーハイブ未読込のためスキップ'
} else {
    # グループポリシーで禁止されていると、ユーザー設定は無視される
    $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $pol = Get-ItemProperty -Path $polPath -Name 'AllowClipboardHistory' -ErrorAction SilentlyContinue
    if ($pol -and $pol.AllowClipboardHistory -eq 0) {
        Write-Warn 'グループポリシーでクリップボード履歴が禁止されています(設定は反映されません)'
    }
    try {
        Set-RegValue -Path "$UserHive\Software\Microsoft\Clipboard" `
                     -Name 'EnableClipboardHistory' -Value 1
        if (-not $DryRun) { Write-Ok 'クリップボード履歴を有効化 (Win+V)' }
    } catch { Write-Fail "クリップボード履歴の設定に失敗: $($_.Exception.Message)" }
}


# ------------------------------------------------------------
#  7. WiFi
# ------------------------------------------------------------
Write-Head 'WiFi'
$wifiXmlPath = $null
$wifiTemp    = $false
$wifiSsidUsed = $null

if ($Config.WifiProfileXml) {
    if (Test-Path $Config.WifiProfileXml) {
        $wifiXmlPath = $Config.WifiProfileXml
        try {
            $wifiSsidUsed = ([xml](Get-Content $wifiXmlPath -Raw)).WLANProfile.name
        } catch { }
    } else {
        Write-Fail "WiFiプロファイルXMLが見つかりません: $($Config.WifiProfileXml)"
    }
} elseif ($Config.WifiSsid -and $Config.WifiPassword) {
    $wifiSsidUsed = $Config.WifiSsid
    $ssidEsc = [System.Security.SecurityElement]::Escape($Config.WifiSsid)
    $pwEsc   = [System.Security.SecurityElement]::Escape($Config.WifiPassword)
    $ssidHex = -join ([Text.Encoding]::UTF8.GetBytes($Config.WifiSsid) |
                      ForEach-Object { $_.ToString('X2') })
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidEsc</name>
  <SSIDConfig>
    <SSID>
      <hex>$ssidHex</hex>
      <name>$ssidEsc</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$pwEsc</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
    $wifiXmlPath = Join-Path $env:TEMP ("wlan_{0}.xml" -f [guid]::NewGuid())
    $wifiTemp = $true
    if (-not $DryRun) {
        [IO.File]::WriteAllText($wifiXmlPath, $xml, [Text.UTF8Encoding]::new($false))
    }
} else {
    Write-Skip '未指定'
}

if ($wifiXmlPath) {
    if ($DryRun) {
        Write-Dry "WiFiプロファイルを追加: $wifiSsidUsed"
    } else {
        try {
            $out = netsh wlan add profile filename="$wifiXmlPath" user=all 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
            Write-Ok "WiFiプロファイルを追加: $wifiSsidUsed"

            if ($Config.WifiConnectAfter -and $wifiSsidUsed) {
                $out = netsh wlan connect name="$wifiSsidUsed" 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok "WiFi接続を要求: $wifiSsidUsed" }
                else { Write-Warn "WiFi接続に失敗(圏外/アダプタ無効など): $($out -join ' ')" }
            }
        } catch {
            Write-Fail "WiFiプロファイル追加に失敗: $_"
        } finally {
            # 平文パスワードを含む一時ファイルは必ず消す
            if ($wifiTemp -and (Test-Path $wifiXmlPath)) {
                Remove-Item $wifiXmlPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


# ------------------------------------------------------------
#  8. スタートアップ無効化 (ユーザー単位)
# ------------------------------------------------------------
Write-Head 'スタートアップ無効化'
if (-not $Config.DisableStartupApps -or $Config.DisableStartupApps.Count -eq 0) {
    Write-Skip '未指定'
} elseif (-not $userHiveOk) {
    Write-Skip 'ユーザーハイブ未読込のためスキップ'
} else {
    $runPath      = "$UserHive\Software\Microsoft\Windows\CurrentVersion\Run"
    $approvedPath = "$UserHive\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    # タスクマネージャーの「無効」と同じ状態を示すバイナリ
    $disabledBin = [byte[]]@(0x03,0,0,0,0,0,0,0,0,0,0,0)

    foreach ($app in $Config.DisableStartupApps) {
        $entry = Get-ItemProperty -Path $runPath -Name $app -ErrorAction SilentlyContinue
        if (-not $entry) {
            Write-Skip "$app : Run キーに登録なし"
            continue
        }
        try {
            # Run から消すのではなく「無効」状態にする
            # (削除するとアプリのアップデート時に復活しやすいため)
            Set-RegValue -Path $approvedPath -Name $app -Value $disabledBin -Type Binary
            if (-not $DryRun) { Write-Ok "$app のスタートアップを無効化" }
        } catch { Write-Fail "$app の無効化に失敗: $($_.Exception.Message)" }
    }
}


# ------------------------------------------------------------
#  9. 仕上げ
# ------------------------------------------------------------
Write-Head '仕上げ'
if ($Config.RestartExplorer -and -not $DryRun) {
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Write-Ok 'エクスプローラを再起動(表示設定を即時反映)'
    } catch { Write-Warn "エクスプローラ再起動に失敗: $($_.Exception.Message)" }
} elseif ($DryRun) {
    Write-Dry 'エクスプローラを再起動'
} else {
    Write-Skip 'エクスプローラ再起動は無効'
}


# ------------------------------------------------------------
#  結果サマリ
# ------------------------------------------------------------
Write-Host ''
Write-Host '############################################' -ForegroundColor White
Write-Host '#  結果                                     #' -ForegroundColor White
Write-Host '############################################' -ForegroundColor White

$ok   = ($script:Results | Where-Object S -eq 'OK').Count
$skip = ($script:Results | Where-Object S -eq 'SKIP').Count
$warn = ($script:Results | Where-Object S -eq 'WARN').Count
$fail = ($script:Results | Where-Object S -eq 'FAIL').Count
Write-Host ("  OK: {0}  SKIP: {1}  WARN: {2}  FAIL: {3}" -f $ok,$skip,$warn,$fail)

if ($warn -gt 0 -or $fail -gt 0) {
    Write-Host ''
    Write-Host '  要確認:' -ForegroundColor Yellow
    $script:Results | Where-Object { $_.S -in 'WARN','FAIL' } | ForEach-Object {
        $c = if ($_.S -eq 'FAIL') { 'Red' } else { 'Yellow' }
        Write-Host "    [$($_.S)] $($_.M)" -ForegroundColor $c
    }
}

if ($needReboot) {
    Write-Host ''
    Write-Host '  PC名の変更を反映するには再起動が必要です。' -ForegroundColor Yellow
    $ans = Read-Host '  今すぐ再起動しますか? (y/N)'
    if ($ans -match '^[yY]') { Restart-Computer -Force }
}

Write-Host ''
Read-Host '終了するには Enter キーを押してください'
