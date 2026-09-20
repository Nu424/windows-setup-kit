<#
    winget でのソフト一括インストール。

    入れるものの一覧は settings.ps1 (Install.Apps) 側が持つ。
    ここに一覧を書くと settings.ps1 と二重管理になるので書かない。

    winget が無いときは例外を投げずに FAIL をログして戻る。
    分類ごとに独立して失敗させたいため (winget が無いだけで
    Windows 設定やアプリ設定まで道連れにしない)。

    外から呼ぶのは Invoke-WingetApps だけ。
#>

# 0x8A15002B。winget が「既にインストール済み / 該当パッケージなし」で返すコード。
# 目的 (そのソフトが入っている状態) は達成できているので成功として扱う。
$script:WingetAlreadyInstalled = -1978335189

# ログに出す表示名。Name が無ければ Id で代用する。
function Get-WingetAppName {
    param([Parameter(Mandatory)][hashtable]$App)

    if ($App.ContainsKey('Name') -and -not [string]::IsNullOrWhiteSpace([string]$App.Name)) {
        return [string]$App.Name
    }
    if ($App.ContainsKey('Id') -and -not [string]::IsNullOrWhiteSpace([string]$App.Id)) {
        return [string]$App.Id
    }
    return '(名前不明のエントリ)'
}

<#
    winget が使えるかを確認し、使えるなら規約同意を先に済ませる。
    同意を先出ししておかないと、インストール途中で同意待ちになって
    無人実行が止まる。
#>
function Initialize-WingetCli {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log 'winget が見つからないので winget でのインストールを全件スキップした。Microsoft Store の「アプリ インストーラー」を入れてから再実行する' 'FAIL'
        Write-Log 'アプリ インストーラー: https://apps.microsoft.com/detail/9nblggh4nns1' 'INFO'
        return $false
    }

    $version = ''
    try { $version = ((& winget --version) | Out-String).Trim() } catch { }
    Write-Log ("winget を確認した ({0})" -f $(if ($version) { $version } else { 'バージョン取得不可' })) 'INFO'

    if (Test-DryRun) {
        # 規約同意もレジストリ (winget の設定) を書き換える操作なので DryRun では触らない
        Write-Log 'winget の規約同意は行わない (DryRun)' 'DRY'
        return $true
    }

    # 同意の記録だけが目的なので出力は捨てる。winget が stderr に書いても続行する
    try { & winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-Null } catch { }
    return $true
}

# winget の一覧に載っているかでインストール済みを判定する。
# 判定できなかったときは未インストール扱い (winget 側が二重インストールを弾く)。
function Test-WingetAppInstalled {
    param([Parameter(Mandatory)][string]$Id)

    try {
        $out = & winget list --id $Id --exact --disable-interactivity 2>&1 | Out-String
    } catch {
        return $false
    }
    return ($out -match [regex]::Escape($Id))
}

# 1 本インストールする。成功 (またはスキップ) なら $true。
function Install-WingetApp {
    param([Parameter(Mandatory)][hashtable]$App)

    $name = Get-WingetAppName -App $App

    if (-not $App.ContainsKey('Id') -or [string]::IsNullOrWhiteSpace([string]$App.Id)) {
        Write-Log "$name : winget の Id が書かれていないのでインストールできない。settings.ps1 の Install.Apps を直す" 'FAIL'
        return $false
    }
    $id = [string]$App.Id

    # DryRun でも読み取りだけなので、インストール済みかどうかは見てよい
    if (Test-WingetAppInstalled -Id $id) {
        Write-Log "$name : インストール済みなのでスキップ ($id)" 'SKIP'
        return $true
    }

    # Scope は settings.ps1 由来で省略され得るので ContainsKey で確認する
    $scope = ''
    if ($App.ContainsKey('Scope') -and -not [string]::IsNullOrWhiteSpace([string]$App.Scope)) {
        $scope = [string]$App.Scope
    }

    if (Test-DryRun) {
        $suffix = if ($scope) { " --scope $scope" } else { '' }
        Write-Log "$name : winget install --id $id$suffix を実行する (DryRun)" 'DRY'
        return $true
    }

    $baseArgs = @(
        'install', '--id', $id, '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    # scope 指定つきで試して、通らなければ scope なしで再試行する。
    # machine / user のどちらかしか出していないパッケージがあるため。
    $attempts = @()
    if ($scope) { $attempts += ,($baseArgs + @('--scope', $scope)) }
    $attempts += ,$baseArgs

    for ($i = 0; $i -lt $attempts.Count; $i++) {
        Write-Log "$name : winget でインストール中 ($id)" 'INFO'
        $p = Start-Process winget -ArgumentList $attempts[$i] -Wait -PassThru -NoNewWindow
        $exit = if ($null -eq $p) { -1 } else { [int]$p.ExitCode }

        if ($exit -eq 0 -or $exit -eq $script:WingetAlreadyInstalled) {
            Write-Change "$name : winget でインストールした ($id)"
            return $true
        }
        if ($i -lt $attempts.Count - 1) {
            Write-Log "$name : winget が exit $exit で失敗。--scope を外して再試行する" 'WARN'
        } else {
            Write-Log "$name : winget が exit $exit で失敗した ($id)。手動で入れる" 'FAIL'
        }
    }
    return $false
}

function Invoke-WingetApps {
    param([Parameter(Mandatory)][hashtable]$Settings)

    Write-SetupStep 'ソフトのインストール (winget)'

    $apps = @()
    if ($Settings.ContainsKey('Install') -and $Settings.Install -is [hashtable] -and
        $Settings.Install.ContainsKey('Apps') -and $Settings.Install.Apps) {
        $apps = @($Settings.Install.Apps)
    }
    if ($apps.Count -eq 0) {
        Write-Log 'settings.ps1 の Install.Apps が空なので winget でのインストールはしない' 'SKIP'
        return
    }

    if (-not (Initialize-WingetCli)) { return }

    $failed = @()
    foreach ($app in $apps) {
        if ($app -isnot [hashtable]) {
            Write-Log 'settings.ps1 の Install.Apps にハッシュテーブル以外の要素があるので無視した' 'WARN'
            continue
        }
        $name = Get-WingetAppName -App $app
        try {
            if (-not (Install-WingetApp -App $app)) { $failed += $name }
        } catch {
            # 1 本の失敗で残りを止めない
            Write-Log "$name : winget の実行中に例外 - $($_.Exception.Message)" 'FAIL'
            $failed += $name
        }
    }

    # インストール直後の PATH をこのセッションに取り込む。
    # 後続の分類 (volta / gh などを叩く app-config) が新しいコマンドを使えるようにする。
    Update-SessionPath

    if ($failed.Count -gt 0) {
        # 個々の FAIL は既に出しているので、ここは見返し用の 1 行にとどめる
        Write-Log ("winget で入らなかったソフト: {0}" -f ($failed -join ', ')) 'INFO'
    }
}
