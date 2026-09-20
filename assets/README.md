# assets

スクリプトではない「自分で用意する実体データ」の置き場。
このフォルダの中身は Git で管理していないので、USB にコピーしたあと手で入れる。

## installers/

winget に無いソフトの `.exe` / `.msi` を直下に置く。サブフォルダは見ない。

ファイル名の昇順で実行するので、順番に意味があるものは番号を振る。

```
01-DobotStudio_V1.9.4.exe
02-CH340-driver.exe
```

インストーラの種別（NSIS / Inno Setup / InstallShield / WiX / msi）は
スクリプトが exe の中身を見て判定し、サイレント引数を自動で選ぶ。
判定できなかったものは GUI が立ち上がるので、そのときだけ手で進める。

サイレント引数を明示したい場合は、ルートの `settings.ps1` の `$Installers` に書く。

## powertoys/

移行元PCの `%LOCALAPPDATA%\Microsoft\PowerToys` の中身を丸ごとコピーして置く。
空なら PowerToys の設定復元はスキップされる。

## wifi/

WiFi プロファイルの XML 置き場。移行元PCで次のように出力したもの。

```
netsh wlan export profile name="SSID名" key=clear folder="."
```

XML を使わず `settings.ps1` に SSID とパスワードを書く方法、
実行時に聞かれる方法でも設定できる。
