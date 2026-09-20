<#
    管理者への昇格と、設定対象ユーザーの特定。

    昇格すると実行アカウントが変わるため、HKCU に入れるべき設定
    (エクスプローラ表示・クリップボード履歴・スタートアップ) が
    昇格先の管理者アカウントに入ってしまう。
    それを避けるため、昇格前のユーザーの SID を -UserSid で引き継ぐ。
#>

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-CurrentUserName {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Resolve-UserName {
    param([Parameter(Mandatory)][string]$Sid)

    try {
        return (New-Object Security.Principal.SecurityIdentifier($Sid)).
               Translate([Security.Principal.NTAccount]).Value
    } catch {
        return $Sid
    }
}

# 昇格プロセスを起動する。起動できたら $true (呼び出し側は自分を終了する)
function Start-ElevatedSetup {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{},
        [Parameter(Mandatory)][string]$UserSid
    )

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")

    foreach ($kv in $BoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'UserSid') { continue }   # あとで確定値を渡す
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } else {
            $argList += @("-$($kv.Key)", "`"$($kv.Value)`"")
        }
    }
    $argList += @('-UserSid', $UserSid)

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
