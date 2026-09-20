<#
    assets\installers に置いた exe / msi のインストール。

    移植元は DobotStudio 専用 (*Dobot*.exe を 1 本だけ拾い、*driver* を後追いで実行) だったが、
    winget に無いソフトは Dobot に限らないので「フォルダに置いた分をまとめて入れる」汎用処理にした。
    依存順はファイル名の連番 (01- / 02- ...) で表現する運用に寄せてある。

    1 本の失敗で全部止めない。FAIL をログして次のファイルへ進む。

    外から呼ぶのは Invoke-LocalInstallers だけ。
#>

# 3010 / 1641 は「インストールは成功したが再起動が必要」。失敗として数えない。
$script:LocalInstallerRebootCodes = @(3010, 1641)

<#
    exe のバイナリ冒頭を覗いて、どのインストーラ製かを当てる。
    サイレント引数がインストーラごとに違うので、その判別用。
    (移植元は ReadAllBytes だったが、数百MB の exe を丸ごとメモリに載せる必要はないので
     判定に使う先頭 3MB だけ読む。判定条件そのものは移植元と同じ)
#>
function Get-LocalInstallerType {
    param([Parameter(Mandatory)][string]$Path)

    $len   = (Get-Item -LiteralPath $Path).Length
    $take  = [int][Math]::Min([long]$len, 3MB)
    if ($take -le 0) { return 'Unknown' }

    $bytes = New-Object byte[] $take
    $fs    = [System.IO.File]::OpenRead($Path)
    try   { $read = $fs.Read($bytes, 0, $take) }
    finally { $fs.Dispose() }

    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $read)

    if ($head -match 'Nullsoft')            { return 'NSIS' }
    if ($head -match 'Inno Setup|JR\.Inno')  { return 'Inno' }
    if ($head -match 'InstallShield')        { return 'InstallShield' }
    if ($head -match 'WixBundle|Burn\.')     { return 'Wix' }
    return 'Unknown'
}

# インストーラ種別ごとのサイレント引数。$null は「サイレントでは入れられない」の意味。
function Get-LocalInstallerSilentArgs {
    param([Parameter(Mandatory)][string]$Type)

    switch ($Type) {
        'NSIS'          { return @('/S') }
        'Inno'          { return @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') }
        'InstallShield' { return @('/s','/v"/qn REBOOT=ReallySuppress"') }
        'Wix'           { return @('/quiet','/norestart') }
        default         { return $null }
    }
}

<#
    ファイル名から製品名を推測して、照合パターンを作る。

    あくまで推測でしかない。外したときは「インストール済みなのに実行する」側に倒す
    (入れ忘れるより二重実行のほうが被害が小さい)。確実に当てたい場合は
    settings.ps1 の Install.Installers に DisplayName を書いて上書きする。

    落とすもの: 先頭の連番 / 拡張子 / バージョンらしき部分 / setup・installer などの配布物語
      '01-DobotStudio_V1.9.4.exe' -> @('DobotStudio')
      '02-CH340-driver.exe'       -> @('CH340 driver', 'CH340')
#>
function Get-LocalInstallerProductName {
    param([Parameter(Mandatory)][string]$FileName)

    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $name = $base

    # 実行順を表すための先頭連番。製品名ではない
    $name = $name -replace '^\d{1,3}[-_.\s]+', ''

    # バージョンから後ろは配布物の都合で変わる部分。DisplayName 側と一致する保証がない
    $name = $name -replace '[-_.\s]+v?\d+(\.\d+)+.*$', ''
    $name = $name -replace '[-_.\s]+v\d+.*$', ''

    # 配布物に付きがちな語。製品名として照合しても意味がない
    $name = $name -replace '[-_.\s]*\b(setup|installer|install|x64|x86|win64|win32|64bit|32bit|full|offline)\b', ''

    # 残った区切り記号は空白に寄せる (DisplayName は空白区切りのことが多い)
    $name = ($name -replace '[-_.]+', ' ').Trim()
    $name = ($name -replace '\s{2,}', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($name)) { return @($base) }

    $patterns = @($name)

    # 'CH340 driver' のように語が続く場合、DisplayName 側の語順や表記が違って
    # 丸ごとでは当たらないことがあるので先頭の語だけでも見る。
    # 短い語は無関係な製品に当たるので除く。
    $first = ($name -split '\s+')[0]
    if ($first -ne $name -and $first.Length -ge 4) { $patterns += $first }

    return $patterns
}

<#
    「プログラムと機能」に載っている DisplayName を照合して、
    当たったらその DisplayName を返す (当たらなければ $null)。
    32bit 版インストーラは WOW6432Node 側に載るので両方見る。
#>
function Get-LocalInstallerInstalledName {
    param([Parameter(Mandatory)][string[]]$Patterns)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entries = @()
    try {
        $entries = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)
    } catch {
        # 判定できないだけなので未インストール扱いで進める
        return $null
    }

    foreach ($e in $entries) {
        # DisplayName を持たないキー (更新プログラムなど) があるので存在確認してから触る
        if ($e.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
        $display = [string]$e.DisplayName
        if ([string]::IsNullOrWhiteSpace($display)) { continue }

        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($display -like "*$p*") { return $display }
        }
    }
    return $null
}

