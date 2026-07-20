param(
    [string]$PrimarySourceRepoRoot = "D:\esp32\web-wifis-RGB-ok",
    [string]$PilotlightWorkspaceRoot = "D:\esp32\ESP32-IDF",
    [string]$ArtifactRepoRoot = $PSScriptRoot,
    [string]$ArtifactRemoteName = "origin",
    [switch]$ResetWorkspace
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host "[artifact-sync] $Message"
}

function Resolve-NormalizedPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-RelativePathSafe {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $resolvedBase = Resolve-NormalizedPath $BasePath
    $resolvedTarget = Resolve-NormalizedPath $TargetPath

    if ($resolvedTarget.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedTarget.Substring($resolvedBase.Length).TrimStart("\")
    }

    $baseUri = New-Object System.Uri(($resolvedBase.TrimEnd("\") + "\"))
    $targetUri = New-Object System.Uri($resolvedTarget)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
}

function Ensure-GitRepository {
    param([string]$RepoRoot)

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
        throw "Git repository not found: $RepoRoot"
    }
}

function Reset-ArtifactWorkspace {
    param([string]$ArtifactRoot)

    $preservedNames = @(
        ".git",
        "README.md",
        "sync-artifacts-to-repo.ps1",
        "sync-artifacts-and-push.ps1",
        "sync-artifacts-and-push.cmd"
    )

    Get-ChildItem -LiteralPath $ArtifactRoot -Force | Where-Object {
        $preservedNames -notcontains $_.Name
    } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

function Get-GitValueOrEmpty {
    param(
        [string]$RepoRoot,
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
        return ""
    }

    $result = & git -C $RepoRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return ($result | Out-String).Trim()
}

function Get-GitMetadata {
    param([string]$RepoRoot)

    return [ordered]@{
        path   = Resolve-NormalizedPath $RepoRoot
        remote = Get-GitValueOrEmpty -RepoRoot $RepoRoot -Arguments @("remote", "get-url", "origin")
        branch = Get-GitValueOrEmpty -RepoRoot $RepoRoot -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
        commit = Get-GitValueOrEmpty -RepoRoot $RepoRoot -Arguments @("rev-parse", "HEAD")
    }
}

function Convert-ToRawBaseUrl {
    param(
        [string]$RemoteUrl,
        [string]$BranchName
    )

    if ([string]::IsNullOrWhiteSpace($RemoteUrl) -or [string]::IsNullOrWhiteSpace($BranchName)) {
        return ""
    }

    $normalized = $RemoteUrl.Trim()
    if ($normalized.StartsWith("git@gitee.com:")) {
        $normalized = "https://gitee.com/" + $normalized.Substring("git@gitee.com:".Length)
    } elseif ($normalized.StartsWith("git@github.com:")) {
        $normalized = "https://github.com/" + $normalized.Substring("git@github.com:".Length)
    }
    if ($normalized.EndsWith(".git")) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }

    if ($normalized.StartsWith("https://gitee.com/")) {
        return "$normalized/raw/$BranchName"
    }

    if ($normalized.StartsWith("https://github.com/")) {
        $repoPath = $normalized.Substring("https://github.com/".Length).Trim("/")
        return "https://raw.githubusercontent.com/$repoPath/$BranchName"
    }

    return ""
}

function Convert-ToPagesBaseUrl {
    param([string]$RemoteUrl)

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return ""
    }

    $normalized = $RemoteUrl.Trim()
    $provider = ""
    if ($normalized.StartsWith("git@gitee.com:")) {
        $provider = "gitee"
        $normalized = $normalized.Substring("git@gitee.com:".Length)
    } elseif ($normalized.StartsWith("git@github.com:")) {
        $provider = "github"
        $normalized = $normalized.Substring("git@github.com:".Length)
    } elseif ($normalized.StartsWith("https://gitee.com/")) {
        $provider = "gitee"
        $normalized = $normalized.Substring("https://gitee.com/".Length)
    } elseif ($normalized.StartsWith("https://github.com/")) {
        $provider = "github"
        $normalized = $normalized.Substring("https://github.com/".Length)
    }

    if ($normalized.EndsWith(".git")) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }

    $parts = $normalized.Trim("/").Split("/")
    if ($parts.Length -lt 2) {
        return ""
    }

    $owner = $parts[0]
    $repo = $parts[1]

    if ($provider -eq "github") {
        return "https://$owner.github.io/$repo"
    }
    if ($provider -eq "gitee") {
        return "https://$owner.gitee.io/$repo"
    }

    return ""
}

function Parse-ApkVersionInfo {
    param([string]$RelativePath)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath)
    $match = [System.Text.RegularExpressions.Regex]::Match($name, "^RGBController-(debug|release)-(?<versionName>.+)-(?<versionCode>\d+)-(?<buildTime>\d{8}_\d{4})$")
    if (-not $match.Success) {
        return @{
            versionName = ""
            versionCode = 0
            buildTime   = ""
        }
    }

    return @{
        versionName = $match.Groups["versionName"].Value
        versionCode = [int]$match.Groups["versionCode"].Value
        buildTime   = $match.Groups["buildTime"].Value
    }
}

