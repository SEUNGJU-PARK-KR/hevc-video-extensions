#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the free HEVC Video Extensions on any Windows 10 / 11 PC using the
    package build that the local machine can actually run.

.DESCRIPTION
    HEVC (H.265) playback on Windows lives in a Store package:
    Microsoft.HEVCVideoExtension (Store ID 9N4WGH0Z6VHQ, "HEVC Video Extensions
    from Device Manufacturer"). Two things make a naive install fail:

      1. The free listing is hidden from Store search on most machines.
      2. Microsoft ships several bundle builds and the newest one refuses to
         install on older OS builds with 0x80073CFD ("not compatible with this
         device"). On this author's machine 2.5.48.0 required build 26200 while
         the OS was 22631, so 2.4.149.0 was the correct pick.

    This script profiles the PC, then reads TargetDeviceFamily MinVersion out of
    every candidate bundle manifest before installing anything, so each machine
    gets the newest bundle it supports instead of a hardcoded file name.

    Candidate sources, in priority order:
      1. local  - *.appxbundle next to this script or in .\packages
      2. cache  - %LOCALAPPDATA%\HEVC-Installer\cache
      3. github - assets of the latest GitHub release of this repository
      4. store  - Microsoft delivery CDN resolved through the public catalog

    Every bundle is verified with its Authenticode signature before install.

.PARAMETER Force
    Reinstall or upgrade even when the package is already present and healthy.

.PARAMETER Uninstall
    Remove Microsoft.HEVCVideoExtension for the current user.

.PARAMETER Diagnose
    Print the machine profile, hardware decode estimate and available candidate
    sources without installing anything.

.PARAMETER AllUsers
    Install (or uninstall) for every user on the machine. Requires elevation.

.PARAMETER Offline
    Only use bundles that are already on disk. No network access at all.

.PARAMETER NoNetwork
    Skip network candidate sources but allow signature/state checks (used by CI).

.PARAMETER BundlePath
    Install a specific .appxbundle instead of resolving one automatically.

.PARAMETER CacheDir
    Where downloaded bundles are kept. Default: %LOCALAPPDATA%\HEVC-Installer\cache

.PARAMETER LogFile
    Transcript path. Default: %LOCALAPPDATA%\HEVC-Installer\install.log

.PARAMETER TimeoutSec
    Per-download timeout in seconds. Default: 900

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-HEVC.ps1

.EXAMPLE
    .\Install-HEVC.ps1 -Diagnose

.EXAMPLE
    .\Install-HEVC.ps1 -Offline -BundlePath .\packages\Microsoft.HEVCVideoExtension_2.4.149.0_neutral_~_8wekyb3d8bbwe.appxbundle

.NOTES
    Exit codes
      0  installed successfully
      10 already installed, nothing to do
      20 no compatible package found
      21 bundle path not found
      30 install or removal failed
      40 not supported on this OS

    Author : SEUNGJU-PARK-KR
    License: MIT
    Project: https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Diagnose,
    [switch]$AllUsers,
    [switch]$Offline,
    [switch]$NoNetwork,
    [string]$BundlePath,
    [string]$CacheDir,
    [string]$LogFile,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:ProductId    = '9N4WGH0Z6VHQ'
$script:PackageName  = 'Microsoft.HEVCVideoExtension'
$script:RepoSlug     = 'SEUNGJU-PARK-KR/hevc-video-extensions'
$script:UserAgent    = 'HEVC-Extension-Installer/1.0 (+https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions)'
$script:StoreProduct = 'https://apps.microsoft.com/detail/9N4WGH0Z6VHQ'

if (-not $CacheDir) { $CacheDir = Join-Path $env:LOCALAPPDATA 'HEVC-Installer\cache' }
if (-not $LogFile)  { $LogFile  = Join-Path $env:LOCALAPPDATA 'HEVC-Installer\install.log' }

$script:CacheDir = $CacheDir
$script:LogFile  = $LogFile
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = (Get-Location).Path }

try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null } catch { }
try { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null } catch { }

