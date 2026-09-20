<#
    設定の読み込み。

    ルートの settings.ps1 はハッシュテーブルを 1 個返すだけのファイル。
    書かれていないキーは Get-DefaultSettings の値で補うので、
    settings.ps1 には変えたい項目だけ書けばよい。

    Get-DefaultSettings が設定キーの唯一の定義元。
    新しい設定を足すときは、まずここに既定値を書く。
#>

function Get-DefaultSettings {
    return @{

        # ---------- Windows そのものの設定 ----------
        Windows = @{
            # 空なら実行時に聞く (15文字以内 / 英数字とハイフン)
            ComputerName           = ''

            # 分単位。0 = なし。$null は変更しない
            MonitorTimeoutAC       = 15
            MonitorTimeoutDC       = 5
            StandbyTimeoutAC       = 0
            StandbyTimeoutDC       = 30

            EnableRdp              = $true
            RdpRequireNla          = $true

            ShowFileExtensions     = $true
            ShowHiddenFiles        = $true
            ShowSuperHidden        = $false

            EnableClipboardHistory = $true

            # タスクマネージャーの「スタートアップ」で無効にする登録名
            DisableStartupApps     = @('OneDrive')

            # $null ならいじらない。'RemoteSigned' などを指定すると恒久変更
            SetExecutionPolicy     = $null

            # 表示設定の即時反映に必要
            RestartExplorer        = $true

            Wifi = @{
                # 3通り: XML を指定 / SSID とパスワードを書く / どちらも空なら実行時に聞く
                ProfileXml   = ''
                Ssid         = ''
                Password     = ''
                ConnectAfter = $true
            }
        }

        # ---------- ソフトのインストール ----------
        Install = @{
            # Scope: 'machine' 全ユーザー / 'user' 自分だけ / $null は winget のお任せ
            Apps = @(
                @{ Name = 'Google Chrome'; Id = 'Google.Chrome';              Scope = 'machine' }
                @{ Name = 'Tailscale';     Id = 'tailscale.tailscale';        Scope = 'machine' }
                @{ Name = 'PowerToys';     Id = 'Microsoft.PowerToys';        Scope = 'machine' }
                @{ Name = 'Git';           Id = 'Git.Git';                    Scope = 'machine' }
                @{ Name = 'GitHub CLI';    Id = 'GitHub.cli';                 Scope = 'machine' }
                @{ Name = 'uv';            Id = 'astral-sh.uv';               Scope = $null     }
                @{ Name = 'Volta';         Id = 'Volta.Volta';                Scope = 'user'    }
                @{ Name = 'VS Code';       Id = 'Microsoft.VisualStudioCode'; Scope = 'machine' }
            )

            # assets\installers の exe/msi は自動で拾うので、通常は空でよい。
            # 自動判別を上書きしたいものだけ書く:
            #   @{ File = '01-Foo.exe'; DisplayName = 'Foo'; Args = @('/S') }
            Installers = @()
        }

        # ---------- 入れたソフトの設定 ----------
        AppConfig = @{
            PowerToys = @{
                Restore = $true
            }
            Tailscale = @{
                # https://login.tailscale.com/admin/settings/keys で発行
                AuthKey = ''
            }
            Crd = @{
                # 空なら PC 名を使う
                HostName = ''
            }
            DevTools = @{
                InstallNodeLts = $true
                GhAuthLogin    = $true
                GitUserName    = ''
                GitUserEmail   = ''
            }
        }

        # ---------- 実体データの場所 (リポジトリからの相対パス) ----------
        Paths = @{
            Installers = 'assets\installers'
            PowerToys  = 'assets\powertoys'
            Wifi       = 'assets\wifi'
        }
    }
}

# 既定値に settings.ps1 の内容をかぶせる (入れ子のハッシュテーブルも辿る)
function Merge-SettingsHashtable {
    param(
        [Parameter(Mandatory)][hashtable]$Base,
        [hashtable]$Override
    )

    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    if (-not $Override) { return $result }

    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-SettingsHashtable -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Import-SetupSettings {
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root 'settings.ps1'
    if (-not (Test-Path $path)) {
        Write-Log 'settings.ps1 が無いので既定値で進める。足りない値は実行時に聞く。' 'WARN'
        Write-Log 'settings.example.ps1 をコピーして settings.ps1 を作ると、次回から聞かれない。' 'INFO'
        return (Get-DefaultSettings)
    }

    $loaded = & $path
    if ($loaded -isnot [hashtable]) {
        throw "settings.ps1 はハッシュテーブルを 1 個返す必要がある (settings.example.ps1 を参照)"
    }

    Write-Log "設定を読み込んだ: $path" 'OK'
    return (Merge-SettingsHashtable -Base (Get-DefaultSettings) -Override $loaded)
}

# 相対パスをリポジトリルート基準の絶対パスにする
function Resolve-AssetPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([IO.Path]::IsPathRooted($Path))      { return $Path }
    return (Join-Path $Root $Path)
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

<#
    設定値が空なら実行時に聞く。
    -Unattended のときは聞かずに '' を返す (呼び出し側はスキップ扱いにする)。
    空 Enter でもスキップできる。
#>
function Get-SettingOrPrompt {
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Secret,
        [switch]$Unattended
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Unattended) { return '' }

    if ($Secret) {
        $secure = Read-Host "  $Prompt" -AsSecureString
        return (ConvertFrom-SecureStringPlain -Secure $secure)
    }
    return (Read-Host "  $Prompt").Trim()
}

# はい/いいえの確認。-Unattended のときは $Default をそのまま返す。
function Confirm-Setup {
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$Default = $true,
        [switch]$Unattended
    )

    if ($Unattended) { return $Default }

    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans  = Read-Host "  $Question $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return ($ans -match '^[yY]')
}
