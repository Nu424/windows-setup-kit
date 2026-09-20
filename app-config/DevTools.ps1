<#
    開発ツールの仕上げ。

    インストール自体は app-install 側で終わっている前提で、
    ここは「入れたあとに一度だけやる設定」だけを扱う。
      - volta で Node LTS を入れる
      - git の名前とメールを設定する
      - GitHub CLI にログインする
      - Claude Code のログイン案内 (REPL をここで開くとセットアップが止まるので起動はしない)

    移植元は git の名前とメールを画面で案内するだけだったが、
    settings.ps1 に書いてあるか聞けば分かる値なので、ここで実際に設定してしまう。
#>

<#
    AppConfig.DevTools の値を読む。
    Set-StrictMode 下では存在しないキーにドットで触れると例外になるので、ここを通す。
#>
function Get-DevToolsSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if (-not $Settings.ContainsKey('AppConfig')) { return $Default }
    $appConfig = $Settings['AppConfig']
    if ($appConfig -isnot [hashtable] -or -not $appConfig.ContainsKey('DevTools')) { return $Default }

    $section = $appConfig['DevTools']
    if ($section -isnot [hashtable] -or -not $section.ContainsKey($Name)) { return $Default }
    return $section[$Name]
}

<#
    Node が既に使える状態か。
    volta list の出力先はバージョンによって変わるため、
    取りこぼしても二重導入しないように node コマンドの有無も見る。
#>
function Test-NodeInstalled {
    if (Get-Command node -ErrorAction SilentlyContinue) { return $true }

    try {
        $listed = (Invoke-NativeCapture -FilePath 'volta' -Arguments @('list','node')).Output
        return ($listed -match 'v\d+\.\d+')
    } catch {
        return $false
    }
}

function Install-NodeLts {
    param([Parameter(Mandatory)][hashtable]$Settings)

    if (-not (Get-DevToolsSetting -Settings $Settings -Name 'InstallNodeLts' -Default $true)) {
        Write-Log 'Node: 設定 AppConfig.DevTools.InstallNodeLts が無効なので Node LTS を導入しない' 'SKIP'
        return
    }

    if (-not (Get-Command volta -ErrorAction SilentlyContinue)) {
        Write-Log 'Node: volta が見つからないので Node LTS の導入をスキップ (Volta のインストールに失敗している可能性)' 'SKIP'
        return
    }

    try {
        if (Test-NodeInstalled) {
            Write-Log 'Node: 既に Node が導入済みなので volta install node@lts はしない' 'SKIP'
            return
        }

        if (Test-DryRun) {
            Write-Log 'Node: 実行すると volta install node@lts で Node LTS を導入する' 'DRY'
            return
        }

        Write-Log 'Node: volta install node@lts を実行中' 'INFO'
        & volta install node@lts
        if ($LASTEXITCODE -eq 0) {
            Write-Change 'Node: volta で Node LTS を導入した'
        } else {
            Write-Log "Node: volta install node@lts に失敗した (exit $LASTEXITCODE)" 'FAIL'
        }
    } catch {
        Write-Log "Node: volta での Node LTS 導入中に例外が発生した - $($_.Exception.Message)" 'FAIL'
    }
}

<#
    git config --global の 1 項目を設定する。
    値が空なら聞く。既に同じ値なら触らない。
#>
function Set-GitConfigValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][AllowNull()][string]$Value,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Unattended
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Unattended) {
            Write-Log "git: $Key の値が settings.ps1 に無く、無人モードでは聞けないので設定しない" 'SKIP'
            return
        }
        if (Test-DryRun) {
            Write-Log "git: 実行すると $Key の値を聞いて git config --global に設定する" 'DRY'
            return
        }
        $Value = Get-SettingOrPrompt -Value $Value -Prompt $Prompt
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Log "git: $Key の値が無いので設定しない (settings.ps1 の AppConfig.DevTools に書くか、git config --global $Key で後から設定する)" 'SKIP'
        return
    }

    try {
        # 未設定のときは出力無しで exit 1 になるが、それは異常ではない
        $current = & git config --global --get $Key
        if ($current) { $current = ([string]$current).Trim() } else { $current = '' }

        if ($current -eq $Value) {
            Write-Log "git: $Key は既に $Value なので変更しない" 'SKIP'
            return
        }

        if (Test-DryRun) {
            Write-Log "git: 実行すると $Key を $Value に設定する" 'DRY'
            return
        }

        & git config --global $Key $Value
        if ($LASTEXITCODE -eq 0) {
            Write-Change "git: $Key を $Value に設定した"
        } else {
            Write-Log "git: $Key の設定に失敗した (git config --global exit $LASTEXITCODE)" 'FAIL'
        }
    } catch {
        Write-Log "git: $Key の設定中に例外が発生した - $($_.Exception.Message)" 'FAIL'
    }
}