# ----------------------------------------------------------------------------
# logging / ui
# ----------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    $color = @{ INFO = 'Gray'; STEP = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; DEBUG = 'DarkGray' }[$Level]
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Banner {
    Write-Host ''
    Write-Host '  HEVC Video Extensions installer' -ForegroundColor White
    Write-Host '  build-aware install for Windows 10 / 11' -ForegroundColor DarkGray
    Write-Host '  ----------------------------------------------------' -ForegroundColor DarkGray
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ----------------------------------------------------------------------------
# machine profiling
# ----------------------------------------------------------------------------
function Get-SystemProfile {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $build = [int]$cv.CurrentBuildNumber
    $ubr = 0
    if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = [int]$cv.UBR }

    $major = 10
    $minor = 0
    if ($cv.PSObject.Properties.Name -contains 'CurrentMajorVersionNumber' -and $cv.CurrentMajorVersionNumber) {
        $major = [int]$cv.CurrentMajorVersionNumber
    }
    if ($cv.PSObject.Properties.Name -contains 'CurrentMinorVersionNumber' -and $cv.CurrentMinorVersionNumber) {
        $minor = [int]$cv.CurrentMinorVersionNumber
    }

    $version = [version]("{0}.{1}.{2}.{3}" -f $major, $minor, $build, $ubr)

    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { $arch = 'x64' }
        'ARM64' { $arch = 'arm64' }
        'x86'   { $arch = 'x86' }
        default { $arch = 'x64' }
    }

    $edition = "$($cv.EditionID)"
    $isN = $false
    if ($edition -match 'N$') { $isN = $true }

    $name = 'Windows 10'
    if ($build -ge 22000) { $name = 'Windows 11' }

    $displayVersion = ''
    if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $displayVersion = "$($cv.DisplayVersion)" }

    $locale = 'en-US'
    try { $locale = (Get-Culture).Name } catch { }

    return [pscustomobject]@{
        Name           = $name
        DisplayVersion = $displayVersion
        Edition        = $edition
        Version        = $version
        Build          = $build
        Arch           = $arch
        IsN            = $isN
        Locale         = $locale
        IsAdmin        = (Test-IsAdmin)
        PowerShell     = $PSVersionTable.PSVersion.ToString()
    }
}

function Test-HevcHardwareDecode {
    param([string]$Adapter)
    if (-not $Adapter) { return 'Unknown' }
    if ($Adapter -match 'NVIDIA|GeForce|Quadro|RTX') {
        if ($Adapter -match 'RTX|GTX\s*(9[5-9]\d|10\d\d|16\d\d|20\d\d|30\d\d|40\d\d|50\d\d)|Quadro\s*(M|P|RTX)') { return 'Yes' }
        return 'Unknown'
    }
    if ($Adapter -match 'AMD|Radeon|ATI') {
        if ($Adapter -match 'RX\s*(4[6-9]\d|[5-9]\d\d)|Vega|Radeon\(TM\)\s*Graphics|6[0-9]0M|7[0-9]0M') { return 'Yes' }
        return 'Unknown'
    }
    if ($Adapter -match 'Intel') {
        if ($Adapter -match 'Iris|Arc|UHD Graphics\s*[6-9]\d\d|HD Graphics\s*[56]\d\d') { return 'Yes' }
        return 'Unknown'
    }
    return 'Unknown'
}

function Get-GpuProfile {
    $adapters = @()
    try { $adapters = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) }
    catch {
        try { $adapters = @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop) } catch { $adapters = @() }
    }
    $result = @()
    foreach ($a in $adapters) {
        $name = "$($a.Name)"
        if (-not $name) { continue }
        if ($name -match 'Microsoft Basic|Remote Display|Virtual') { continue }
        $result += [pscustomobject]@{
            Name         = $name
            Driver       = "$($a.DriverVersion)"
            HardwareHevc = (Test-HevcHardwareDecode -Adapter $name)
        }
    }
    return $result
}

