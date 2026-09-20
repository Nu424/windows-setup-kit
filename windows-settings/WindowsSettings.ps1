<#
    Windows そのものの設定。

    実行ポリシー / PC名 / 電源タイムアウト / リモートデスクトップ /
    エクスプローラ表示 / クリップボード履歴 / スタートアップ無効化 を適用する。

    昇格すると実行アカウントが変わるため、ユーザー単位 (HKCU 相当) の項目は
    HKEY_USERS\<UserSid> 側に書いて、元のユーザーに設定が入るようにする。
#>

<#
    設定ハッシュテーブルから 1 個読む。
    settings.ps1 の書き方次第ではキーが欠けることがあり、
    StrictMode 下ではドットアクセスが例外になるので索引アクセスで包む。
#>
function Get-WindowsSettingValue {
    param(
        $Table,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Table -is [hashtable] -and $Table.ContainsKey($Key)) { return $Table[$Key] }
    return $null
}

<#
    Windows の設定をまとめて適用する。
    1 項目の失敗では止めず、FAIL を記録して次の項目へ進む。

    戻り値: PC名を変更して再起動が必要なら $true
#>
function Invoke-WindowsSettings {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$UserSid,
        [switch]$Unattended
    )

    Write-SetupStep 'Windows の設定'

    $w = Get-WindowsSettingValue -Table $Settings -Key 'Windows'
    $needReboot = $false

    # 昇格先の管理者ではなく、どのユーザーに設定が入るかを最初に示しておく
    Write-Log ("設定対象ユーザー: {0}" -f (Resolve-UserName -Sid $UserSid))

    $userHive   = Get-UserHivePath -UserSid $UserSid
    $userHiveOk = Test-UserHive -UserSid $UserSid
    if (-not $userHiveOk) {
        Write-Log "ユーザーのレジストリハイブが読み込まれていない ($UserSid)。エクスプローラ表示 / クリップボード履歴 / スタートアップ無効化はスキップする" 'WARN'
    }

    # ------------------------------------------------------------
    #  1. 実行ポリシー (LocalMachine)
    # ------------------------------------------------------------
    $policy = Get-WindowsSettingValue -Table $w -Key 'SetExecutionPolicy'
    if ($policy) {
        try {
            $current = Get-ExecutionPolicy -Scope LocalMachine
            if ($current -eq $policy) {
                Write-Log "実行ポリシー: 既に LocalMachine = $current" 'SKIP'
            } else {
                if (-not (Test-DryRun)) {
                    Set-ExecutionPolicy -ExecutionPolicy $policy -Scope LocalMachine -Force -ErrorAction Stop
                }
                Write-Change "実行ポリシー: LocalMachine を $current から $policy に変更"
            }
        } catch {
            Write-Log "実行ポリシーの変更に失敗: $($_.Exception.Message)" 'FAIL'
        }
    } else {
        Write-Log '実行ポリシー: 未指定なので現状維持' 'SKIP'
    }

    # ------------------------------------------------------------
    #  2. PC名
    # ------------------------------------------------------------
    $computerName = Get-SettingOrPrompt `
        -Value (Get-WindowsSettingValue -Table $w -Key 'ComputerName') `
        -Prompt 'PC名 (空 Enter で変更しない)' -Unattended:$Unattended

    if ([string]::IsNullOrWhiteSpace($computerName)) {
        Write-Log 'PC名: 指定が無いので変更しない' 'SKIP'
    } elseif ($computerName -eq $env:COMPUTERNAME) {
        Write-Log "PC名: 既に '$computerName'" 'SKIP'
    } elseif ($computerName.Length -gt 15 -or
              $computerName -notmatch '^[A-Za-z0-9\-]+$' -or
              $computerName -match '^\d+$') {
        Write-Log "PC名: '$computerName' は使えない (15文字以内 / 英数字とハイフン / 数字のみ不可)" 'FAIL'
    } else {
        try {
            if (-not (Test-DryRun)) {
                Rename-Computer -NewName $computerName -Force -ErrorAction Stop | Out-Null
                # 実際に変更したときだけ再起動を要求する (DryRun では何も変わっていない)
                $needReboot = $true
            }
            Write-Change "PC名: $env:COMPUTERNAME から $computerName に変更 (再起動後に反映)"
        } catch {
            Write-Log "PC名の変更に失敗: $($_.Exception.Message)" 'FAIL'
        }
    }

    # ------------------------------------------------------------
    #  3. 電源タイムアウト (分 / 0 = なし / $null = 現状維持)
    # ------------------------------------------------------------
    $powerItems = @(
        @{ Key = 'monitor-timeout-ac'; Label = '画面オフ (電源接続)';   Value = (Get-WindowsSettingValue -Table $w -Key 'MonitorTimeoutAC') }
        @{ Key = 'monitor-timeout-dc'; Label = '画面オフ (バッテリー)'; Value = (Get-WindowsSettingValue -Table $w -Key 'MonitorTimeoutDC') }
        @{ Key = 'standby-timeout-ac'; Label = 'スリープ (電源接続)';   Value = (Get-WindowsSettingValue -Table $w -Key 'StandbyTimeoutAC') }
        @{ Key = 'standby-timeout-dc'; Label = 'スリープ (バッテリー)'; Value = (Get-WindowsSettingValue -Table $w -Key 'StandbyTimeoutDC') }
    )
    foreach ($item in $powerItems) {
        if ($null -eq $item.Value) {
            Write-Log "電源タイムアウト: $($item.Label) は未指定なので現状維持" 'SKIP'
            continue
        }
        $display = if ($item.Value -eq 0) { 'なし' } else { "$($item.Value)分" }
        try {
            if (-not (Test-DryRun)) {
                $result = Invoke-NativeCapture -FilePath 'powercfg' -Arguments @('/change', $item.Key, [string]$item.Value)
                if ($result.ExitCode -ne 0) { throw "powercfg 終了コード $($result.ExitCode) : $($result.Output)" }
            }
            Write-Change "電源タイムアウト: $($item.Label) を $display に設定"
        } catch {
            Write-Log "電源タイムアウト: $($item.Label) の設定に失敗: $_" 'FAIL'
        }
    }

    # ------------------------------------------------------------
    #  4. リモートデスクトップ
    # ------------------------------------------------------------
    if (Get-WindowsSettingValue -Table $w -Key 'EnableRdp') {
        try {
            $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
            if ($edition -match 'Home') {
                Write-Log "RDP: Home エディションでは有効化できない ($edition)" 'WARN'
            } else {
                $nla = [bool](Get-WindowsSettingValue -Table $w -Key 'RdpRequireNla')

                Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
                             -Name 'fDenyTSConnections' -Value 0
                if ($nla) {
                    Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                                 -Name 'UserAuthentication' -Value 1
                }
                if (-not (Test-DryRun)) {
                    # 規則の表示名はロケール依存なので、不変のグループIDで指定する
                    Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop |
                        Enable-NetFirewallRule -ErrorAction Stop
                }
                Write-Change "RDP: 有効化してファイアウォールのリモートデスクトップ規則を許可 (NLA: $nla)"
            }
        } catch {
            Write-Log "RDP の有効化に失敗: $($_.Exception.Message)" 'FAIL'
        }
    } else {
        Write-Log 'RDP: 設定が無効なので有効化しない' 'SKIP'
    }

    # ------------------------------------------------------------
    #  5. エクスプローラ表示 (ユーザー単位)
    # ------------------------------------------------------------
    if (-not $userHiveOk) {
        Write-Log 'エクスプローラ表示: ユーザーのレジストリハイブ未読込のためスキップ' 'SKIP'
    } else {
        $advancedPath = "$userHive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $explorerItems = @(
            @{ Name = 'HideFileExt';     Value = 0; Label = '拡張子を表示';             Enabled = [bool](Get-WindowsSettingValue -Table $w -Key 'ShowFileExtensions') }
            @{ Name = 'Hidden';          Value = 1; Label = '隠しファイルを表示';       Enabled = [bool](Get-WindowsSettingValue -Table $w -Key 'ShowHiddenFiles')    }
            @{ Name = 'ShowSuperHidden'; Value = 1; Label = '保護されたOSファイルも表示'; Enabled = [bool](Get-WindowsSettingValue -Table $w -Key 'ShowSuperHidden')    }
        )
        foreach ($item in $explorerItems) {
            if (-not $item.Enabled) {
                Write-Log "エクスプローラ表示: $($item.Label) は設定が無効なので現状維持" 'SKIP'
                continue
            }
            try {
                Set-RegValue -Path $advancedPath -Name $item.Name -Value $item.Value
                Write-Change "エクスプローラ表示: $($item.Label)"
            } catch {
                Write-Log "エクスプローラ表示: $($item.Label) の設定に失敗: $($_.Exception.Message)" 'FAIL'
            }
        }
    }

    # ------------------------------------------------------------
    #  6. クリップボード履歴 (ユーザー単位)
    # ------------------------------------------------------------
    if (-not (Get-WindowsSettingValue -Table $w -Key 'EnableClipboardHistory')) {
        Write-Log 'クリップボード履歴: 設定が無効なので有効化しない' 'SKIP'
    } elseif (-not $userHiveOk) {
        Write-Log 'クリップボード履歴: ユーザーのレジストリハイブ未読込のためスキップ' 'SKIP'
    } else {
        # グループポリシーで禁止されているとユーザー設定は無視されるので、先に知らせる
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        $clipPolicy = Get-ItemProperty -Path $policyPath -Name 'AllowClipboardHistory' -ErrorAction SilentlyContinue
        if ($clipPolicy -and $clipPolicy.AllowClipboardHistory -eq 0) {
            Write-Log 'クリップボード履歴: グループポリシーで禁止されているため設定しても反映されない' 'WARN'
        }
        try {
            Set-RegValue -Path "$userHive\Software\Microsoft\Clipboard" `
                         -Name 'EnableClipboardHistory' -Value 1
            Write-Change 'クリップボード履歴: 有効化 (Win+V)'
        } catch {
            Write-Log "クリップボード履歴の設定に失敗: $($_.Exception.Message)" 'FAIL'
        }
    }

    # ------------------------------------------------------------
    #  7. スタートアップ無効化 (ユーザー単位)
    # ------------------------------------------------------------
    $startupApps = @(Get-WindowsSettingValue -Table $w -Key 'DisableStartupApps')
    if ($startupApps.Count -eq 0) {
        Write-Log 'スタートアップ無効化: 対象アプリが未指定' 'SKIP'
    } elseif (-not $userHiveOk) {
        Write-Log 'スタートアップ無効化: ユーザーのレジストリハイブ未読込のためスキップ' 'SKIP'
    } else {
        $runPath      = "$userHive\Software\Microsoft\Windows\CurrentVersion\Run"
        $approvedPath = "$userHive\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        # タスクマネージャーの「無効」と同じ状態を示すバイナリ
        $disabledBin  = [byte[]]@(0x03,0,0,0,0,0,0,0,0,0,0,0)

        foreach ($app in $startupApps) {
            if ([string]::IsNullOrWhiteSpace($app)) { continue }

            $entry = Get-ItemProperty -Path $runPath -Name $app -ErrorAction SilentlyContinue
            if (-not $entry) {
                Write-Log "スタートアップ無効化: $app は Run キーに登録が無い" 'SKIP'
                continue
            }

            $approved = Get-ItemProperty -Path $approvedPath -Name $app -ErrorAction SilentlyContinue
            if ($approved -and $approved.$app -is [byte[]] -and $approved.$app[0] -eq 3) {
                Write-Log "スタートアップ無効化: $app は既に無効" 'SKIP'
                continue
            }

            try {
                # Run から消すとアプリの更新時に復活しやすいので、「無効」状態にするだけにする
                Set-RegValue -Path $approvedPath -Name $app -Value $disabledBin -Type Binary
                Write-Change "スタートアップ無効化: $app を無効にした"
            } catch {
                Write-Log "スタートアップ無効化: $app の無効化に失敗: $($_.Exception.Message)" 'FAIL'
            }
        }
    }

    # ------------------------------------------------------------
    #  8. エクスプローラ再起動 (表示設定の即時反映)
    # ------------------------------------------------------------
    if (Get-WindowsSettingValue -Table $w -Key 'RestartExplorer') {
        try {
            if (-not (Test-DryRun)) {
                Stop-Process -Name explorer -Force -ErrorAction Stop
            }
            Write-Change 'エクスプローラを再起動して表示設定を反映'
        } catch {
            Write-Log "エクスプローラの再起動に失敗: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Write-Log 'エクスプローラ再起動: 設定が無効なので再起動しない (表示設定は次のサインイン以降に反映)' 'SKIP'
    }

    return [bool]$needReboot
}