# settings.ps1 の Install.Installers に同名エントリがあれば、それを返す。
# キー自体が無い設定でも動くようにしておく。
function Get-LocalInstallerOverride {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$FileName
    )

    if (-not $Settings.ContainsKey('Install') -or $Settings.Install -isnot [hashtable]) { return $null }
    $install = $Settings.Install
    if (-not $install.ContainsKey('Installers') -or -not $install.Installers) { return $null }

    foreach ($entry in @($install.Installers)) {
        if ($entry -isnot [hashtable] -or -not $entry.ContainsKey('File')) { continue }
        if ([string]$entry.File -eq $FileName) { return $entry }
    }
    return $null
}

# Start-Process は空の -ArgumentList を受け付けないので呼び分ける。
# インストーラは直列に流したいので必ず終了を待つ。
function Start-LocalInstallerProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList
    )

    if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    } else {
        $p = Start-Process -FilePath $FilePath -Wait -PassThru
    }
    if ($null -eq $p) { return -1 }
    return [int]$p.ExitCode
}

# 1 本インストールする。FAIL をログしたときだけ $false を返す。
function Install-LocalInstallerFile {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [hashtable]$Override,
        [switch]$Unattended
    )

    $label = $File.Name

    # インストール済み判定に使う名前。settings.ps1 の DisplayName があればそれを優先する
    if ($Override -and $Override.ContainsKey('DisplayName') -and
        -not [string]::IsNullOrWhiteSpace([string]$Override.DisplayName)) {
        $patterns = @([string]$Override.DisplayName)
    } else {
        $patterns = Get-LocalInstallerProductName -FileName $label
    }

    # DryRun でも読み取りだけなので判定はしてよい
    $installed = Get-LocalInstallerInstalledName -Patterns $patterns
    if ($installed) {
        Write-Log "$label : 「$installed」がインストール済みなのでスキップ" 'SKIP'
        return $true
    }

    # 実行するコマンドと引数を決める。
    # $silentArgs が $null なら「サイレントでは入れられない」= GUI に任せる。
    $isMsi   = ($File.Extension -eq '.msi')
    $quoted  = '"{0}"' -f $File.FullName
    $target  = if ($isMsi) { 'msiexec.exe' } else { $File.FullName }
    $guiArgs = if ($isMsi) { @('/i', $quoted) } else { @() }

    $overrideArgs = $null
    $hasOverrideArgs = ($Override -and $Override.ContainsKey('Args') -and $null -ne $Override.Args)
    if ($hasOverrideArgs) { $overrideArgs = @($Override.Args) }

    if ($isMsi) {
        # msi は msiexec に渡す形が決まっているので、上書きされるのは後ろの引数だけ
        $typeLabel  = 'msi'
        $silentArgs = @('/i', $quoted, '/qn', '/norestart')
        if ($hasOverrideArgs) {
            $typeLabel  = 'msi (settings.ps1 の指定)'
            $silentArgs = if ($overrideArgs.Count -gt 0) { @('/i', $quoted) + $overrideArgs } else { $null }
        }
    } elseif ($hasOverrideArgs) {
        # Args = @() は「サイレントにしないで GUI で開く」の意思表示として扱う
        $typeLabel  = 'settings.ps1 の指定'
        $silentArgs = if ($overrideArgs.Count -gt 0) { $overrideArgs } else { $null }
    } else {
        $typeLabel  = Get-LocalInstallerType -Path $File.FullName
        $silentArgs = Get-LocalInstallerSilentArgs -Type $typeLabel
    }

    if (Test-DryRun) {
        if ($silentArgs) {
            Write-Log "$label : 種別 $typeLabel。$target $($silentArgs -join ' ') を実行する (DryRun)" 'DRY'
        } elseif ($Unattended) {
            Write-Log "$label : 種別 $typeLabel でサイレント引数が無く -Unattended なので実行しない (DryRun)" 'DRY'
        } else {
            Write-Log "$label : 種別 $typeLabel でサイレント引数が無いので GUI で起動する (DryRun)" 'DRY'
        }
        return $true
    }

    if ($silentArgs) {
        Write-Log "$label : 種別 $typeLabel と判定。サイレントインストール中 (引数: $($silentArgs -join ' '))" 'INFO'
        $exit = Start-LocalInstallerProcess -FilePath $target -ArgumentList $silentArgs

        if ($exit -eq 0) {
            Write-Change "$label : サイレントインストールした"
            return $true
        }
        if ($script:LocalInstallerRebootCodes -contains $exit) {
            Write-Log "$label : インストールできたが、反映には再起動が必要 (exit $exit)" 'WARN'
            return $true
        }
        if ($Unattended) {
            Write-Log "$label : サイレントインストールが exit $exit で失敗。-Unattended なので GUI は出さない。手動で入れる" 'FAIL'
            return $false
        }
        # サイレント引数が合っていない可能性があるので、人間に進めてもらうほうへ倒す
        Write-Log "$label : サイレントインストールが exit $exit で失敗したので GUI にフォールバックする" 'WARN'
    } else {
        if ($Unattended) {
            Write-Log "$label : 種別 $typeLabel でサイレント引数が判別できず、-Unattended なので飛ばした。手動で入れる" 'WARN'
            return $true
        }
        Write-Log "$label : 種別 $typeLabel でサイレント引数が判別できないので GUI で起動する" 'INFO'
    }

    Write-Log "$label : インストーラを起動した。ウィザードを最後まで進める" 'INFO'
    $exit = Start-LocalInstallerProcess -FilePath $target -ArgumentList $guiArgs
    if ($exit -eq 0 -or $script:LocalInstallerRebootCodes -contains $exit) {
        Write-Change "$label : ウィザードが完了した"
        return $true
    }
    # 途中でキャンセルしても非 0 になるので、失敗と断定はしない
    Write-Log "$label : ウィザードが exit $exit で終了した。入ったか「アプリと機能」で確認する" 'WARN'
    return $true
}

