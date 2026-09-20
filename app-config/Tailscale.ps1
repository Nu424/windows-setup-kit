<#
    Tailscale のログイン。

    インストールは app-install 側で終わっている前提。
    Auth key があれば無人でログインでき、無ければブラウザ認証になる。

    Auth key は資格情報そのものなので、ログにも画面にも値を出さない。
    tailscale up の出力にキーが混ざる可能性があるため、その出力も残さない。
#>

<#
    AppConfig.Tailscale の値を読む。
    Set-StrictMode 下では存在しないキーにドットで触れると例外になるので、ここを通す。
#>
function Get-TailscaleSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if (-not $Settings.ContainsKey('AppConfig')) { return $Default }
    $appConfig = $Settings['AppConfig']
    if ($appConfig -isnot [hashtable] -or -not $appConfig.ContainsKey('Tailscale')) { return $Default }

    $section = $appConfig['Tailscale']
    if ($section -isnot [hashtable] -or -not $section.ContainsKey($Name)) { return $Default }
    return $section[$Name]
}

# tailscale.exe の場所。インストール直後は PATH が通っていないことがあるので、既定の場所も見る。
function Get-TailscaleExePath {
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($base in $bases) {
        $path = Join-Path $base 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }

    $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

<#
    ログイン済みかどうか。
    BackendState が Running ならログイン済みで接続中。
    状態を取れなかったときは判断できないので $false を返し、ログインを試させる。
#>
function Test-TailscaleLoggedIn {
    param([Parameter(Mandatory)][string]$ExePath)

    try {
        # ステータスは標準出力に出る。ここでの stderr リダイレクトは
        # $ErrorActionPreference='Stop' 下で例外になるので使わない。
        $status = & $ExePath status --json | Out-String
        return ($status -match '"BackendState"\s*:\s*"Running"')
    } catch {
        Write-Log "Tailscale: 接続状態を確認できなかったのでログイン済みか判断できない - $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-TailscaleSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [switch]$Unattended
    )

    Write-SetupStep 'Tailscale'

    $exe = Get-TailscaleExePath
    if (-not $exe) {
        Write-Log 'Tailscale: tailscale.exe が見つからないのでログインをスキップ (インストールに失敗している可能性)' 'SKIP'
        return
    }

    if (Test-TailscaleLoggedIn -ExePath $exe) {
        Write-Log 'Tailscale: 既にログイン済みで接続中なのでスキップ' 'SKIP'
        return
    }

    $authKey = [string](Get-TailscaleSetting -Settings $Settings -Name 'AuthKey' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($authKey)) {
        if (Test-DryRun) {
            Write-Log 'Tailscale: 実行すると settings.ps1 の Auth key で無人ログイン (tailscale up --unattended) する' 'DRY'
            return
        }

        Write-Log 'Tailscale: settings.ps1 の Auth key でログイン中 (キーの内容はログに残さない)' 'INFO'
        try {
            # 出力に Auth key が混ざりうるので捨てる。成否は終了コードだけで判断する。
            & $exe up --authkey=$authKey --unattended | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Change 'Tailscale: Auth key でログインして接続した'
            } else {
                Write-Log "Tailscale: Auth key でのログインに失敗した (tailscale up exit $LASTEXITCODE)。キーの失効や権限を確認する" 'FAIL'
            }
        } catch {
            Write-Log "Tailscale: Auth key でのログイン中に例外が発生した - $($_.Exception.Message)" 'FAIL'
        }
        return
    }

    if ($Unattended) {
        Write-Log 'Tailscale: Auth key が未設定で無人モードなのでログインをスキップ (settings.ps1 の AppConfig.Tailscale.AuthKey を設定すると無人でログインできる)' 'SKIP'
        return
    }

    if (Test-DryRun) {
        Write-Log 'Tailscale: 実行するとブラウザ認証 (tailscale up) を開始する' 'DRY'
        return
    }

    Write-Log 'Tailscale: ブラウザが開くので Tailscale アカウントでログインする' 'INFO'
    try {
        & $exe up
        if ($LASTEXITCODE -eq 0) {
            Write-Change 'Tailscale: ブラウザ認証でログインして接続した'
        } else {
            Write-Log "Tailscale: ブラウザ認証でのログインに失敗した (tailscale up exit $LASTEXITCODE)" 'FAIL'
        }
    } catch {
        Write-Log "Tailscale: ブラウザ認証でのログイン中に例外が発生した - $($_.Exception.Message)" 'FAIL'
    }
}
