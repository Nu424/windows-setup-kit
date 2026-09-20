<#
    設定の雛形。

    このファイルを settings.ps1 にコピーして書き換える。
    settings.ps1 は Git 管理外なので、PC 名や WiFi パスワードを書いてよい。

        Copy-Item .\settings.example.ps1 .\settings.ps1

    書かなかったキーは common\Settings.ps1 の既定値が使われる。
    変えたい項目だけ残して、あとは消してしまってもよい。
#>

@{

    # ============================================================
    #  Windows そのものの設定
    # ============================================================
    Windows = @{

        # PC名。空のままなら実行時に聞かれる (空 Enter で変更しない)
        # 15文字以内 / 英数字とハイフンのみ / 数字だけは不可
        ComputerName           = ''          # 例: 'DEV-PC01'

        # 電源タイムアウト (分)。0 = なし、$null = 今の設定のまま
        #   AC = 電源に繋いでいるとき / DC = バッテリー駆動
        MonitorTimeoutAC       = 15
        MonitorTimeoutDC       = 5
        StandbyTimeoutAC       = 0           # スリープさせない
        StandbyTimeoutDC       = 30

        # リモートデスクトップ (Home エディションでは有効化できない)
        EnableRdp              = $true
        RdpRequireNla          = $true       # ネットワークレベル認証。基本 $true

        # エクスプローラの表示
        ShowFileExtensions     = $true
        ShowHiddenFiles        = $true
        ShowSuperHidden        = $false      # 保護された OS ファイルまで出す。普通は $false

        # クリップボード履歴 (Win+V)
        EnableClipboardHistory = $true

        # スタートアップを無効にするアプリ (レジストリの Run に入っている名前)
        DisableStartupApps     = @('OneDrive')

        # PowerShell の実行ポリシー。$null ならいじらない
        SetExecutionPolicy     = $null       # 例: 'RemoteSigned'

        # 表示設定を今すぐ反映するためエクスプローラを再起動する
        RestartExplorer        = $true

        Wifi = @{
            # 設定方法は 3 通り。上から順に使われる。
            #   1) assets\wifi に置いた XML のファイル名かフルパス
            #      (assets\wifi に XML が 1 個だけなら、ここは空でも自動で使う)
            #   2) Ssid と Password を直接書く (WPA2-PSK / AES)
            #   3) どちらも空なら実行時に聞かれる (パスワードは画面に出ない)
            ProfileXml   = ''                # 例: 'Wi-Fi-MyHome.xml'
            Ssid         = ''                # 例: 'MyHomeWiFi'
            Password     = ''                # 平文。settings.ps1 は Git 管理外だが扱いは慎重に
            ConnectAfter = $true             # 登録後に接続まで試す
        }
    }

    # ============================================================
    #  ソフトのインストール
    # ============================================================
    Install = @{

        # winget で入れるもの。ID は `winget search <名前>` で調べる。
        # Scope: 'machine' 全ユーザー / 'user' 自分だけ / $null は winget のお任せ
        #   Volta は 'user' 必須 (machine だと PATH が通らず volta install node が動かない)
        Apps = @(
            @{ Name = 'Google Chrome'; Id = 'Google.Chrome';              Scope = 'machine' }
            @{ Name = 'Tailscale';     Id = 'Tailscale.Tailscale';        Scope = 'machine' }
            @{ Name = 'PowerToys';     Id = 'Microsoft.PowerToys';        Scope = 'machine' }
            @{ Name = 'Git';           Id = 'Git.Git';                    Scope = 'machine' }
            @{ Name = 'GitHub CLI';    Id = 'GitHub.cli';                 Scope = 'machine' }
            @{ Name = 'uv';            Id = 'astral-sh.uv';               Scope = $null     }
            @{ Name = 'Volta';         Id = 'Volta.Volta';                Scope = 'user'    }
            @{ Name = 'VS Code';       Id = 'Microsoft.VisualStudioCode'; Scope = 'machine' }
            # 足したいものがあれば 1 行追加する
            # @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Scope = 'machine' }
        )

        # assets\installers に置いた exe/msi はファイル名順に自動で入るので、
        # 通常このリストは空でよい。自動判別がうまくいかないものだけ書く。
        #   File        : assets\installers 内のファイル名
        #   DisplayName : インストール済み判定に使う名前 (アプリと機能に出る名前の一部)
        #   Args        : サイレントインストール引数。@() なら GUI で開く
        Installers = @(
            # @{ File = '01-DobotStudio_V1.9.4.exe'; DisplayName = 'DobotStudio'; Args = @('/S') }
        )
    }

    # ============================================================
    #  入れたソフトの設定
    # ============================================================
    AppConfig = @{

        PowerToys = @{
            # assets\powertoys の中身を %LOCALAPPDATA%\Microsoft\PowerToys に復元する
            Restore = $true
        }

        Tailscale = @{
            # https://login.tailscale.com/admin/settings/keys で発行。
            # 空ならブラウザ認証 (-Unattended のときはスキップ)
            AuthKey = ''
        }

        Crd = @{
            # Chrome リモートデスクトップに表示されるホスト名。空なら PC 名
            HostName = ''
        }

        DevTools = @{
            InstallNodeLts = $true           # volta で Node LTS を入れる
            GhAuthLogin    = $true           # gh auth login を促す
            GitUserName    = ''              # 例: 'Taro Yamada'
            GitUserEmail   = ''              # 例: 'taro@example.com'
        }
    }

    # ============================================================
    #  実体データの場所 (リポジトリからの相対パス。普通は変えない)
    # ============================================================
    Paths = @{
        Installers = 'assets\installers'
        PowerToys  = 'assets\powertoys'
        Wifi       = 'assets\wifi'
    }
}