# ----------------------------------------------------------------------------
# package state
# ----------------------------------------------------------------------------
function Get-InstalledHevc {
    param([switch]$IncludeAllUsers)
    $raw = @()
    $raw += @(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue)
    if ($IncludeAllUsers) {
        $raw += @(Get-AppxPackage -AllUsers -Name $script:PackageName -ErrorAction SilentlyContinue)
    }
    $seen = @{}
    foreach ($p in $raw) {
        if (-not $p) { continue }
        if (-not $seen.ContainsKey($p.PackageFullName)) { $seen[$p.PackageFullName] = $p }
    }
    return @($seen.Values | Sort-Object -Property @{ Expression = { [version]$_.Version } } -Descending)
}

function Test-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
    catch { return $false }
    if ($sig.Status -ne 'Valid') { return $false }
    if (-not $sig.SignerCertificate) { return $false }
    return ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}

# ----------------------------------------------------------------------------
# bundle inspection
# ----------------------------------------------------------------------------
function Get-VersionFromFileName {
    param([string]$Name)
    $m = [regex]::Match("$Name", '(?<v>\d+\.\d+\.\d+\.\d+)')
    if ($m.Success) { return [version]$m.Groups['v'].Value }
    return [version]'0.0.0.0'
}

function Get-BundleInfo {
    <#
        Opens the .appxbundle, extracts the .appx for the requested architecture,
        reads AppxManifest.xml and returns the lowest TargetDeviceFamily
        MinVersion (the OS build the bundle demands) plus the package version.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Architecture
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $work = Join-Path $env:TEMP ('hevc-bundle-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $bundle = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entries = @($bundle.Entries | Where-Object { $_.FullName -like '*.appx' })
            if ($entries.Count -eq 0) { throw 'no .appx payload inside the bundle' }

            $pick = $null
            foreach ($e in $entries) { if ($e.Name -match "_$($Architecture)_") { $pick = $e; break } }
            if (-not $pick) { foreach ($e in $entries) { if ($e.Name -match '_neutral_') { $pick = $e; break } } }
            if (-not $pick) { $pick = $entries[0] }

            $appx = Join-Path $work 'payload.appx'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($pick, $appx, $true)
        }
        finally { $bundle.Dispose() }

        $inner = [IO.Compression.ZipFile]::OpenRead($appx)
        try {
            $manifestEntry = $inner.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
            if (-not $manifestEntry) { throw 'AppxManifest.xml missing' }
            $reader = New-Object IO.StreamReader($manifestEntry.Open())
            try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $inner.Dispose() }

        $minVersion = $null
        foreach ($el in [regex]::Matches($xmlText, '<TargetDeviceFamily\b[^>]*>')) {
            $block = $el.Value
            if ($block -notmatch 'Name="Windows\.(Universal|Desktop|Mobile)"') { continue }
            $mv = [regex]::Match($block, 'MinVersion="(?<v>[^"]+)"')
            if (-not $mv.Success) { continue }
            $parsed = [version]'0.0.0.0'
            if ([version]::TryParse($mv.Groups['v'].Value, [ref]$parsed)) {
                if (-not $minVersion -or $parsed -lt $minVersion) { $minVersion = $parsed }
            }
        }
        if (-not $minVersion) { $minVersion = [version]'0.0.0.0' }

        $pkgVersion = [version]'0.0.0.0'
        $idm = [regex]::Match($xmlText, '<Identity\b[^>]*Version="(?<v>[^"]+)"')
        if ($idm.Success) {
            $parsed = [version]'0.0.0.0'
            if ([version]::TryParse($idm.Groups['v'].Value, [ref]$parsed)) { $pkgVersion = $parsed }
        }

        return [pscustomobject]@{
            MinVersion     = $minVersion
            PackageVersion = $pkgVersion
            Architecture   = $Architecture
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------
# candidate discovery
# ----------------------------------------------------------------------------
function New-Candidate {
    param(
        [string]$Source,
        [string]$Uri,
        [string]$FileName,
        [version]$Version,
        [int]$Rank
    )
    [pscustomobject]@{
        Source   = $Source
        Uri      = $Uri
        FileName = $FileName
        Version  = $Version
        Rank     = $Rank
    }
}

function Get-LocalCandidates {
    $dirs = @($script:ScriptDir, (Join-Path $script:ScriptDir 'packages'))
    $out = @()
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.appxbundle' -File -ErrorAction SilentlyContinue)) {
            $out += New-Candidate -Source 'local' -Uri $f.FullName -FileName $f.Name -Version (Get-VersionFromFileName $f.Name) -Rank 0
        }
    }
    return $out
}

