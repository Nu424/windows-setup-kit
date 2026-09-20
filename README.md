# Windows セットアップキット

新しい Windows PC の初期設定とソフト導入を 1 回で終わらせるスクリプト集。
USB メモリにフォルダごと入れて持ち歩き、`Setup.cmd` をダブルクリックするだけで動く。

何度実行しても壊れない。既に設定済み・インストール済みのものはスキップされる。

## USB での使い方

1. このリポジトリをフォルダごと USB にコピーする
2. `settings.example.ps1` を `settings.ps1` にコピーして、PC 名や WiFi などを書く
   （書かなくても動く。空の項目は実行時に聞かれる）
3. winget に無いソフトの exe / msi を `assets\installers\` に置く
4. `Setup.cmd` をダブルクリックする（管理者権限は自動で取り直す）

初回はまず動きを見たいので、PowerShell から次を実行するとよい。
実際には何も変更せず、何が起きるかだけ表示する。

```powershell
.\Setup.cmd -DryRun
```

## 何が起きるか

| 分類 | 内容 |
|---|---|
| Windows の設定 | PC 名、電源タイムアウト、リモートデスクトップ、拡張子と隠しファイルの表示、クリップボード履歴、スタートアップ無効化、WiFi プロファイル |
| ソフトのインストール | winget での一括インストール、`assets\installers` に置いた exe / msi の一括インストール |
| 入れたソフトの設定 | PowerToys 設定の復元、Tailscale ログイン、Chrome リモートデスクトップのホスト登録、Node LTS、git の名前とメール、GitHub CLI ログイン |

実行ログは `setup_日時.log` に残る（USB が書き込み禁止なら `%TEMP%` に出る）。
失敗した項目は最後のサマリにまとまるので、まずそこを見る。

## フォルダ構成

```
Setup.cmd                 ダブルクリックする入口
setup.ps1                 どの分類をどの順で流すかだけ
settings.ps1              ← 編集するのはここ一本 (Git 管理外)
settings.example.ps1      その雛形

common/                   全分類が使う土台 (ログ / 昇格 / レジストリ / 設定読み込み)
windows-settings/         Windows そのものの設定
app-install/              ソフトのインストール
app-config/               入れたソフトの設定・ログイン

assets/                   スクリプトではない実体データ (中身は Git 管理外)
  installers/             exe / msi を置く
  powertoys/              PowerToys の設定ファイル一式
  wifi/                   WiFi プロファイルの XML

ref/                      整理前の試作。実行には使わない
```

分類フォルダにはスクリプトだけ、`assets/` にはデータだけを置く。
自分で用意する物は `assets/` の下と `settings.ps1` だけ。

## 同梱インストーラ（winget に無いソフト）

`assets\installers\` の直下に置いた `.exe` / `.msi` を**ファイル名の昇順で全部**入れる。
順番に意味があるものは番号を振る。

```
01-DobotStudio_V1.9.4.exe
02-CH340-driver.exe
```

インストーラの種別（NSIS / Inno Setup / InstallShield / WiX / msi）は exe の中身を見て判定し、
サイレント引数を自動で選ぶ。判定できなかったものは GUI が立ち上がるので、そのときだけ手で進める。

サイレント引数を明示したい場合は `settings.ps1` の `Install.Installers` に書く。

```powershell
Installers = @(
    @{ File = '01-DobotStudio_V1.9.4.exe'; DisplayName = 'DobotStudio'; Args = @('/S') }
)
```

## スイッチ

分類ごとにも項目ごとにも飛ばせる。失効した認証コードを取り直して CRD だけやり直す、といった使い方ができる。

```powershell
.\Setup.cmd -SkipWindowsSettings -SkipAppInstall     # 入れたソフトの設定だけ
.\Setup.cmd -SkipWinget -SkipAppConfig               # 同梱インストーラだけ
```

| スイッチ | 効果 |
|---|---|
| `-DryRun` | 変更せず、何をやるかだけ表示する |
| `-Unattended` | 一切聞かない。手入力が要るものは全部スキップする |
| `-SkipWindowsSettings` / `-SkipAppInstall` / `-SkipAppConfig` | 分類ごと飛ばす |
| `-SkipWifi` / `-SkipWinget` / `-SkipInstallers` / `-SkipPowerToys` / `-SkipTailscale` / `-SkipCrd` / `-SkipDevTools` | 項目ごと飛ばす |
| `-TailscaleAuthKey "tskey-auth-xxxx"` | `settings.ps1` より優先して Tailscale に自動ログインする |

無人で流すなら次の形になる。

```powershell
.\Setup.cmd -Unattended -TailscaleAuthKey "tskey-auth-xxxx"
```

## 事前に用意するもの

`assets\README.md` に置き方を書いてある。要点だけ挙げると:

- **installers**: winget に無いソフトの exe / msi
- **powertoys**: 移行元 PC の `%LOCALAPPDATA%\Microsoft\PowerToys` の中身を丸ごと
- **wifi**: `netsh wlan export profile name="SSID名" key=clear folder="."` で出した XML
  （1 個だけ置いてあれば自動で使う。SSID とパスワードを `settings.ps1` に書く方法、実行時に聞かれる方法でもよい）

## 手作業が残るところ

Google の OAuth と 2 段階認証は自動化できないので、ここは手で進める。

- **Chrome の Google ログイン**: ログインして同期を ON にすれば、拡張機能・ブックマーク・パスワードは全部降ってくる
- **Chrome リモートデスクトップの認証コード**: スクリプトが `remotedesktop.google.com/headless` を開くので、表示される `--code="..."` の中身を貼る。PIN 設定とサービスの自動起動化はスクリプトがやる
- **GitHub CLI のログイン**: 最後に聞かれる。ブラウザ認証
- **VS Code の設定同期**: 左下のアカウントアイコンから。GitHub ログインで拡張機能ごと復元される

## つまずきポイント

- **CRD の認証コードは数分で失効する**。コピーしたらすぐ貼る。失効したら取り直して `-SkipWindowsSettings -SkipAppInstall` で CRD だけやり直せる
- **PATH は再起動後に反映される**。スクリプト内では都度読み直しているが、作業を続けるならターミナルを開き直す
- **Volta だけユーザースコープ必須**。machine で入れると PATH が他ユーザーに通らず `volta install node` が動かない
- **リモートデスクトップは Home エディションでは有効化できない**。WARN が出るだけで先へ進む
- **WiFi パスワードは `settings.ps1` に平文で入る**。このファイルは Git 管理外だが、USB の扱いには注意する
- **`.ps1` を編集するときは UTF-8 BOM 付きで保存する**。Windows PowerShell 5.1 は BOM が無いとコメントの日本語を読み違える

## 設定を足すには

winget で入れるソフトを足すなら、`settings.ps1` の `Install.Apps` に 1 行足すだけ。

```powershell
@{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Scope = 'machine' }
```

ID は `winget search <名前>` で調べられる。

新しい設定項目そのものを増やす場合は、まず `common\Settings.ps1` の `Get-DefaultSettings`
に既定値を書く。ここが設定キーの定義元で、`settings.ps1` は差分だけを持つ。