function Get-TextFileTrimmedOrEmpty {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

function Get-Esp32Version {
    param([string]$SourceRoot)

    $version = Get-TextFileTrimmedOrEmpty -Path (Join-Path $SourceRoot "esp32-s3-supermini-rgb-control\version.txt")
    if ($version) {
        return $version
    }

    return ""
}

function Get-Esp8266Version {
    param([string]$SourceRoot)

    $version = Get-TextFileTrimmedOrEmpty -Path (Join-Path $SourceRoot "esp8266-esp01s-rgb-control\version.txt")
    if ($version) {
        return $version
    }

    return "1.0.0-esp8266-port-"
}

function Get-PilotlightVersion {
    param(
        [string]$PilotlightWorkspaceRoot,
        [string]$PilotlightRelativePath
    )

    $projectRoot = Join-Path $PilotlightWorkspaceRoot "pilotlight-idf"
    $version = Get-TextFileTrimmedOrEmpty -Path (Join-Path $projectRoot "version.txt")
    if ($version) {
        return $version
    }

    $timestamp = Get-TextFileTrimmedOrEmpty -Path (Join-Path $projectRoot "build\.bin_timestamp")
    if ($timestamp) {
        return $timestamp
    }

    $artifactPath = Join-Path $PilotlightWorkspaceRoot $PilotlightRelativePath
    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        return (Get-Item -LiteralPath $artifactPath).LastWriteTime.ToString("yyyyMMdd_HHmmss")
    }

    return ""
}

function Get-LatestManifestEntry {
    param(
        [System.Collections.IEnumerable]$ManifestEntries,
        [scriptblock]$Filter
    )

    return $ManifestEntries |
        Where-Object $Filter |
        Sort-Object { [DateTime]$_.lastWriteUtc } -Descending |
        Select-Object -First 1
}

