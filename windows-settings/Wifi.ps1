<#
    WiFi プロファイルの登録。

    設定方法は上から順に 3 通り:
      1) Windows.Wifi.ProfileXml に書いた XML (ファイル名なら assets\wifi の中を探す)
      2) assets\wifi に XML が 1 個だけ置いてあれば、それを自動で使う
      3) Ssid / Password から WPA2-PSK / AES のプロファイルを生成する

    パスワードは画面にもログにも出さない。
    生成した一時 XML は平文パスワードを含むので、使い終わったら必ず消す。
#>

# 設定ハッシュテーブルから 1 個読む (StrictMode 下で欠けたキーに触れても落ちないように)
function Get-WifiSettingValue {
    param(
        $Table,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Table -is [hashtable] -and $Table.ContainsKey($Key)) { return $Table[$Key] }
    return $null
}

# SSID とパスフレーズから WPA2-PSK / AES のプロファイル XML を組み立てる
function New-WifiProfileXml {
    param(
        [Parameter(Mandatory)][string]$Ssid,
        [Parameter(Mandatory)][string]$Password
    )

    $ssidEscaped = [System.Security.SecurityElement]::Escape($Ssid)
    $pwEscaped   = [System.Security.SecurityElement]::Escape($Password)
    # SSID は 16 進表記も持たせておく (マルチバイト SSID でも確実に一致させるため)
    $ssidHex = -join ([Text.Encoding]::UTF8.GetBytes($Ssid) | ForEach-Object { $_.ToString('X2') })

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidEscaped</name>
  <SSIDConfig>
    <SSID>
      <hex>$ssidHex</hex>
      <name>$ssidEscaped</name>
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
        <keyMaterial>$pwEscaped</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
}

<#
    WiFi プロファイルを登録し、設定に応じて接続まで試す。
#>
function Invoke-WifiSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Unattended
    )

    Write-SetupStep 'WiFi'

    $wifi    = Get-WifiSettingValue -Table (Get-WifiSettingValue -Table $Settings -Key 'Windows') -Key 'Wifi'
    $wifiDir = Resolve-AssetPath -Root $Root -Path ([string](Get-WifiSettingValue -Table (Get-WifiSettingValue -Table $Settings -Key 'Paths') -Key 'Wifi'))

    $xmlPath   = $null    # netsh に渡すプロファイル XML
    $isTempXml = $false   # 生成した一時ファイルなら $true (最後に消す)
    $ssid      = $null    # 接続に使う SSID

    # --- 1) 設定で指定された XML ---
    $profileXml = [string](Get-WifiSettingValue -Table $wifi -Key 'ProfileXml')
    if (-not [string]::IsNullOrWhiteSpace($profileXml)) {
        # ファイル名だけなら assets\wifi の中、フルパスならそのまま
        $baseDir  = if ($wifiDir) { $wifiDir } else { $Root }
        $resolved = Resolve-AssetPath -Root $baseDir -Path $profileXml
        if (Test-Path -LiteralPath $resolved) {
            $xmlPath = $resolved
        } else {
            Write-Log "WiFi: 設定で指定されたプロファイル XML が見つからない: $resolved" 'FAIL'
            return
        }
    }

    # --- 2) assets\wifi に XML が 1 個だけなら自動採用 ---
    if (-not $xmlPath -and $wifiDir -and (Test-Path -LiteralPath $wifiDir)) {
        $found = @(Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) {
            $xmlPath = $found[0].FullName
            Write-Log "WiFi: assets\wifi の $($found[0].Name) を自動で使う"
        } elseif ($found.Count -gt 1) {
            Write-Log "WiFi: assets\wifi に XML が $($found.Count) 個あり、どれを使うか決められない。settings.ps1 の Windows.Wifi.ProfileXml にファイル名を書くこと" 'WARN'
            return
        }
    }

    # --- 3) SSID / パスワードからプロファイルを生成 ---
    if (-not $xmlPath) {
        $ssidValue = Get-SettingOrPrompt -Value ([string](Get-WifiSettingValue -Table $wifi -Key 'Ssid')) `
                                         -Prompt 'WiFi の SSID (空 Enter でスキップ)' -Unattended:$Unattended
        if ([string]::IsNullOrWhiteSpace($ssidValue)) {
            Write-Log 'WiFi: プロファイル XML も SSID も無いので設定しない' 'SKIP'
            return
        }

        $password = Get-SettingOrPrompt -Value ([string](Get-WifiSettingValue -Table $wifi -Key 'Password')) `
                                        -Prompt "WiFi $ssidValue のパスワード (空 Enter でスキップ)" -Secret -Unattended:$Unattended
        if ([string]::IsNullOrWhiteSpace($password)) {
            Write-Log "WiFi: $ssidValue のパスワードが無いので設定しない" 'SKIP'
            return
        }

        $ssid      = $ssidValue
        $xmlPath   = Join-Path $env:TEMP ("wlan_{0}.xml" -f [guid]::NewGuid())
        $isTempXml = $true
        try {
            # DryRun では平文パスワードをディスクに書かない
            if (-not (Test-DryRun)) {
                [IO.File]::WriteAllText($xmlPath, (New-WifiProfileXml -Ssid $ssidValue -Password $password), [Text.UTF8Encoding]::new($false))
            }
        } catch {
            Write-Log "WiFi: $ssidValue のプロファイル XML を作れなかった: $($_.Exception.Message)" 'FAIL'
            return
        } finally {
            $password = $null
        }
    }

    # XML から採った SSID は接続とログの表示に使う
    if (-not $ssid) {
        try {
            $ssid = ([xml](Get-Content -LiteralPath $xmlPath -Raw)).WLANProfile.name
        } catch {
            # SSID が読めなくてもプロファイルの登録自体はできる
            $ssid = $null
        }
    }
    $label = if ($ssid) { $ssid } else { Split-Path -Leaf $xmlPath }

    $connectAfter = [bool](Get-WifiSettingValue -Table $wifi -Key 'ConnectAfter')

    try {
        if (Test-DryRun) {
            Write-Log "WiFi: プロファイル $label を全ユーザー向けに登録する" 'DRY'
            if ($connectAfter -and $ssid) {
                Write-Log "WiFi: 登録後に $ssid へ接続を試みる" 'DRY'
            }
        } else {
            $added = Invoke-NativeCapture -FilePath 'netsh' -Arguments @('wlan','add','profile',"filename=$xmlPath",'user=all')
            if ($added.ExitCode -ne 0) { throw $added.Output }
            Write-Log "WiFi: プロファイル $label を登録した" 'OK'

            if ($connectAfter) {
                if ($ssid) {
                    $connected = Invoke-NativeCapture -FilePath 'netsh' -Arguments @('wlan','connect',"name=$ssid")
                    if ($connected.ExitCode -eq 0) {
                        Write-Log "WiFi: $ssid への接続を要求した" 'OK'
                    } else {
                        Write-Log "WiFi: $ssid に接続できなかった (圏外 / 無線アダプタ無効など): $($connected.Output)" 'WARN'
                    }
                } else {
                    Write-Log "WiFi: プロファイル $label から SSID を読めなかったので自動接続は試さない" 'WARN'
                }
            }
        }
    } catch {
        Write-Log "WiFi: プロファイル $label の登録に失敗: $_" 'FAIL'
    } finally {
        # 生成した一時 XML は平文パスワードを含むので必ず消す
        if ($isTempXml -and (Test-Path -LiteralPath $xmlPath)) {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }
}
