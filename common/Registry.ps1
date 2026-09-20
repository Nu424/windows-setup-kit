<#
    レジストリ書き込み。DryRun のときは何もしない。

    ユーザー単位 (HKCU) の設定は、昇格で実行アカウントが変わっている前提で
    HKEY_USERS\<元ユーザーのSID> 側に書く。
#>

function Get-UserHivePath {
    param([Parameter(Mandatory)][string]$UserSid)

    return "Registry::HKEY_USERS\$UserSid"
}

# 対象ユーザーのハイブが読み込まれているか。
# ログオンしていないユーザーの SID を渡した場合などは $false になる。
function Test-UserHive {
    param([Parameter(Mandatory)][string]$UserSid)

    return (Test-Path (Get-UserHivePath -UserSid $UserSid))
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','Binary','ExpandString','QWord')]
        [string]$Type = 'DWord'
    )

    if (Test-DryRun) { return }

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type `
                     -Force -ErrorAction Stop | Out-Null
}