function Invoke-LocalInstallers {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Unattended
    )

    Write-SetupStep 'ソフトのインストール (同梱インストーラ)'

    $configured = ''
    if ($Settings.ContainsKey('Paths') -and $Settings.Paths -is [hashtable] -and
        $Settings.Paths.ContainsKey('Installers')) {
        $configured = [string]$Settings.Paths.Installers
    }

    $dir = Resolve-AssetPath -Root $Root -Path $configured
    if (-not $dir) {
        Write-Log '同梱インストーラの置き場 (Paths.Installers) が設定されていないのでスキップ' 'SKIP'
        return
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Log "同梱インストーラのフォルダが無いのでスキップ: $dir" 'SKIP'
        Write-Log "$configured に exe / msi を置くと、次回のセットアップでファイル名順に入る" 'INFO'
        return
    }

    # 直下だけを見る。展開済みフォルダの中にある付属 exe を誤って実行しないため。
    # 実行順はファイル名の昇順 (01- / 02- ... で依存順を表す運用)。
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe', '.msi' } |
               Sort-Object -Property Name)

    if ($files.Count -eq 0) {
        Write-Log "同梱インストーラが 1 本も無いのでスキップ: $dir" 'SKIP'
        Write-Log "$configured に exe / msi を置くと、次回のセットアップでファイル名順に入る" 'INFO'
        return
    }

    Write-Log ("同梱インストーラ {0} 本を順に処理する: {1}" -f $files.Count, ($files.Name -join ', ')) 'INFO'

    $failed = @()
    foreach ($file in $files) {
        $override = Get-LocalInstallerOverride -Settings $Settings -FileName $file.Name
        try {
            if (-not (Install-LocalInstallerFile -File $file -Override $override -Unattended:$Unattended)) {
                $failed += $file.Name
            }
        } catch {
            # 1 本の失敗で残りを止めない
            Write-Log "$($file.Name) : インストール中に例外 - $($_.Exception.Message)" 'FAIL'
            $failed += $file.Name
        }
    }

    if ($failed.Count -gt 0) {
        # 個々の FAIL は既に出しているので、ここは見返し用の 1 行にとどめる
        Write-Log ("同梱インストーラで入らなかったもの: {0}" -f ($failed -join ', ')) 'INFO'
    }
}