function Get-CacheCandidates {
    if (-not (Test-Path -LiteralPath $script:CacheDir)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $script:CacheDir -Filter '*.appxbundle' -File -ErrorAction SilentlyContinue)) {
        $out += New-Candidate -Source 'cache' -Uri $f.FullName -FileName $f.Name -Version (Get-VersionFromFileName $f.Name) -Rank 1
    }
    return $out
}

function Get-GitHubCandidates {
    $headers = @{ 'User-Agent' = $script:UserAgent; 'Accept' = 'application/vnd.github+json' }
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:RepoSlug)/releases/latest" -Headers $headers -TimeoutSec 60
    }
    catch {
        Write-Log "GitHub release lookup failed: $($_.Exception.Message)" 'WARN'
        return @()
    }
    $out = @()
    foreach ($asset in @($release.assets)) {
        if (-not $asset -or $asset.name -notlike '*.appxbundle') { continue }
        $out += New-Candidate -Source 'github' -Uri $asset.browser_download_url -FileName $asset.name -Version (Get-VersionFromFileName $asset.name) -Rank 2
    }
    return $out
}

function Get-StoreCandidates {
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0'
        'Referer'    = 'https://store.rg-adguard.net/'
        'Origin'     = 'https://store.rg-adguard.net'
    }
    $body = @{ type = 'ProductId'; url = $script:ProductId; ring = 'RP'; lang = 'en-US' }
    try {
        $resp = Invoke-WebRequest -Uri 'https://store.rg-adguard.net/api/GetFiles' -Method Post -Body $body -Headers $headers -TimeoutSec 90 -UseBasicParsing
    }
    catch {
        Write-Log "Store delivery catalog lookup failed: $($_.Exception.Message)" 'WARN'
        return @()
    }
    $out = @()
    foreach ($m in [regex]::Matches($resp.Content, '<a href="(?<u>[^"]+)"[^>]*>(?<n>[^<]*\.appxbundle)</a>')) {
        $name = $m.Groups['n'].Value.Trim()
        $url = ($m.Groups['u'].Value -replace '&amp;', '&')
        $out += New-Candidate -Source 'store' -Uri $url -FileName $name -Version (Get-VersionFromFileName $name) -Rank 3
    }
    return $out
}

function Get-AllCandidates {
    $list = @()
    if ($BundlePath) {
        if (-not (Test-Path -LiteralPath $BundlePath)) { throw "Bundle not found: $BundlePath" }
        $full = (Resolve-Path -LiteralPath $BundlePath).Path
        $leaf = Split-Path -Path $full -Leaf
        $list += New-Candidate -Source 'local' -Uri $full -FileName $leaf -Version (Get-VersionFromFileName $leaf) -Rank 0
        return $list
    }

    $list += Get-LocalCandidates
    $list += Get-CacheCandidates

    if (-not $Offline -and -not $NoNetwork) {
        $list += Get-GitHubCandidates
        $list += Get-StoreCandidates
    }
    return $list
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$Retries = 3
    )
    $ProgressPreference = 'SilentlyContinue'
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
            if ((Get-Item -LiteralPath $OutFile).Length -gt 0) { return $true }
            throw 'downloaded file is empty'
        }
        catch {
            Write-Log "  download attempt $i/$Retries failed: $($_.Exception.Message)" 'WARN'
            if ($i -lt $Retries) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    return $false
}

