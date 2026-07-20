param(
    [string]$SourceRepoRoot = "D:\esp32\web-wifis-RGB-ok",
    [string]$PilotlightWorkspaceRoot = "D:\esp32\ESP32-IDF",
    [string]$ArtifactRepoRoot = $PSScriptRoot,
    [string]$GitHubKeyPath = "C:/Users/W/.ssh/id_ed25519_github_rgb"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host "[artifact-sync-runner] $Message"
}

$resolvedSourceRoot = [System.IO.Path]::GetFullPath($SourceRepoRoot)
$resolvedPilotlightRoot = [System.IO.Path]::GetFullPath($PilotlightWorkspaceRoot)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRepoRoot)
$syncScriptPath = Join-Path $resolvedArtifactRoot "sync-artifacts-to-repo.ps1"

if (-not (Test-Path -LiteralPath $resolvedSourceRoot -PathType Container)) {
    throw "Source repository directory not found: $resolvedSourceRoot"
}
if (-not (Test-Path -LiteralPath $resolvedPilotlightRoot -PathType Container)) {
    throw "Pilotlight workspace directory not found: $resolvedPilotlightRoot"
}
if (-not (Test-Path -LiteralPath $resolvedArtifactRoot -PathType Container)) {
    throw "Artifact repository directory not found: $resolvedArtifactRoot"
}
if (-not (Test-Path -LiteralPath $syncScriptPath -PathType Leaf)) {
    throw "Sync script not found: $syncScriptPath"
}

$env:GIT_SSH_COMMAND = "ssh.exe -i `"$GitHubKeyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

Write-Log "Source repo: $resolvedSourceRoot"
Write-Log "Pilotlight workspace: $resolvedPilotlightRoot"
Write-Log "Artifact repo: $resolvedArtifactRoot"
Write-Log "Running sync script."

& $syncScriptPath `
    -PrimarySourceRepoRoot $resolvedSourceRoot `
    -PilotlightWorkspaceRoot $resolvedPilotlightRoot `
    -ArtifactRepoRoot $resolvedArtifactRoot `
    -ArtifactRemoteName "origin"

if ($LASTEXITCODE -ne 0) {
    throw "Artifact sync script failed with exit code $LASTEXITCODE"
}

Write-Log "Synchronization finished."
