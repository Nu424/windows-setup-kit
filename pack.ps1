<#
.SYNOPSIS
    配布用 zip を 1 個作る。

.DESCRIPTION
    Git で管理しているスクリプト一式を、日付スタンプ付きの zip にまとめる。
    できたファイルは dist\windows-setup-matome-vyymmdd.zip。

    settings.ps1 と assets の実体データ (インストーラ / PowerToys / WiFi) は
    機ごとに違う・秘密を含むので入れない。.git と実行ログも入れない。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\pack.ps1
    powershell -ExecutionPolicy Bypass -File .\pack.ps1 -Stamp 260920
    powershell -ExecutionPolicy Bypass -File .\pack.ps1 -DryRun
#>

[CmdletBinding()]
param(
    # yymmdd。先頭の v はあってもよい。空なら実行日
    [string]$Stamp,

    # 実際には書かず、何が入る予定かだけ表示する
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitName = 'windows-setup-matome'

# ------------------------------------------------------------
#  スタンプ (v + yymmdd)
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Stamp)) {
    $Stamp = Get-Date -Format 'yyMMdd'
} else {
    $Stamp = $Stamp.Trim()
    if ($Stamp -like 'v*') { $Stamp = $Stamp.Substring(1) }
}

if ($Stamp -notmatch '^\d{6}$') {
    Write-Host "[!] Stamp は yymmdd (例: 260920) にする。受け取った値: '$Stamp'" -ForegroundColor Red
    exit 1
}

$Version     = "v$Stamp"
$ArchiveName = "$KitName-$Version"
$DistDir     = Join-Path $Root 'dist'
$ZipPath     = Join-Path $DistDir "$ArchiveName.zip"

# トップレベルで丸ごと飛ばすフォルダ。中は走査しない
$SkipTopDirs = @('.git', 'dist')

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][string]$RootPath
    )
    $prefix = $RootPath.TrimEnd('\') + '\'
    if ($FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($prefix.Length)
    }
    return (Split-Path -Leaf $FullName)
}

<#
    zip に入れないファイル。
      - settings.ps1 / ログ / 別の zip
      - assets\installers|powertoys|wifi の実体 (.gitkeep だけ残す)
#>
function Test-PackSkipFile {
    param(
        [Parameter(Mandatory)][string]$RelativePath
    )

    $rel = $RelativePath.Replace('/', '\')
    $leaf = Split-Path -Leaf $rel

    if ($rel -eq 'settings.ps1') { return $true }
    if ($leaf -like '*.log')     { return $true }
    if ($leaf -like '*.zip')     { return $true }

    $parts = $rel.Split('\')
    if ($parts.Length -ge 3 -and $parts[0] -eq 'assets' -and
        $parts[1] -in @('installers', 'powertoys', 'wifi') -and
        $leaf -ne '.gitkeep') {
        return $true
    }

    return $false
}

function Get-PackFiles {
    $items = New-Object System.Collections.Generic.List[object]

    Get-ChildItem -LiteralPath $Root -Force | Where-Object {
        -not ($_.PSIsContainer -and $_.Name -in $SkipTopDirs)
    } | ForEach-Object {
        $files = if ($_.PSIsContainer) {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue
        } else {
            @($_)
        }

        foreach ($file in @($files)) {
            $rel = Get-RelativePathFromRoot -FullName $file.FullName -RootPath $Root
            if (Test-PackSkipFile -RelativePath $rel) { continue }
            $items.Add([pscustomobject]@{ FullName = $file.FullName; RelativePath = $rel })
        }
    }

    return @($items | Sort-Object RelativePath)
}

$files = Get-PackFiles
if ($files.Count -eq 0) {
    Write-Host '[!] zip に入れるファイルが 1 つも無い' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "  配布用 zip: $ArchiveName.zip" -ForegroundColor Cyan
Write-Host "  ファイル数: $($files.Count)"
Write-Host ''

if ($DryRun) {
    foreach ($f in $files) {
        Write-Host "  [DRY] $($f.RelativePath)" -ForegroundColor Magenta
    }
    Write-Host ''
    Write-Host "  実行すると dist\$ArchiveName.zip を作る" -ForegroundColor Magenta
    exit 0
}

$stageRoot = Join-Path $env:TEMP ("pack-$KitName-" + [guid]::NewGuid().ToString('N'))
$payload   = Join-Path $stageRoot $ArchiveName

try {
    New-Item -ItemType Directory -Path $payload -Force | Out-Null

    foreach ($f in $files) {
        $dest = Join-Path $payload $f.RelativePath
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }

    if (-not (Test-Path -LiteralPath $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }
    # Compress-Archive は既存 zip へ追記するので、同名があれば先に消す
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    Compress-Archive -Path $payload -DestinationPath $ZipPath -CompressionLevel Optimal

    $zip = Get-Item -LiteralPath $ZipPath
    Write-Host "  作成した: $($zip.FullName)" -ForegroundColor Green
    Write-Host ("  サイズ:   {0:N1} KB" -f ($zip.Length / 1KB))
    Write-Host ''
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