function Set-GitIdentity {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [switch]$Unattended
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log 'git: git コマンドが見つからないので user.name / user.email の設定をスキップ (Git のインストールに失敗している可能性)' 'SKIP'
        return
    }

    Set-GitConfigValue -Key 'user.name' `
        -Value ([string](Get-DevToolsSetting -Settings $Settings -Name 'GitUserName' -Default '')) `
        -Prompt 'git のユーザー名 (空 Enter でスキップ)' -Unattended:$Unattended

    Set-GitConfigValue -Key 'user.email' `
        -Value ([string](Get-DevToolsSetting -Settings $Settings -Name 'GitUserEmail' -Default '')) `
        -Prompt 'git のメールアドレス (空 Enter でスキップ)' -Unattended:$Unattended
}

<#
    GitHub CLI にログイン済みか。
    gh auth status は未ログインだと exit 1 を返す。
    出力先が gh のバージョンで stdout / stderr と変わるので、両方まとめて捨てて
    終了コードだけを見る。
#>
function Test-GhLoggedIn {
    return ((Invoke-NativeCapture -FilePath 'gh' -Arguments @('auth','status')).ExitCode -eq 0)
}

function Invoke-GhAuthLogin {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [switch]$Unattended
    )

    if (-not (Get-DevToolsSetting -Settings $Settings -Name 'GhAuthLogin' -Default $true)) {
        Write-Log 'gh: 設定 AppConfig.DevTools.GhAuthLogin が無効なので GitHub CLI のログインをしない' 'SKIP'
        return
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Log 'gh: GitHub CLI が見つからないのでログインをスキップ (GitHub.cli のインストールに失敗している可能性)' 'SKIP'
        return
    }

    if ($Unattended) {
        Write-Log 'gh: 無人モードではブラウザ認証できないので GitHub CLI のログインをスキップ' 'SKIP'
        return
    }

    try {
        if (Test-GhLoggedIn) {
            Write-Log 'gh: GitHub CLI は既にログイン済み' 'OK'
            return
        }

        if (Test-DryRun) {
            Write-Log 'gh: 実行すると gh auth login でブラウザ認証を行う' 'DRY'
            return
        }

        if (-not (Confirm-Setup -Question 'GitHub CLI にログインする?' -Default $true)) {
            Write-Log 'gh: ログインしないと選択されたので GitHub CLI のログインをスキップ' 'SKIP'
            return
        }

        & gh auth login
        if ($LASTEXITCODE -eq 0) {
            Write-Change 'gh: GitHub CLI にログインした'
        } else {
            Write-Log "gh: GitHub CLI のログインに失敗した (gh auth login exit $LASTEXITCODE)" 'FAIL'
        }
    } catch {
        Write-Log "gh: GitHub CLI のログイン処理で例外が発生した - $($_.Exception.Message)" 'FAIL'
    }
}

<#
    Claude Code のログインは `claude` を起動した初回にブラウザで行う。
    ここで claude を実行すると対話 REPL に入ってセットアップが止まるので、
    入っているかと認証ファイルの有無だけ見て案内する。
#>
function Write-ClaudeCodeHint {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        return
    }

    $cred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (Test-Path -LiteralPath $cred) {
        Write-Log 'Claude Code: 認証ファイルがあるのでログイン済みに見える' 'OK'
        return
    }

    Write-Log 'Claude Code: インストール済み。ターミナルを開き直して claude を実行するとブラウザログインになる (Pro / Max / Team / Enterprise / Console が必要)' 'INFO'
}

function Invoke-DevToolsSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [switch]$Unattended
    )

    Write-SetupStep '開発ツールの仕上げ'

    # 直前のインストールで増えた PATH をこのセッションに取り込む。
    # これをやらないと volta / git / gh がまだ見つからない。
    Update-SessionPath

    Install-NodeLts  -Settings $Settings
    Set-GitIdentity  -Settings $Settings -Unattended:$Unattended
    Invoke-GhAuthLogin -Settings $Settings -Unattended:$Unattended
    Write-ClaudeCodeHint
}