function Get-PrimaryArtifactRelativePaths {
    param([string]$Root)

    $relativePaths = New-Object System.Collections.Generic.List[string]

    $apkRoot = Join-Path $Root "app-controller\app\build\outputs\apk"
    if (Test-Path -LiteralPath $apkRoot -PathType Container) {
        Get-ChildItem -LiteralPath $apkRoot -Recurse -File | Where-Object {
            $_.Extension.Equals(".apk", [System.StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object {
            $relativePaths.Add((Get-RelativePathSafe -BasePath $Root -TargetPath $_.FullName)) | Out-Null
        }
    }

    @(
        "esp32-s3-supermini-rgb-control\build\esp32.esp32.esp32s3\esp32-s3-supermini-rgb-control.ino.bin",
        "esp8266-esp01s-rgb-control\build\esp8266.esp8266.generic\esp8266-esp01s-rgb-control.ino.bin"
    ) | ForEach-Object {
        $fullPath = Join-Path $Root $_
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $relativePaths.Add((Get-RelativePathSafe -BasePath $Root -TargetPath $fullPath)) | Out-Null
        }
    }

    return @($relativePaths | Sort-Object -Unique)
}

function Get-AllArtifactSources {
    param(
        [string]$PrimarySourceRoot,
        [string]$PilotlightRoot
    )

    $sources = New-Object System.Collections.Generic.List[object]

    $primaryPaths = Get-PrimaryArtifactRelativePaths -Root $PrimarySourceRoot
    foreach ($relativePath in $primaryPaths) {
        $sources.Add([pscustomobject]@{
            SourceRoot    = $PrimarySourceRoot
            RelativePath  = $relativePath
            SourceName    = "primary"
        }) | Out-Null
    }

    $pilotlightRelativePath = "pilotlight-idf\build\pilotlight_esp32.bin"
    $pilotlightFullPath = Join-Path $PilotlightRoot $pilotlightRelativePath
    if (Test-Path -LiteralPath $pilotlightFullPath -PathType Leaf) {
        $sources.Add([pscustomobject]@{
            SourceRoot    = $PilotlightRoot
            RelativePath  = $pilotlightRelativePath
            SourceName    = "pilotlight"
        }) | Out-Null
    }

    return $sources.ToArray()
}

function Copy-Artifacts {
    param(
        [System.Collections.IEnumerable]$ArtifactSources,
        [string]$ArtifactRoot
    )

    $manifestEntries = New-Object System.Collections.Generic.List[object]

    foreach ($artifact in $ArtifactSources) {
        $sourcePath = Join-Path $artifact.SourceRoot $artifact.RelativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Artifact file not found: $sourcePath"
        }

        $destinationPath = Join-Path $ArtifactRoot ("payload\" + $artifact.RelativePath)
        $destinationDirectory = Split-Path -Path $destinationPath -Parent
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

        $file = Get-Item -LiteralPath $sourcePath
        $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestEntries.Add([ordered]@{
            relativePath = $artifact.RelativePath.Replace("\", "/")
            sizeBytes    = $file.Length
            lastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
            sha256       = $hash
        }) | Out-Null
    }

    return $manifestEntries.ToArray()
}

function New-LatestJsonObject {
    param(
        [System.Collections.IEnumerable]$ManifestEntries,
        [System.Collections.IDictionary]$ArtifactRepoMetadata,
        [string]$PrimarySourceRoot,
        [string]$PilotlightRoot
    )

    $rawBaseUrl = Convert-ToRawBaseUrl -RemoteUrl $ArtifactRepoMetadata.remote -BranchName $ArtifactRepoMetadata.branch
    $pagesBaseUrl = Convert-ToPagesBaseUrl -RemoteUrl $ArtifactRepoMetadata.remote

    $latestReleaseApk = Get-LatestManifestEntry -ManifestEntries $ManifestEntries -Filter {
        $_.relativePath -like "app-controller/app/build/outputs/apk/release/*.apk"
    }
    $latestDebugApk = Get-LatestManifestEntry -ManifestEntries $ManifestEntries -Filter {
        $_.relativePath -like "app-controller/app/build/outputs/apk/debug/*.apk"
    }
    $latestEsp32Bin = Get-LatestManifestEntry -ManifestEntries $ManifestEntries -Filter {
        $_.relativePath -eq "esp32-s3-supermini-rgb-control/build/esp32.esp32.esp32s3/esp32-s3-supermini-rgb-control.ino.bin"
    }
    $latestEsp8266Bin = Get-LatestManifestEntry -ManifestEntries $ManifestEntries -Filter {
        $_.relativePath -eq "esp8266-esp01s-rgb-control/build/esp8266.esp8266.generic/esp8266-esp01s-rgb-control.ino.bin"
    }
    $latestPilotlightBin = Get-LatestManifestEntry -ManifestEntries $ManifestEntries -Filter {
        $_.relativePath -eq "pilotlight-idf/build/pilotlight_esp32.bin"
    }

    $appReleaseInfo = if ($null -ne $latestReleaseApk) { Parse-ApkVersionInfo -RelativePath $latestReleaseApk.relativePath } else { @{ versionName = ""; versionCode = 0; buildTime = "" } }
    $appDebugInfo = if ($null -ne $latestDebugApk) { Parse-ApkVersionInfo -RelativePath $latestDebugApk.relativePath } else { @{ versionName = ""; versionCode = 0; buildTime = "" } }

    return [ordered]@{
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        sources = [ordered]@{
            recommendedManifestUrl = if ($pagesBaseUrl) { "$pagesBaseUrl/latest.json" } elseif ($rawBaseUrl) { "$rawBaseUrl/latest.json" } else { "" }
            pagesManifestUrl       = if ($pagesBaseUrl) { "$pagesBaseUrl/latest.json" } else { "" }
            rawManifestUrl         = if ($rawBaseUrl) { "$rawBaseUrl/latest.json" } else { "" }
        }
        app = [ordered]@{
            release = if ($null -ne $latestReleaseApk) {
                [ordered]@{
                    versionName  = $appReleaseInfo.versionName
                    versionCode  = $appReleaseInfo.versionCode
                    buildTime    = $appReleaseInfo.buildTime
                    relativePath = "payload/$($latestReleaseApk.relativePath)"
                    sha256       = $latestReleaseApk.sha256
                    sizeBytes    = $latestReleaseApk.sizeBytes
                    pageUrl      = if ($pagesBaseUrl) { "$pagesBaseUrl/payload/$($latestReleaseApk.relativePath)" } else { "" }
                    rawUrl       = if ($rawBaseUrl) { "$rawBaseUrl/payload/$($latestReleaseApk.relativePath)" } else { "" }
                }
            } else { $null }
            debug = if ($null -ne $latestDebugApk) {
                [ordered]@{
                    versionName  = $appDebugInfo.versionName
                    versionCode  = $appDebugInfo.versionCode
                    buildTime    = $appDebugInfo.buildTime
                    relativePath = "payload/$($latestDebugApk.relativePath)"
                    sha256       = $latestDebugApk.sha256
                    sizeBytes    = $latestDebugApk.sizeBytes
                    pageUrl      = if ($pagesBaseUrl) { "$pagesBaseUrl/payload/$($latestDebugApk.relativePath)" } else { "" }
                    rawUrl       = if ($rawBaseUrl) { "$rawBaseUrl/payload/$($latestDebugApk.relativePath)" } else { "" }
                }
            } else { $null }
        }
        firmware = [ordered]@{
            esp32S3 = if ($null -ne $latestEsp32Bin) {
                [ordered]@{
                    version      = Get-Esp32Version -SourceRoot $PrimarySourceRoot
                    relativePath = "payload/$($latestEsp32Bin.relativePath)"
                    sha256       = $latestEsp32Bin.sha256
                    sizeBytes    = $latestEsp32Bin.sizeBytes
                    pageUrl      = if ($pagesBaseUrl) { "$pagesBaseUrl/payload/$($latestEsp32Bin.relativePath)" } else { "" }
                    rawUrl       = if ($rawBaseUrl) { "$rawBaseUrl/payload/$($latestEsp32Bin.relativePath)" } else { "" }
                }
            } else { $null }
            esp8266Esp01s = if ($null -ne $latestEsp8266Bin) {
                [ordered]@{
                    version      = Get-Esp8266Version -SourceRoot $PrimarySourceRoot
                    relativePath = "payload/$($latestEsp8266Bin.relativePath)"
                    sha256       = $latestEsp8266Bin.sha256
                    sizeBytes    = $latestEsp8266Bin.sizeBytes
                    pageUrl      = if ($pagesBaseUrl) { "$pagesBaseUrl/payload/$($latestEsp8266Bin.relativePath)" } else { "" }
                    rawUrl       = if ($rawBaseUrl) { "$rawBaseUrl/payload/$($latestEsp8266Bin.relativePath)" } else { "" }
                }
            } else { $null }
            pilotlightEsp32 = if ($null -ne $latestPilotlightBin) {
                [ordered]@{
                    version      = Get-PilotlightVersion -PilotlightWorkspaceRoot $PilotlightRoot -PilotlightRelativePath "pilotlight-idf\build\pilotlight_esp32.bin"
                    relativePath = "payload/$($latestPilotlightBin.relativePath)"
                    sha256       = $latestPilotlightBin.sha256
                    sizeBytes    = $latestPilotlightBin.sizeBytes
                    pageUrl      = if ($pagesBaseUrl) { "$pagesBaseUrl/payload/$($latestPilotlightBin.relativePath)" } else { "" }
                    rawUrl       = if ($rawBaseUrl) { "$rawBaseUrl/payload/$($latestPilotlightBin.relativePath)" } else { "" }
                }
            } else { $null }
        }
    }
}

function Write-ArtifactMetadata {
    param(
        [System.Collections.IEnumerable]$ManifestEntries,
        [string]$ArtifactRoot,
        [System.Collections.IDictionary]$PrimarySourceMetadata,
        [System.Collections.IDictionary]$PilotlightSourceMetadata,
        [System.Collections.IDictionary]$ArtifactRepoMetadata,
        [string]$PrimarySourceRoot,
        [string]$PilotlightRoot
    )

    $manifestObject = [ordered]@{
        sourceRepo       = $PrimarySourceMetadata
        additionalSources = @(
            [ordered]@{
                name                 = "pilotlight-idf"
                path                 = $PilotlightSourceMetadata.path
                remote               = $PilotlightSourceMetadata.remote
                branch               = $PilotlightSourceMetadata.branch
                commit               = $PilotlightSourceMetadata.commit
                relativeArtifactPath = "pilotlight-idf/build/pilotlight_esp32.bin"
            }
        )
        syncedAtUtc      = [DateTime]::UtcNow.ToString("o")
        artifactCount    = $ManifestEntries.Count
        files            = @($ManifestEntries)
    }

    $manifestJson = $manifestObject | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath (Join-Path $ArtifactRoot "artifact-manifest.json") -Value $manifestJson -Encoding UTF8

    $latestJsonObject = New-LatestJsonObject -ManifestEntries $ManifestEntries -ArtifactRepoMetadata $ArtifactRepoMetadata -PrimarySourceRoot $PrimarySourceRoot -PilotlightRoot $PilotlightRoot
    $latestJson = $latestJsonObject | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath (Join-Path $ArtifactRoot "latest.json") -Value $latestJson -Encoding UTF8
}

function Get-SyncCommitLabel {
    param(
        [System.Collections.IDictionary]$PrimarySourceMetadata,
        [System.Collections.IDictionary]$PilotlightSourceMetadata
    )

    $labels = New-Object System.Collections.Generic.List[string]
    if ($PrimarySourceMetadata.commit) {
        $labels.Add("web-wifis-RGB-ok@$($PrimarySourceMetadata.commit.Substring(0, [Math]::Min(7, $PrimarySourceMetadata.commit.Length)))") | Out-Null
    }
    if ($PilotlightSourceMetadata.commit) {
        $labels.Add("pilotlight-idf@$($PilotlightSourceMetadata.commit.Substring(0, [Math]::Min(7, $PilotlightSourceMetadata.commit.Length)))") | Out-Null
    }

    if ($labels.Count -eq 0) {
        return "sync artifacts"
    }

    return "sync artifacts from " + ($labels -join ", ")
}

function Commit-And-PushArtifactRepo {
    param(
        [string]$ArtifactRoot,
        [string]$CommitMessage,
        [string]$RemoteName
    )

    & git -C $ArtifactRoot add -A
    if ($LASTEXITCODE -ne 0) {
        throw "git add failed in artifact repository"
    }

    $statusLines = @(& git -C $ArtifactRoot status --short)
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in artifact repository"
    }

    if ($statusLines.Count -eq 0) {
        Write-Log "No artifact changes detected."
        return
    }

    & git -C $ArtifactRoot commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed in artifact repository"
    }

    $remotes = @(& git -C $ArtifactRoot remote)
    if ($LASTEXITCODE -ne 0) {
        throw "git remote failed in artifact repository"
    }

    if ($remotes -contains $RemoteName) {
        Write-Log "Pushing artifact repository to remote '$RemoteName'."
        & git -C $ArtifactRoot push -u $RemoteName HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "git push failed in artifact repository"
        }
    } else {
        Write-Log "Artifact repository has no remote '$RemoteName'. Local commit created, push skipped."
    }
}