function Resolve-CompatibleBundles {
    <#
        Returns every candidate the current build can run, best first.
        Bundles whose manifest MinVersion is above the local build are skipped
        with the reason logged, which is the whole point of this script.
    #>
    param(
        [Parameter(Mandatory)]$Candidates,
        [Parameter(Mandatory)]$Sys
    )
    $ordered = @($Candidates | Sort-Object -Property `
            @{ Expression = { $_.Version }; Descending = $true }, `
            @{ Expression = { $_.Rank }; Descending = $false })

    $seenVersions = @{}
    $compatible = @()

    foreach ($c in $ordered) {
        $key = $c.Version.ToString()
        if ($seenVersions.ContainsKey($key)) { continue }
        $seenVersions[$key] = $true

        $file = $null
        if ($c.Source -eq 'local' -or $c.Source -eq 'cache') {
            $file = $c.Uri
        }
        else {
            $file = Join-Path $script:CacheDir $c.FileName
            if (-not (Test-Path -LiteralPath $file)) {
                Write-Log ("Fetching {0} from {1} ..." -f $c.Version, $c.Source) 'STEP'
                if (-not (Save-RemoteFile -Uri $c.Uri -OutFile $file)) {
                    Write-Log "  skipped: download failed" 'WARN'
                    continue
                }
            }
            else {
                Write-Log ("Using cached {0}" -f $c.Version) 'DEBUG'
            }
        }

        try { $info = Get-BundleInfo -Path $file -Architecture $Sys.Arch }
        catch {
            Write-Log ("  {0}: cannot read bundle manifest ({1})" -f $c.Version, $_.Exception.Message) 'WARN'
            continue
        }

        if ($info.MinVersion -gt $Sys.Version) {
            Write-Log ("  {0}: needs build {1}, this PC is {2} - skipped" -f $c.Version, $info.MinVersion, $Sys.Version) 'WARN'
            continue
        }

        if (-not (Test-MicrosoftSignature -Path $file)) {
            Write-Log ("  {0}: Authenticode signature is not a valid Microsoft signature - skipped" -f $c.Version) 'ERROR'
            continue
        }

        Write-Log ("  {0}: compatible (min build {1})" -f $c.Version, $info.MinVersion) 'OK'
        $compatible += [pscustomobject]@{
            Candidate = $c
            File      = $file
            Info      = $info
        }
    }

    return $compatible
}

# ----------------------------------------------------------------------------
# install / remove
# ----------------------------------------------------------------------------
function Install-HevcBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$ForAllUsers,
        [switch]$ForceReinstall
    )
    $apParams = @{ Path = $Path; ErrorAction = 'Stop' }
    if ($ForAllUsers) { $apParams['AllUsers'] = $true }
    if ($ForceReinstall) { $apParams['ForceUpdateFromAnyVersion'] = $true }

    try { Add-AppxPackage @apParams }
    catch {
        if ($ForceReinstall) {
            # older Windows builds do not know -ForceUpdateFromAnyVersion
            $apParams.Remove('ForceUpdateFromAnyVersion')
            Add-AppxPackage @apParams
        }
        else { throw }
    }
}

