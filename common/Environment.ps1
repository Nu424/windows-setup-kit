<#
    実行中セッションの環境変数まわり。
#>

# インストール直後でも、この PowerShell から新しいコマンドを呼べるようにする。
# (本来は再起動 / ターミナル再起動が必要な PATH を手で読み直している)
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}