$resolvedPrimarySourceRoot = Resolve-NormalizedPath $PrimarySourceRepoRoot
$resolvedPilotlightRoot = Resolve-NormalizedPath $PilotlightWorkspaceRoot
$resolvedArtifactRoot = Resolve-NormalizedPath $ArtifactRepoRoot

if (-not (Test-Path -LiteralPath $resolvedPrimarySourceRoot -PathType Container)) {
    throw "Primary source repository directory not found: $resolvedPrimarySourceRoot"
}
if (-not (Test-Path -LiteralPath $resolvedPilotlightRoot -PathType Container)) {
    throw "Pilotlight workspace directory not found: $resolvedPilotlightRoot"
}
if (-not (Test-Path -LiteralPath $resolvedArtifactRoot -PathType Container)) {
    throw "Artifact repository directory not found: $resolvedArtifactRoot"
}

Ensure-GitRepository -RepoRoot $resolvedArtifactRoot
if ($ResetWorkspace) {
    Write-Log "Resetting artifact repository contents before sync."
    Reset-ArtifactWorkspace -ArtifactRoot $resolvedArtifactRoot
}

$primarySourceMetadata = Get-GitMetadata -RepoRoot $resolvedPrimarySourceRoot
$pilotlightSourceMetadata = Get-GitMetadata -RepoRoot (Join-Path $resolvedPilotlightRoot "pilotlight-idf")
$artifactRepoMetadata = Get-GitMetadata -RepoRoot $resolvedArtifactRoot

$artifactSources = Get-AllArtifactSources -PrimarySourceRoot $resolvedPrimarySourceRoot -PilotlightRoot $resolvedPilotlightRoot
Write-Log "Discovered $($artifactSources.Count) artifact file(s) across all sources."

$manifestEntries = Copy-Artifacts -ArtifactSources $artifactSources -ArtifactRoot $resolvedArtifactRoot
Write-ArtifactMetadata `
    -ManifestEntries $manifestEntries `
    -ArtifactRoot $resolvedArtifactRoot `
    -PrimarySourceMetadata $primarySourceMetadata `
    -PilotlightSourceMetadata $pilotlightSourceMetadata `
    -ArtifactRepoMetadata $artifactRepoMetadata `
    -PrimarySourceRoot $resolvedPrimarySourceRoot `
    -PilotlightRoot $resolvedPilotlightRoot

$commitMessage = Get-SyncCommitLabel -PrimarySourceMetadata $primarySourceMetadata -PilotlightSourceMetadata $pilotlightSourceMetadata
Commit-And-PushArtifactRepo -ArtifactRoot $resolvedArtifactRoot -CommitMessage $commitMessage -RemoteName $ArtifactRemoteName
Write-Log "Artifact synchronization completed."