function Remove-HevcPackage {
    param([switch]$ForAllUsers)
    $packages = @(Get-InstalledHevc -IncludeAllUsers:$ForAllUsers)
    if ($packages.Count -eq 0) {
        Write-Log 'HEVC Video Extensions is not installed.' 'INFO'
        return 10
    }
    foreach ($p in $packages) {
        Write-Log ("Removing {0} ..." -f $p.PackageFullName) 'STEP'
        try {
            $rmParams = @{ Package = $p.PackageFullName; ErrorAction = 'Stop' }
            if ($ForAllUsers -and (Test-IsAdmin)) { $rmParams['AllUsers'] = $true }
            Remove-AppxPackage @rmParams
            Write-Log 'Removed.' 'OK'
        }
        catch {
            Write-Log ("Removal failed: {0}" -f $_.Exception.Message) 'ERROR'
            return 30
        }
    }
    return 0
}

# ----------------------------------------------------------------------------
# reporting
# ----------------------------------------------------------------------------
function Write-ProfileReport {
    param($Sys, $Gpus)
    Write-Log '--- this machine ---' 'STEP'
    Write-Log ("OS          : {0} {1} (build {2})" -f $Sys.Name, $Sys.DisplayVersion, $Sys.Version)
    $editionNote = ''
    if ($Sys.IsN) { $editionNote = '  <-- N edition, Media Feature Pack required' }
    Write-Log ("Edition     : {0}{1}" -f $Sys.Edition, $editionNote)
    Write-Log ("Architecture: {0}" -f $Sys.Arch)
    Write-Log ("Locale      : {0}" -f $Sys.Locale)
    Write-Log ("PowerShell  : {0}  (elevated: {1})" -f $Sys.PowerShell, $Sys.IsAdmin)
    if (@($Gpus).Count -eq 0) {
        Write-Log 'GPU         : not detected' 'WARN'
    }
    foreach ($g in $Gpus) {
        Write-Log ("GPU         : {0} (driver {1})" -f $g.Name, $g.Driver)
        if ($g.HardwareHevc -eq 'Yes') {
            Write-Log '              hardware HEVC decode: likely available (estimate)' 'DEBUG'
        }
        else {
            Write-Log '              hardware HEVC decode: unknown - software decode will be used' 'DEBUG'
        }
    }
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
Write-Banner
Write-Log "log file: $($script:LogFile)" 'DEBUG'

$sys = Get-SystemProfile
$gpus = @(Get-GpuProfile)
Write-ProfileReport -Sys $sys -Gpus $gpus

if ($sys.Version -lt [version]'10.0.16299.0') {
    Write-Log 'Windows 10 1709 (build 16299) or newer is required.' 'ERROR'
    exit 40
}

if ($sys.IsN) {
    Write-Log 'N editions ship without media components. Install "Media Feature Pack" first, then re-run.' 'WARN'
}

$installed = @(Get-InstalledHevc -IncludeAllUsers:$AllUsers)
if ($installed.Count -gt 0) {
    Write-Log '--- package state ---' 'STEP'
    foreach ($p in $installed) {
        Write-Log ("installed   : {0} -> {1}" -f $p.PackageFullName, $p.Status) 'OK'
    }
}
else {
    Write-Log 'HEVC Video Extensions is not installed yet.' 'INFO'
}

if ($Diagnose) {
    Write-Log '--- candidate sources ---' 'STEP'
    try { $all = @(Get-AllCandidates) } catch { $all = @(); Write-Log $_.Exception.Message 'WARN' }
    if ($all.Count -eq 0) {
        Write-Log 'No bundle candidates found (offline, blocked, or no release assets).' 'WARN'
    }
    foreach ($c in ($all | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true })) {
        Write-Log ("  {0,-10} {1,-10} {2}" -f $c.Source, $c.Version, $c.FileName) 'INFO'
    }
    $isInstalled = 'no'
    if ($installed.Count -gt 0) { $isInstalled = 'yes' }
    Write-Log '--- summary ---' 'STEP'
    Write-Log ("installed={0}  arch={1}  build={2}  hardwareDecode={3}" -f $isInstalled, $sys.Arch, $sys.Version, $(if (@($gpus | Where-Object { $_.HardwareHevc -eq 'Yes' }).Count -gt 0) { 'likely' } else { 'unknown' }))
    Write-Log 'Diagnose mode: nothing was changed.' 'OK'
    exit 0
}

