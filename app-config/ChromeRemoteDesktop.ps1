<#
    Chrome リモートデスクトップ (ホスト側) の設定。

    Google の OAuth はスクリプトから通せないので、
    ワンタイムコードの取得だけ人間がやり、残り (PIN 設定・ホスト登録・
    サービスの自動起動化) はここで片付ける。

    PIN は接続の資格情報そのものなので、画面にもログにも出さない。
#>

<#
    AppConfig.Crd の値を読む。
    Set-StrictMode 下では存在しないキーにドットで触れると例外になるので、ここを通す。
#>
function Get-CrdSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if (-not $Settings.ContainsKey('AppConfig')) { return $Default }
    $appConfig = $Settings['AppConfig']
    if ($appConfig -isnot [hashtable] -or -not $appConfig.ContainsKey('Crd')) { return $Default }

    $section = $appConfig['Crd']
    if ($section -isnot [hashtable] -or -not $section.ContainsKey($Name)) { return $Default }
    return $section[$Name]
}

# ホスト本体の導入判定。app-install 側の判定関数には依存せず、この分類だけで完結させる。
function Test-CrdHostInstalled {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }

    try {
        $listed = (Invoke-NativeCapture -FilePath 'winget' `
                       -Arguments @('list','--id','Google.ChromeRemoteDesktop','--exact','--disable-interactivity')).Output
        return ($listed -match [regex]::Escape('Google.ChromeRemoteDesktop'))
    } catch {
        return $false
    }
}

<#
    Chrome Remote Desktop Host のインストール。
    CRD を使わない人に常駐サービスを入れさせないため、アプリ一覧ではなくここで入れる。
#>
function Install-CrdHost {
    if (Test-CrdHostInstalled) {
        Write-Log 'CRD: Chrome Remote Desktop Host はインストール済み' 'OK'
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log 'CRD: winget が無いので Chrome Remote Desktop Host を導入できない。https://remotedesktop.google.com/access から手動で入れる' 'FAIL'
        return
    }

    Write-Log 'CRD: Chrome Remote Desktop Host をインストール中' 'INFO'
    try {
        $proc = Start-Process winget -Wait -PassThru -NoNewWindow -ArgumentList @(
            'install', '--id', 'Google.ChromeRemoteDesktop', '--exact',
            '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
        # -1978335189 (0x8A15002B) は「既にインストール済み」なので成功扱い
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) {
            Write-Change 'CRD: Chrome Remote Desktop Host をインストールした'
        } else {
            Write-Log "CRD: Chrome Remote Desktop Host のインストールに失敗した (winget exit $($proc.ExitCode))" 'FAIL'
        }
    } catch {
        Write-Log "CRD: Chrome Remote Desktop Host のインストール中に例外が発生した - $($_.Exception.Message)" 'FAIL'
    }
}

# ホスト登録用の exe。バージョン番号のフォルダ配下に入るので再帰で探す。
function Get-CrdStartHostExe {
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($base in $bases) {
        $dir = Join-Path $base 'Google\Chrome Remote Desktop'
        if (-not (Test-Path -LiteralPath $dir)) { continue }

        $exe = Get-ChildItem -LiteralPath $dir -Filter 'remoting_start_host.exe' -Recurse -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

# 画面に出るページ手順の案内。ログではなく手順書なので Write-Host で出す。
function Show-CrdCodeInstruction {
    Write-Host ''
    Write-Host '  ブラウザで次のページを開き、Google アカウントでログインする:' -ForegroundColor Yellow
    Write-Host '    https://remotedesktop.google.com/headless' -ForegroundColor White
    Write-Host '  「別のパソコンをセットアップ」→ 開始 → 次へ → 承認 と進むと' -ForegroundColor Yellow
    Write-Host '  Windows (Cmd) 用のコマンドが表示される。その中の --code="..." の中身をコピーする。' -ForegroundColor Yellow
    Write-Host '  (コードは数分で失効するので、コピーしたらすぐ貼る)' -ForegroundColor DarkYellow
    Write-Host ''
}

<#
    PIN の入力。
    画面に残さないため SecureString で受け、二重入力で打ち間違いを弾く。
    無限ループになると無人寄りの運用で止まってしまうので、3 回で諦める。
    入力されなかった場合は $null を返す。
#>
function Read-CrdPin {
    for ($i = 1; $i -le 3; $i++) {
        $first  = ConvertFrom-SecureStringPlain -Secure (Read-Host '  接続用 PIN (6 桁以上の数字)' -AsSecureString)
        $second = ConvertFrom-SecureStringPlain -Secure (Read-Host '  もう一度' -AsSecureString)

        if ($first -ne $second) {
            Write-Host '  2 回の入力が一致しない。入力し直す。' -ForegroundColor Red
            continue
        }
        if ($first.Length -lt 6) {
            Write-Host '  PIN は 6 桁以上にする。' -ForegroundColor Red
            continue
        }
        if ($first -notmatch '^\d+$') {
            # CRD の PIN は数字のみ。ここで弾かないとホスト登録が失敗する
            Write-Host '  PIN は数字だけで入力する。' -ForegroundColor Red
            continue
        }
        return $first
    }
    return $null
}

# 手動起動のままだと再起動後にホストが上がらず接続できないことがある。
function Set-CrdServiceAutoStart {
    $service = Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log 'CRD: chromoting サービスが見つからないので自動起動の設定をスキップ (再起動後に接続できない可能性)' 'WARN'
        return
    }

    try {
        Set-Service -Name 'chromoting' -StartupType Automatic -ErrorAction Stop
        if ($service.Status -ne 'Running') { Start-Service -Name 'chromoting' -ErrorAction Stop }
        Write-Change 'CRD: chromoting サービスを自動起動に設定した'
    } catch {
        Write-Log "CRD: chromoting サービスの自動起動設定に失敗した (再起動後に接続できない可能性) - $($_.Exception.Message)" 'FAIL'
    }
}

function Invoke-CrdSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [switch]$Unattended
    )

    Write-SetupStep 'Chrome リモートデスクトップ'

    if ($Unattended) {
        Write-Log 'CRD: 無人モードではワンタイムコードを取得できないのでホスト登録をスキップ' 'SKIP'
        return
    }

    $hostName = [string](Get-CrdSetting -Settings $Settings -Name 'HostName' -Default '')
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $env:COMPUTERNAME }

    if (Test-DryRun) {
        Write-Log 'CRD: 実行すると Chrome Remote Desktop Host (Google.ChromeRemoteDesktop) を導入する' 'DRY'
        Write-Log "CRD: 実行するとワンタイムコードと PIN を聞いて name=$hostName でホスト登録し、chromoting サービスを自動起動にする" 'DRY'
        return
    }

    Install-CrdHost

    # インストールに失敗していても別経路で入っている可能性があるので、exe の有無で最終判断する
    $starter = Get-CrdStartHostExe
    if (-not $starter) {
        Write-Log 'CRD: remoting_start_host.exe が見つからないのでホスト登録できない (ホストのインストールに失敗した可能性)' 'FAIL'
        Write-Log 'CRD: 手動なら https://remotedesktop.google.com/access からホストを入れられる' 'INFO'
        return
    }

    Show-CrdCodeInstruction
    try {
        Start-Process 'https://remotedesktop.google.com/headless' -ErrorAction Stop
    } catch {
        Write-Log 'CRD: 既定ブラウザを自動で開けなかったので https://remotedesktop.google.com/headless を手で開く' 'WARN'
    }

    $code = Read-Host '  認証コード (空 Enter でスキップ)'
    if ([string]::IsNullOrWhiteSpace($code)) {
        Write-Log 'CRD: 認証コードが入力されなかったのでホスト登録をスキップ' 'SKIP'
        return
    }
    # コマンド全体を貼られても救えるようにする
    if ($code -match '--code="?([^"\s]+)"?') { $code = $Matches[1] }
    $code = $code.Trim()

    $pin = Read-CrdPin
    if (-not $pin) {
        Write-Log 'CRD: PIN が確定しなかったのでホスト登録をスキップ' 'SKIP'
        return
    }

    Write-Log "CRD: ホストを登録中 (name=$hostName)" 'INFO'
    $exitCode = $null
    try {
        & $starter `
            --code="$code" `
            --redirect-url="https://remotedesktop.google.com/_/oauthredirect" `
            --name="$hostName" `
            --pin="$pin"
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Log "CRD: remoting_start_host.exe の実行で例外が発生しホスト登録できなかった - $($_.Exception.Message)" 'FAIL'
        return
    } finally {
        $pin = $null   # 平文の PIN を必要以上に持ち回らない
    }

    if ($exitCode -ne 0) {
        Write-Log "CRD: ホスト登録に失敗した (remoting_start_host.exe exit $exitCode)。認証コードが失効した可能性が高いので、取り直して再実行する" 'FAIL'
        return
    }

    Write-Change "CRD: ホストを登録した (name=$hostName)。remotedesktop.google.com/access に表示される"
    Set-CrdServiceAutoStart
}
