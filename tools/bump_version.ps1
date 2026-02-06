
$versionFile = Join-Path $PSScriptRoot "..\version.txt"
$deployScript = Join-Path $PSScriptRoot "..\deploy.sh"

if (-not (Test-Path $versionFile)) {
    Write-Error "version.txt not found at $versionFile"
    exit 1
}

$currentVersion = Get-Content $versionFile -TotalCount 1
$today = Get-Date -Format "yyyy.M.d"

if ($currentVersion -match "^$today-(\d+)$") {
    $buildNum = [int]$matches[1] + 1
    $newVersion = "$today-$buildNum"
} else {
    $newVersion = "$today-1"
}

$newVersion | Set-Content $versionFile -NoNewline
Write-Host "Bumped version: $currentVersion -> $newVersion"

# Update deploy.sh
$content = Get-Content $deployScript -Raw
$newContent = $content -replace 'SCRIPT_VERSION=".*?"', "SCRIPT_VERSION=""$newVersion"""
$newContent | Set-Content $deployScript -NoNewline
Write-Host "Updated deploy.sh with new version"
