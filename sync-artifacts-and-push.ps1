param(
    [string]$SourceRepoRoot = "D:\esp32\web-wifis-RGB-ok",
    [string]$ArtifactRepoRoot = $PSScriptRoot,
    [string]$GitHubKeyPath = "C:/Users/W/.ssh/id_ed25519_github_rgb"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host "[artifact-sync-runner] $Message"
}

$resolvedSourceRoot = [System.IO.Path]::GetFullPath($SourceRepoRoot)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRepoRoot)
$syncScriptPath = Join-Path $resolvedSourceRoot "tools\sync-artifacts-to-repo.ps1"

if (-not (Test-Path -LiteralPath $resolvedSourceRoot -PathType Container)) {
    throw "Source repository directory not found: $resolvedSourceRoot"
}
if (-not (Test-Path -LiteralPath $resolvedArtifactRoot -PathType Container)) {
    throw "Artifact repository directory not found: $resolvedArtifactRoot"
}
if (-not (Test-Path -LiteralPath $syncScriptPath -PathType Leaf)) {
    throw "Sync script not found: $syncScriptPath"
}

$env:GIT_SSH_COMMAND = "ssh.exe -i `"$GitHubKeyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

Write-Log "Source repo: $resolvedSourceRoot"
Write-Log "Artifact repo: $resolvedArtifactRoot"
Write-Log "Running sync script."

& $syncScriptPath `
    -SourceRepoRoot $resolvedSourceRoot `
    -ArtifactRepoRoot $resolvedArtifactRoot `
    -ArtifactRemoteName "origin"

if ($LASTEXITCODE -ne 0) {
    throw "Artifact sync script failed with exit code $LASTEXITCODE"
}

Write-Log "Synchronization finished."
