<#
    ネイティブコマンド (winget / netsh / powercfg など) の実行。

    $ErrorActionPreference = 'Stop' のもとでは、ネイティブコマンドの
    stderr を PowerShell 側で受け取った時点で NativeCommandError となり、
    終了コードを見る前に処理が止まってしまう。
    出力と終了コードの両方を見たいコマンドは必ずここを通す。
#>

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output.Trim()
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}
