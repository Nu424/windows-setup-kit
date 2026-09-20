# 開発用PC セットアップキット

USBメモリなりに `devpc-setup` フォルダごと入れて持ち歩く想定。

## フォルダ構成

```
devpc-setup/
├── setup.ps1                  ← これを実行する
├── README.md
├── installers/
│   └── DobotStudio_x.x.x.exe  ← ここに置く（ファイル名に "Dobot" が入ってれば自動で拾う）
└── config/
    └── powertoys/             ← PowerToys の設定ファイル一式（後述）
```

## 使い方

PowerShell を開いて（管理者権限は不要、必要なら勝手に昇格する）:

```powershell
cd <このフォルダ>
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

無人で回したいとき:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 `
  -TailscaleAuthKey "tskey-auth-xxxxxxxx" -Unattended
```

部分的に回したいとき（何度実行しても安全）:

| スイッチ | 効果 |
|---|---|
| `-SkipApps` | winget インストールを飛ばす |
| `-SkipDobot` | DobotStudio を飛ばす |
| `-SkipPowerToysConfig` | PowerToys 設定復元を飛ばす |
| `-SkipTailscale` | Tailscale ログインを飛ばす |
| `-SkipCrd` | Chromeリモートデスクトップを飛ばす |

---

## 事前に用意するもの

### 1. DobotStudio の exe

`installers/` に置くだけ。スクリプトが exe の中身を覗いて
NSIS / Inno Setup / InstallShield / WiX のどれかを判別し、
それぞれに合ったサイレント引数を自動で使う。
判別できないインストーラーだった場合は GUI が立ち上がるので、そのときだけ手で進める。

同じフォルダにファイル名へ `driver` を含む exe を置いておくと、本体のあとに続けて実行する（CH340 などのUSBドライバ用）。

### 2. PowerToys の設定

移行元のPCで、

```
%LOCALAPPDATA%\Microsoft\PowerToys
```

の中身を丸ごとコピーして `config/powertoys/` に入れておく。
スクリプトが PowerToys を一度停止 → 既存設定を `.bak_日時` に退避 → 上書き → 再起動する。

> PowerToys の「バックアップと復元」機能で作った `.ptb` を使う手もあるけど、
> フォルダ丸ごとのほうが復元漏れがなくて確実。

### 3. Tailscale の Auth key（任意）

https://login.tailscale.com/admin/settings/keys で発行。
`-TailscaleAuthKey` に渡すとブラウザ認証なしで繋がる。
渡さない場合はブラウザが開くので手でログインする。

---

## 手作業が残るところ

正直に言うと、ここは自動化できない。Google の OAuth + 2段階認証の壁。

| やること | 補足 |
|---|---|
| **Chrome の Googleログイン** | ログインして同期をONにすれば、拡張機能・ブックマーク・パスワードは全部降ってくる。実質これ1回で済む |
| **Chromeリモートデスクトップの認証コード** | スクリプトが `remotedesktop.google.com/headless` を自動で開く。そこで出る `--code="..."` の中身を貼るだけ。PIN設定とサービスの自動起動化はスクリプトがやる |
| **gh auth login** | 最後に聞かれる。ブラウザ認証 |
| **git の名前/メール** | 完了時に案内が出る |
| **VS Code の設定同期** | 左下のアカウントアイコンから。GitHubログインで拡張機能ごと復元される |

---

## インストールされるもの

| アプリ | winget ID |
|---|---|
| Google Chrome | `Google.Chrome` |
| Tailscale | `tailscale.tailscale` |
| PowerToys | `Microsoft.PowerToys` |
| Git | `Git.Git` |
| GitHub CLI | `GitHub.cli` |
| uv | `astral-sh.uv` |
| Volta | `Volta.Volta` |
| VS Code | `Microsoft.VisualStudioCode` |
| Chrome Remote Desktop Host | `Google.ChromeRemoteDesktop` |

追加したいものがあれば `setup.ps1` 冒頭の `$Apps` に1行足すだけ。

```powershell
@{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Scope = 'machine' }
```

ID は `winget search <名前>` で調べられる。

---

## つまずきポイント

- **Volta だけ `Scope = 'user'`**。machine スコープで入れると PATH が他ユーザーに通らず、`volta install node` が動かない。
- **PATH は再起動後に反映される**。スクリプト内では都度読み直してるけど、作業を続けるならターミナルは開き直すこと。
- **CRDの認証コードは数分で失効する**。コピーしたらすぐ貼る。失効したら取り直して `-SkipApps` 付きで再実行すれば CRD だけやり直せる。
- 実行ログは `setup_日時.log` に残る。失敗したら中を見る。
