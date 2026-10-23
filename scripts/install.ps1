#Requires -Version 5.1
# Install a prebuilt gdcli binary on Windows.
#
# Env overrides:
#   GDCLI_VERSION      release to install ("0.9.0" or "v0.9.0"); default: latest
#   GDCLI_BASE_URL     directory holding the release assets; default: the GitHub release
#   GDCLI_INSTALL_DIR  destination directory; default: %LOCALAPPDATA%\gdcli\bin
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'haytham818/gdcli'
$BinaryName = 'gdcli.exe'

# Windows PowerShell 5.1 does not negotiate TLS 1.2 on older builds by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Assert-GdcliVersion {
    param([string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+') {
        throw "Invalid version '$Version'; expected a version such as 0.9.0"
    }
}

function Resolve-GdcliVersion {
    if ($env:GDCLI_VERSION) {
        $pinned = $env:GDCLI_VERSION.Trim()
        if ($pinned.StartsWith('v')) {
            $pinned = $pinned.Substring(1)
        }
        Assert-GdcliVersion -Version $pinned
        return $pinned
    }

    Write-Host "Resolving the latest gdcli release..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'gdcli-install' }
    } catch {
        throw "Could not resolve the latest release from GitHub ($($_.Exception.Message)). Set GDCLI_VERSION to pin a version."
    }
    if (-not $release -or -not $release.tag_name) {
        throw "GitHub did not return a release tag. Set GDCLI_VERSION to pin a version."
    }

    $latest = $release.tag_name
    if ($latest.StartsWith('v')) {
        $latest = $latest.Substring(1)
    }
    Assert-GdcliVersion -Version $latest
    return $latest
}

function Resolve-GdcliTarget {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }

    switch ($arch) {
        'AMD64' { return 'x86_64-pc-windows-msvc' }
        'x86' { throw "32-bit Windows is not supported by the published builds." }
        'ARM64' { throw "Windows ARM64 builds are not yet published. Build from source with: cargo install --git https://github.com/$Repo" }
        default { throw "Unsupported Windows architecture: $arch" }
    }
}

function Resolve-GdcliInstallDir {
    if ($env:GDCLI_INSTALL_DIR) {
        return $env:GDCLI_INSTALL_DIR
    }
    if (-not $env:LOCALAPPDATA) {
        throw "LOCALAPPDATA is not set; set GDCLI_INSTALL_DIR instead."
    }
    return (Join-Path $env:LOCALAPPDATA 'gdcli\bin')
}

function Get-ExpectedHash {
    param(
        [string]$SumsPath,
        [string]$FileName
    )

    foreach ($line in (Get-Content -Path $SumsPath)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }
        $fields = $trimmed -split '\s+', 2
        if ($fields.Count -lt 2) {
            continue
        }
        $listed = $fields[1].Trim()
        if ($listed.StartsWith('*')) {
            $listed = $listed.Substring(1)
        }
        if ($listed -eq $FileName) {
            return $fields[0].ToLowerInvariant()
        }
    }
    throw "SHA256SUMS does not list $FileName"
}

function ConvertTo-NormalizedPath {
    param([string]$Value)

    $trimmed = $Value.Trim()
    $trimmed = $trimmed.Trim([char[]]'"')
    return $trimmed.TrimEnd([char[]]'\')
}

# Returns true when the directory was added to the user PATH.
function Add-ToUserPath {
    param([string]$Directory)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) {
        $userPath = ''
    }

    $normalized = ConvertTo-NormalizedPath -Value $Directory
    foreach ($entry in ($userPath -split ';')) {
        if (-not $entry) {
            continue
        }
        if ((ConvertTo-NormalizedPath -Value $entry) -ieq $normalized) {
            return $false
        }
    }

    if ($userPath) {
        $newPath = "$Directory;$userPath"
    } else {
        $newPath = $Directory
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    return $true
}

$version = Resolve-GdcliVersion
$target = Resolve-GdcliTarget
$installDir = Resolve-GdcliInstallDir

$baseUrl = $env:GDCLI_BASE_URL
if ($baseUrl) {
    $baseUrl = $baseUrl.TrimEnd([char[]]'/')
} else {
    $baseUrl = "https://github.com/$Repo/releases/download/v$version"
}

$archiveName = "gdcli-$version-$target.zip"
$archiveUrl = "$baseUrl/$archiveName"
$sumsUrl = "$baseUrl/SHA256SUMS"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gdcli-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $archivePath = Join-Path $tempDir $archiveName
    $sumsPath = Join-Path $tempDir 'SHA256SUMS'

    Write-Host "Downloading $archiveUrl"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -UseBasicParsing

    $expected = Get-ExpectedHash -SumsPath $sumsPath -FileName $archiveName
    $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Checksum mismatch for ${archiveName}: expected $expected, got $actual"
    }

    $extractDir = Join-Path $tempDir 'extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
    $binary = Join-Path $extractDir $BinaryName
    if (-not (Test-Path -Path $binary -PathType Leaf)) {
        throw "$archiveName did not contain $BinaryName"
    }

    if (-not (Test-Path -Path $installDir -PathType Container)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    $installedExe = Join-Path $installDir $BinaryName
    Copy-Item -Path $binary -Destination $installedExe -Force

    $addedToPath = Add-ToUserPath -Directory $installDir
    if ($addedToPath) {
        Write-Host "Added $installDir to your user PATH."
    }

    Write-Host "Installed $installedExe"
    & $installedExe --version
    if ($LASTEXITCODE -ne 0) {
        throw "the installed binary failed to run"
    }

    Write-Host ""
    Write-Host "Restart your shell (or sign out and back in) so the updated PATH is picked up."
} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
