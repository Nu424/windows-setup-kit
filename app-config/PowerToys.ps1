<#
    PowerToys の設定復元。

    インストールは app-install 側で終わっている前提で、ここは設定ファイルだけを移す。
    PowerToys の「バックアップと復元」(.ptb) ではなく
    %LOCALAPPDATA%\Microsoft\PowerToys をフォルダごと持ち回る方式にしてある。
    フォルダ丸ごとのほうが復元漏れが出にくい。

    書き込み先は実行中アカウントの LOCALAPPDATA。
    昇格で別アカウントに変わっている場合は、そのアカウント側に復元されることになる。
#>

<#
    AppConfig.PowerToys の値を読む。
    Set-StrictMode 下では存在しないキーにドットで触れると例外になるので、
    settings.ps1 で節ごと差し替えられていても落ちないようにここを通す。
#>
function Get-PowerToysSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if (-not $Settings.ContainsKey('AppConfig')) { return $Default }
    $appConfig = $Settings['AppConfig']
    if ($appConfig -isnot [hashtable] -or -not $appConfig.ContainsKey('PowerToys')) { return $Default }

    $section = $appConfig['PowerToys']
    if ($section -isnot [hashtable] -or -not $section.ContainsKey($Name)) { return $Default }
    return $section[$Name]
}

# 復元元フォルダ (既定 assets\powertoys) の絶対パス。
function Get-PowerToysAssetRoot {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root
    )

    $relative = ''
    if ($Settings.ContainsKey('Paths')) {
        $paths = $Settings['Paths']
        if ($paths -is [hashtable] -and $paths.ContainsKey('PowerToys')) {
            $relative = [string]$paths['PowerToys']
        }
    }
    return (Resolve-AssetPath -Root $Root -Path $relative)
}

# 設定ファイルを掴まれたままだと、終了時に PowerToys 側の内容で上書きし返される。
# なので書き換える前に必ず止める。
function Stop-PowerToysProcess {
    $running = @(Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }

    foreach ($proc in $running) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        } catch {
            Write-Log "PowerToys: 実行中プロセス $($proc.ProcessName) を停止できなかった (復元した設定が上書きし返される可能性) - $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log "PowerToys: 設定を書き換えるため実行中のプロセス $($running.Count) 個を停止した" 'INFO'
    Start-Sleep -Seconds 3   # ファイルハンドルが離れるまでの待ち
}

<#
    上書き前の退避。
    退避に失敗したときは上書きしない。今の設定を失うほうが痛いため。
    戻り値は「このあと上書きしてよいか」。
#>
function Backup-PowerToysConfig {
    param([Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination)) {
        try {
            New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-Log "PowerToys: 設定フォルダ $Destination を作成できなかったので復元を中止した - $($_.Exception.Message)" 'FAIL'
            return $false
        }
    }

    $backup = '{0}.bak_{1:yyyyMMdd_HHmmss}' -f $Destination, (Get-Date)
    try {
        Copy-Item -LiteralPath $Destination -Destination $backup -Recurse -Force -ErrorAction Stop
        Write-Log "PowerToys: 既存設定を $backup に退避した" 'OK'
        return $true
    } catch {
        Write-Log "PowerToys: 既存設定を $backup に退避できなかったので上書きを中止した - $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

# 復元した設定を読ませるための起動。マシン導入とユーザー導入で場所が違う。
function Start-PowerToysApp {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe')
        (Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe')
    )
    $exe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $exe) {
        Write-Log 'PowerToys: 本体の exe が見つからないので起動しない。設定は復元済みなので次回 PowerToys 起動時に反映される' 'WARN'
        return
    }

    try {
        Start-Process -FilePath $exe -ErrorAction Stop
        Write-Log 'PowerToys: 復元した設定を読み込ませるため PowerToys を起動した' 'OK'
    } catch {
        Write-Log "PowerToys: PowerToys の起動に失敗したので手動で起動する ($exe) - $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-PowerToysRestore {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root
    )

    Write-SetupStep 'PowerToys の設定復元'

    if (-not (Get-PowerToysSetting -Settings $Settings -Name 'Restore' -Default $true)) {
        Write-Log 'PowerToys: 設定 AppConfig.PowerToys.Restore が無効なので設定復元をスキップ' 'SKIP'
        return
    }

    $src = Get-PowerToysAssetRoot -Settings $Settings -Root $Root
    if (-not $src) {
        Write-Log 'PowerToys: 設定 Paths.PowerToys が空で復元元が決まらないので設定復元をスキップ' 'SKIP'
        return
    }

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Log "PowerToys: 復元元フォルダ $src が無いので設定復元をスキップ" 'SKIP'
        Write-Log 'PowerToys: 移行元 PC の %LOCALAPPDATA%\Microsoft\PowerToys の中身をそこに置くと復元される' 'INFO'
        return
    }

    # .gitkeep しか無い状態は「まだ何も置いていない」なので空扱いにする
    $items = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne '.gitkeep' })
    if ($items.Count -eq 0) {
        Write-Log "PowerToys: 復元元フォルダ $src が空なので設定復元をスキップ" 'SKIP'
        Write-Log 'PowerToys: 移行元 PC の %LOCALAPPDATA%\Microsoft\PowerToys の中身をそこに置くと復元される' 'INFO'
        return
    }

    $dst = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'

    if (Test-DryRun) {
        Write-Log "PowerToys: 実行すると $src の $($items.Count) 項目を $dst に上書きコピーする" 'DRY'
        Write-Log 'PowerToys: 実行すると PowerToys を停止し、既存設定を .bak_日時 に退避してからコピーして起動し直す' 'DRY'
        return
    }

    Stop-PowerToysProcess

    if (-not (Backup-PowerToysConfig -Destination $dst)) { return }

    try {
        foreach ($item in $items) {
            Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
        }
        Write-Change "PowerToys: 設定を $src から $dst に復元した"
    } catch {
        Write-Log "PowerToys: 設定のコピーに失敗した (コピー先 $dst) - $($_.Exception.Message)" 'FAIL'
        return
    }

    Start-PowerToysApp
}