if ($Uninstall) {
    Write-Log '--- uninstall ---' 'STEP'
    if ($AllUsers -and -not $sys.IsAdmin) {
        Write-Log '-AllUsers needs an elevated shell.' 'ERROR'
        exit 30
    }
    exit (Remove-HevcPackage -ForAllUsers:$AllUsers)
}

if ($installed.Count -gt 0 -and -not $Force) {
    Write-Log 'Nothing to do. Use -Force to reinstall or repair, -Uninstall to remove.' 'OK'
    exit 10
}

if ($AllUsers -and -not $sys.IsAdmin) {
    Write-Log '-AllUsers needs an elevated shell. Run without -AllUsers for a per-user install.' 'ERROR'
    exit 30
}

Write-Log '--- selecting a bundle for this PC ---' 'STEP'
try { $candidates = @(Get-AllCandidates) }
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 21
}

if ($candidates.Count -eq 0) {
    Write-Log 'No candidate bundles available.' 'ERROR'
    Write-Log 'Try without -Offline, or download a bundle manually and pass -BundlePath.' 'INFO'
    Write-Log ("Store page: {0}" -f $script:StoreProduct) 'INFO'
    exit 20
}

$compatible = @(Resolve-CompatibleBundles -Candidates $candidates -Sys $sys)

if ($compatible.Count -eq 0) {
    Write-Log 'No bundle in the catalog supports this build.' 'ERROR'
    Write-Log 'Run with -Diagnose to see which builds each bundle demands.' 'INFO'
    exit 20
}

Write-Log '--- installing ---' 'STEP'
$exitCode = 30
foreach ($entry in $compatible) {
    $label = $entry.Candidate.Source
    Write-Log ("Installing {0} from {1} ..." -f $entry.Candidate.Version, $label) 'STEP'
    try {
        Install-HevcBundle -Path $entry.File -ForAllUsers:$AllUsers -ForceReinstall:$Force
        $exitCode = 0
        break
    }
    catch {
        Write-Log ("  install failed: {0}" -f $_.Exception.Message) 'ERROR'
        $exitCode = 30
    }
}

if ($exitCode -ne 0) {
    Write-Log 'Installation failed. Common causes:' 'ERROR'
    Write-Log '  0x80073CFD  bundle build too new for this OS (run -Diagnose)' 'INFO'
    Write-Log '  0x80073D02  app is in use, close Photos / Films & TV and retry' 'INFO'
    Write-Log '  0x80073CF9  AppX Deployment Service (AppXSvc) is disabled' 'INFO'
    Write-Log '  0x800B0109  signature chain not trusted (corporate proxy / TLS inspection)' 'INFO'
    exit $exitCode
}

Write-Log '--- verification ---' 'STEP'
$after = @(Get-InstalledHevc -IncludeAllUsers:$AllUsers)
if ($after.Count -eq 0) {
    Write-Log 'Package did not register after install.' 'ERROR'
    exit 30
}
foreach ($p in $after) {
    $state = 'OK'
    if ($p.Status -ne 'Ok') { $state = 'WARN' }
    Write-Log ("installed   : {0} -> {1}" -f $p.PackageFullName, $p.Status) $state
}

$hwNote = 'software decode'
if (@($gpus | Where-Object { $_.HardwareHevc -eq 'Yes' }).Count -gt 0) { $hwNote = 'hardware decode likely' }
Write-Log ("done        : HEVC playback ready ({0})" -f $hwNote) 'OK'
Write-Log 'Try a .hevc/.265/.mp4 file in Photos or Films & TV. Restart the app if it was open.' 'INFO'
Write-Host ''
exit 0
