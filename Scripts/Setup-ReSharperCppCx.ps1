<#
.SYNOPSIS
Creates pristine decompiled workspaces for installed or remotely selected Rider builds.
.DESCRIPTION
Builds the pinned, patched ILSpy v11.0 command when needed. Installed mode
accepts Rider roots; download mode resolves exact release, RC, or EAP versions
from JetBrains metadata and reads only required files through HTTP byte ranges.
Both modes cache pristine targets, XML documentation, and direct assembly-reference
DLLs under the version's
Work\...\References directory. Generated projects target .NET Framework 4.8,
receive relative HintPath entries into that cache, mark assembly references
non-private, and public-sign with the original JetBrains strong-name public key.
Feature Services references the generated ReSharper.Cpp project. No patches are
applied and no project is built.

The default layout is:
  Work\<Version>_<Build>\ReSharperCppCx_<Version>.slnx
  Work\<Version>_<Build>\References\
  Work\<Version>_<Build>\<AssemblyName>\
    <AssemblyName>.dll
    GeneratePatchesForThisDll.bat
    Source\<AssemblyName>.csproj

Every selected original must retain a valid JetBrains Authenticode signature.
Installed mode checks the canonical DLL and then <name>-.dll, <name>.bak.dll, and
<name>.dll.cppcx.bak. XML documentation is placed beside the canonical temporary
DLL so ILSpy consumes it normally.
.PARAMETER RiderDirectory
One or more installed Rider roots containing product-info.json and
lib\ReSharperHost. Mutually exclusive with DownloadVersion.
.PARAMETER DownloadVersion
One or more exact Rider display versions or build numbers from JetBrains
metadata, such as 2026.2.2, 2026.3-EAP3, or 263.5153.35.
.PARAMETER WorkRoot
Workspace root. Defaults to the repository's Work directory.
.EXAMPLE
.\Setup-ReSharperCppCx.ps1 -RiderDirectory 'C:\Program Files\JetBrains\JetBrains Rider'
.EXAMPLE
.\Setup-ReSharperCppCx.ps1 -RiderDirectory 'C:\Rider Stable','C:\Rider EAP'
.EXAMPLE
.\Setup-ReSharperCppCx.ps1 -DownloadVersion 2026.2.2,2026.3-EAP3
#>
[CmdletBinding(DefaultParameterSetName = 'Installed')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Installed')]
    [ValidateNotNullOrEmpty()]
    [string[]]$RiderDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'Download')]
    [Alias('Version')]
    [ValidateNotNullOrEmpty()]
    [string[]]$DownloadVersion,
    [string]$WorkRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression

$decompilerVersion = '11.0.0.9375'
$languageVersion = 'CSharp13_0'
$assemblySpecs = @(
    [pscustomobject]@{ FileName = 'JetBrains.ReSharper.Cpp.dll' },
    [pscustomobject]@{ FileName = 'JetBrains.ReSharper.Feature.Services.Cpp.dll' }
)
$remoteEntryNames = @(
    'lib/ReSharperHost/JetBrains.ReSharper.Cpp.dll',
    'lib/ReSharperHost/JetBrains.ReSharper.Cpp.xml',
    'lib/ReSharperHost/JetBrains.ReSharper.Feature.Services.Cpp.dll',
    'lib/ReSharperHost/JetBrains.ReSharper.Feature.Services.Cpp.xml'
)


function Find-PristineAssembly {
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][string]$ExpectedMarketingVersion
    )
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Spec.FileName)
    $installed = Join-Path $ReferenceDirectory $Spec.FileName
    $candidates = @(
        [pscustomobject]@{ Path = $installed; Backup = $false },
        [pscustomobject]@{ Path = (Join-Path $ReferenceDirectory ($baseName + '-.dll')); Backup = $true },
        [pscustomobject]@{ Path = (Join-Path $ReferenceDirectory ($baseName + '.bak.dll')); Backup = $true },
        [pscustomobject]@{ Path = ($installed + '.cppcx.bak'); Backup = $true }
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        $identity = Get-AssemblyIdentityOrNull -Path $candidate.Path
        if ($null -eq $identity -or $identity.Name -cne $baseName -or $identity.GetPublicKeyToken().Length -eq 0) {
            throw "Assembly identity mismatch: $($candidate.Path)"
        }
        $null = Assert-RiderAssemblyMarketingVersion -Path $candidate.Path -ExpectedVersion $ExpectedMarketingVersion
        if ($candidate.Backup) { Assert-JetBrainsSignature -Path $candidate.Path }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        $identity = Get-AssemblyIdentityOrNull -Path $candidate.Path
        if ($null -ne $identity -and (Test-JetBrainsSignature -Path $candidate.Path)) {
            if ($candidate.Path -cne $installed) { Write-Host "Using pristine backup: $($candidate.Path)" }
            return [pscustomobject]@{ Path = $candidate.Path; Identity = $identity; MarketingVersion = $ExpectedMarketingVersion }
        }
    }
    throw "No JetBrains-signed pristine $($Spec.FileName) was found for Rider $ExpectedMarketingVersion. Checked: $(@($candidates.Path) -join ', ')"
}


function Ensure-IlSpy {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $sourceDirectory = Join-Path $ToolRoot 'ILSpy'
    $repository = 'https://github.com/icsharpcode/ILSpy.git'
    $tag = 'v11.0'
    $commit = 'cdeae656fee6e184ff76cdc549edc7f9031dba09'
    $patchPath = Join-Path $PSScriptRoot 'ILSpy.Compatibility.patch'
    $patchSha256 = Get-Sha256 -Path $patchPath
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        $null = Invoke-PatchNative -FilePath 'git' -Arguments @(
            'clone', '--branch', $tag, '--single-branch',
            $repository, $sourceDirectory
        ) -WorkingDirectory $ToolRoot
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory '.git') -PathType Container)) {
        throw "ILSpy source is not a Git repository: $sourceDirectory"
    }
    $actualCommit = (Invoke-PatchNative -FilePath 'git' -Arguments @(
        '-C', $sourceDirectory, 'rev-parse', 'HEAD'
    ) -WorkingDirectory $ToolRoot -Quiet).StdOut.Trim()
    if ($actualCommit -cne $commit) { throw "Unexpected ILSpy commit: $actualCommit" }

    $transformPath = Join-Path $sourceDirectory 'ICSharpCode.Decompiler\CSharp\Transforms\TransformFieldAndConstructorInitializers.cs'
    $transformText = [IO.File]::ReadAllText($transformPath)
    if ($transformText.Contains('ReferencesInstanceMember(entry.Initializer)')) {
        $null = Invoke-PatchNative -FilePath 'git' -Arguments @(
            '-C', $sourceDirectory, 'apply', '--reverse', '--check', '--', $patchPath
        ) -WorkingDirectory $ToolRoot -Quiet
    }
    else {
        $null = Invoke-PatchNative -FilePath 'git' -Arguments @(
            '-C', $sourceDirectory, 'apply', '--check', '--', $patchPath
        ) -WorkingDirectory $ToolRoot -Quiet
        $null = Invoke-PatchNative -FilePath 'git' -Arguments @(
            '-C', $sourceDirectory, 'apply', '--', $patchPath
        ) -WorkingDirectory $ToolRoot -Quiet
    }

    $project = Join-Path $sourceDirectory 'ICSharpCode.ILSpyCmd\ICSharpCode.ILSpyCmd.csproj'
    $executable = Join-Path $sourceDirectory 'ICSharpCode.ILSpyCmd\bin\Release\net10.0\ilspycmd.exe'
    $stampPath = Join-Path $sourceDirectory 'custom-build.json'
    $requiresBuild = $true
    if ((Test-Path -LiteralPath $executable -PathType Leaf) -and
        (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
        $stamp = [IO.File]::ReadAllText($stampPath) | ConvertFrom-Json
        $requiresBuild = $stamp.commit -cne $commit -or $stamp.patchSha256 -cne $patchSha256
    }
    if ($requiresBuild) {
        $sdk = Invoke-PatchNative -FilePath 'dotnet' -Arguments @('--version') -WorkingDirectory $ToolRoot -Quiet
        if ($sdk.StdOut.Trim() -notmatch '^(\d+)\.' -or [int]$Matches[1] -lt 10) {
            throw '.NET SDK 10 or newer is required to build the customized ILSpy command.'
        }
        $null = Invoke-PatchNative -FilePath 'dotnet' -Arguments @(
            'build', $project, '--configuration', 'Release', '--verbosity', 'minimal'
        ) -WorkingDirectory $ToolRoot
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Customized ilspycmd build output is missing: $executable"
        }
        Write-PatchJson -Path $stampPath -Value ([ordered]@{
            schemaVersion = 1
            commit = $commit
            patchSha256 = $patchSha256
        })
    }
    $versionOutput = Invoke-PatchNative -FilePath $executable -Arguments @('--disable-updatecheck', '--version') -WorkingDirectory $ToolRoot -Quiet
    if ($versionOutput.StdOut -notmatch ('(?m)^ilspycmd: ' + [regex]::Escape($decompilerVersion) + '\s*$')) {
        throw "Unexpected ilspycmd version at $executable"
    }
    return $executable
}



function Get-RemoteArchiveInfo {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][long]$ExpectedLength
    )
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, $Uri)
    try {
        $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "Archive HEAD failed ($([int]$response.StatusCode)): $Uri" }
            $length = [long]$response.Content.Headers.ContentLength
            if ($length -ne $ExpectedLength) { throw "Archive length differs from JetBrains metadata: $length != $ExpectedLength" }
            if (-not @($response.Headers.AcceptRanges).Contains('bytes')) { throw "Archive server does not advertise byte ranges: $Uri" }
            if ($null -eq $response.Headers.ETag -or [string]::IsNullOrWhiteSpace($response.Headers.ETag.Tag)) {
                throw "Archive server did not provide an ETag: $Uri"
            }
            return [pscustomobject]@{
                Uri = $response.RequestMessage.RequestUri.AbsoluteUri
                Length = $length
                ETag = $response.Headers.ETag.ToString()
            }
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Get-RemoteRange {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][long]$Start,
        [Parameter(Mandatory = $true)][long]$End
    )
    if ($Start -lt 0 -or $End -lt $Start -or $End -ge $Archive.Length) { throw "Invalid archive range: $Start-$End" }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Archive.Uri)
    $null = $request.Headers.TryAddWithoutValidation('Range', "bytes=$Start-$End")
    $null = $request.Headers.TryAddWithoutValidation('If-Match', $Archive.ETag)
    try {
        $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseContentRead).GetAwaiter().GetResult()
        try {
            if ($response.StatusCode -ne [Net.HttpStatusCode]::PartialContent) {
                throw "Archive range request returned $([int]$response.StatusCode), not 206; refusing a full download."
            }
            $range = $response.Content.Headers.ContentRange
            if ($null -eq $range -or $range.From -ne $Start -or $range.To -ne $End -or $range.Length -ne $Archive.Length) {
                throw "Archive returned an unexpected Content-Range for $Start-$End."
            }
            if ($null -eq $response.Headers.ETag -or $response.Headers.ETag.ToString() -cne $Archive.ETag) {
                throw 'Archive ETag changed during range extraction.'
            }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -ne ($End - $Start + 1)) { throw "Archive range length mismatch for $Start-$End." }
            $script:RangeBytesDownloaded += $bytes.Length
            return ,$bytes
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Find-ZipSignatureBackwards {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][uint32]$Signature)
    for ($index = $Bytes.Length - 4; $index -ge 0; --$index) {
        if ([BitConverter]::ToUInt32($Bytes, $index) -eq $Signature) { return $index }
    }
    return -1
}

function Get-RemoteZipEntries {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Archive
    )
    $tailLength = [Math]::Min([long]131072, $Archive.Length)
    $tailStart = $Archive.Length - $tailLength
    $tail = Get-RemoteRange -Client $Client -Archive $Archive -Start $tailStart -End ($Archive.Length - 1)
    $eocdOffset = Find-ZipSignatureBackwards -Bytes $tail -Signature 0x06054b50
    if ($eocdOffset -lt 0 -or $eocdOffset + 22 -gt $tail.Length) { throw 'ZIP end-of-central-directory record was not found.' }
    $entryCount = [BitConverter]::ToUInt16($tail, $eocdOffset + 10)
    $centralSize = [BitConverter]::ToUInt32($tail, $eocdOffset + 12)
    $centralOffset = [BitConverter]::ToUInt32($tail, $eocdOffset + 16)
    if ($entryCount -eq [uint16]::MaxValue -or $centralSize -eq [uint32]::MaxValue -or $centralOffset -eq [uint32]::MaxValue) {
        throw 'ZIP64 archives are not yet supported by the selective downloader.'
    }
    if ([long]$centralOffset + [long]$centralSize -gt $Archive.Length) { throw 'ZIP central directory is outside the archive.' }
    $central = Get-RemoteRange -Client $Client -Archive $Archive -Start $centralOffset -End ([long]$centralOffset + $centralSize - 1)
    $entries = @()
    $position = 0
    while ($position -lt $central.Length) {
        if ($position + 46 -gt $central.Length -or [BitConverter]::ToUInt32($central, $position) -ne 0x02014b50) {
            throw "Invalid ZIP central-directory entry at offset $position."
        }
        $flags = [BitConverter]::ToUInt16($central, $position + 8)
        $method = [BitConverter]::ToUInt16($central, $position + 10)
        $crc32 = [BitConverter]::ToUInt32($central, $position + 16)
        $compressedSize = [BitConverter]::ToUInt32($central, $position + 20)
        $uncompressedSize = [BitConverter]::ToUInt32($central, $position + 24)
        $nameLength = [BitConverter]::ToUInt16($central, $position + 28)
        $extraLength = [BitConverter]::ToUInt16($central, $position + 30)
        $commentLength = [BitConverter]::ToUInt16($central, $position + 32)
        $localOffset = [BitConverter]::ToUInt32($central, $position + 42)
        $entryLength = 46 + $nameLength + $extraLength + $commentLength
        if ($position + $entryLength -gt $central.Length) { throw 'Truncated ZIP central-directory entry.' }
        $encoding = if (($flags -band 0x0800) -ne 0) { [Text.Encoding]::UTF8 } else { [Text.Encoding]::ASCII }
        $name = $encoding.GetString($central, $position + 46, $nameLength)
        $entries += [pscustomobject]@{
            Name = $name
            Flags = $flags
            Method = $method
            Crc32 = $crc32
            CompressedSize = $compressedSize
            UncompressedSize = $uncompressedSize
            LocalOffset = $localOffset
        }
        $position += $entryLength
    }
    if ($entries.Count -ne $entryCount) { throw "ZIP entry count mismatch: $($entries.Count) != $entryCount" }
    return @($entries)
}

function Get-Crc32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    [uint32]$crc = [uint32]::MaxValue
    foreach ($byte in $Bytes) {
        $tableIndex = [int](($crc -bxor [uint32]$byte) -band 0xff)
        $crc = [uint32](($crc -shr 8) -bxor $script:Crc32Table[$tableIndex])
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Expand-RemoteZipEntry {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (($Entry.Flags -band 1) -ne 0) { throw "Encrypted ZIP entry is unsupported: $($Entry.Name)" }
    if ($Entry.CompressedSize -gt 64MB -or $Entry.UncompressedSize -gt 64MB) { throw "Unexpectedly large target entry: $($Entry.Name)" }
    $header = Get-RemoteRange -Client $Client -Archive $Archive -Start $Entry.LocalOffset -End ([long]$Entry.LocalOffset + 29)
    if ([BitConverter]::ToUInt32($header, 0) -ne 0x04034b50) { throw "Invalid ZIP local header: $($Entry.Name)" }
    $localMethod = [BitConverter]::ToUInt16($header, 8)
    $nameLength = [BitConverter]::ToUInt16($header, 26)
    $extraLength = [BitConverter]::ToUInt16($header, 28)
    if ($localMethod -ne $Entry.Method) { throw "ZIP compression method mismatch: $($Entry.Name)" }
    $dataStart = [long]$Entry.LocalOffset + 30 + $nameLength + $extraLength
    $compressed = Get-RemoteRange -Client $Client -Archive $Archive -Start $dataStart -End ($dataStart + $Entry.CompressedSize - 1)
    if ($Entry.Method -eq 0) {
        [byte[]]$expanded = $compressed
    }
    elseif ($Entry.Method -eq 8) {
        $input = [IO.MemoryStream]::new($compressed, $false)
        $output = [IO.MemoryStream]::new()
        try {
            $deflate = [IO.Compression.DeflateStream]::new($input, [IO.Compression.CompressionMode]::Decompress, $true)
            try { $deflate.CopyTo($output) } finally { $deflate.Dispose() }
            [byte[]]$expanded = $output.ToArray()
        }
        finally {
            $output.Dispose()
            $input.Dispose()
        }
    }
    else { throw "Unsupported ZIP compression method $($Entry.Method): $($Entry.Name)" }
    if ($expanded.Length -ne $Entry.UncompressedSize) { throw "Expanded size mismatch: $($Entry.Name)" }
    if ((Get-Crc32 -Bytes $expanded) -ne $Entry.Crc32) { throw "CRC32 mismatch: $($Entry.Name)" }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    [IO.File]::WriteAllBytes($Destination, $expanded)
}

function Assert-CachedReferences {
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedMarketingVersion
    )
    foreach ($spec in $assemblySpecs) {
        $dll = Join-Path $ReferenceDirectory $spec.FileName
        $xml = Join-Path $ReferenceDirectory ([IO.Path]::GetFileNameWithoutExtension($spec.FileName) + '.xml')
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf) -or -not (Test-Path -LiteralPath $xml -PathType Leaf)) {
            throw "Rider reference cache is incomplete: $ReferenceDirectory"
        }
        Assert-JetBrainsSignature -Path $dll
        $null = Assert-RiderAssemblyMarketingVersion -Path $dll -ExpectedVersion $ExpectedMarketingVersion
    }
}

function Get-ProjectReferenceNames {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)
    $project = [Xml.XmlDocument]::new()
    $project.XmlResolver = $null
    $project.Load($ProjectPath)
    $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in @($project.SelectNodes("/*[local-name()='Project']/*[local-name()='ItemGroup']/*[local-name()='Reference']"))) {
        $name = $reference.GetAttribute('Include').Split(',')[0].Trim()
        if ($name -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw "Invalid project reference name: $name" }
        $null = $names.Add($name)
    }
    return $names
}

function Write-ReferenceInventory {
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Build
    )
    $inventory = @(
        foreach ($file in @(Get-ChildItem -LiteralPath $ReferenceDirectory -Filter '*.dll' -File | Sort-Object Name)) {
            [ordered]@{ file = $file.Name; sha256 = Get-Sha256 -Path $file.FullName; size = $file.Length }
        }
    )
    Write-PatchJson -Path (Join-Path ([IO.Path]::GetDirectoryName($ReferenceDirectory)) 'references.json') -Value ([ordered]@{
        schemaVersion = 1
        version = $Version
        build = $Build
        files = $inventory
    })
}

function Ensure-RemoteProjectReferences {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )
    $referenceNames = Get-ProjectReferenceNames -ProjectPath $ProjectPath

    $downloadProperty = $Release.Downloads.PSObject.Properties['windowsZip']
    if ($null -eq $downloadProperty -or $null -eq $downloadProperty.Value) {
        throw "windowsZip is unavailable for Rider $($Release.Version)."
    }
    $download = $downloadProperty.Value
    $before = $script:RangeBytesDownloaded
    $archive = Get-RemoteArchiveInfo -Client $Client -Uri ([string]$download.link) -ExpectedLength ([long]$download.size)
    $entries = Get-RemoteZipEntries -Client $Client -Archive $archive
    $downloadedCount = 0
    foreach ($name in $referenceNames) {
        $destination = Join-Path $ReferenceDirectory ($name + '.dll')
        if (Test-Path -LiteralPath $destination -PathType Leaf) { continue }
        $entryName = 'lib/ReSharperHost/' + $name + '.dll'
        $matches = @($entries | Where-Object { $_.Name -ceq $entryName })
        if ($matches.Count -eq 0) { continue } # Framework reference, supplied by the target framework.
        if ($matches.Count -ne 1) { throw "Expected one ZIP entry named $entryName; found $($matches.Count)." }
        $temporary = Join-Path $ReferenceDirectory ($name + '.' + [Guid]::NewGuid().ToString('N') + '.stage.dll')
        try {
            Expand-RemoteZipEntry -Client $Client -Archive $archive -Entry $matches[0] -Destination $temporary
            $identity = Get-AssemblyIdentityOrNull -Path $temporary
            if ($null -eq $identity -or $identity.Name -cne $name) { throw "Downloaded reference identity mismatch: $entryName" }
            [IO.File]::Move($temporary, $destination)
            ++$downloadedCount
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
        }
    }

    Write-ReferenceInventory -ReferenceDirectory $ReferenceDirectory -Version $Release.Version -Build $Release.Build
    if ($downloadedCount -gt 0) {
        Write-Host "Downloaded $downloadedCount direct project reference DLL(s) using $($script:RangeBytesDownloaded - $before) additional archive bytes."
    }
}

function Get-InstalledReferences {
    param(
        [Parameter(Mandatory = $true)][string]$SourceReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Build
    )
    $workspaceId = Get-WorkspaceId -Version $Version -Build $Build
    $cacheParent = Join-Path $WorkRoot $workspaceId
    $referenceDirectory = Join-Path $cacheParent 'References'
    if (Test-Path -LiteralPath $referenceDirectory) {
        Assert-CachedReferences -ReferenceDirectory $referenceDirectory -ExpectedMarketingVersion $Version
        Write-Host "Using cached Rider payload: $cacheParent"
        return $referenceDirectory
    }

    $originals = @(
        foreach ($spec in $assemblySpecs) {
            Find-PristineAssembly -ReferenceDirectory $SourceReferenceDirectory -Spec $spec `
                -ExpectedMarketingVersion $Version
        }
    )
    $null = [IO.Directory]::CreateDirectory($cacheParent)
    $stage = Join-Path $cacheParent ('.references-' + [Guid]::NewGuid().ToString('N'))
    $ownsStage = $false
    try {
        $null = [IO.Directory]::CreateDirectory($stage)
        $ownsStage = $true
        for ($index = 0; $index -lt $assemblySpecs.Count; ++$index) {
            $spec = $assemblySpecs[$index]
            $original = $originals[$index]
            [IO.File]::Copy($original.Path, (Join-Path $stage $spec.FileName), $false)
            $baseName = [IO.Path]::GetFileNameWithoutExtension($spec.FileName)
            $xml = Join-Path $SourceReferenceDirectory ($baseName + '.xml')
            if (-not (Test-Path -LiteralPath $xml -PathType Leaf)) { throw "XML documentation is missing: $xml" }
            [IO.File]::Copy($xml, (Join-Path $stage ($baseName + '.xml')), $false)
        }
        Assert-CachedReferences -ReferenceDirectory $stage -ExpectedMarketingVersion $Version
        Move-DirectoryTree -Source $stage -Destination $referenceDirectory
        $ownsStage = $false
        return $referenceDirectory
    }
    finally {
        if ($ownsStage -and (Test-Path -LiteralPath $stage)) { Remove-DirectoryTree -Path $stage }
    }
}

function Ensure-InstalledProjectReferences {
    param(
        [Parameter(Mandatory = $true)][string]$SourceReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Build
    )
    $copiedCount = 0
    foreach ($name in (Get-ProjectReferenceNames -ProjectPath $ProjectPath)) {
        $destination = Join-Path $ReferenceDirectory ($name + '.dll')
        if (Test-Path -LiteralPath $destination -PathType Leaf) { continue }
        $source = Join-Path $SourceReferenceDirectory ($name + '.dll')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue } # Framework reference.
        $identity = Get-AssemblyIdentityOrNull -Path $source
        if ($null -eq $identity -or $identity.Name -cne $name) { throw "Installed reference identity mismatch: $source" }
        [IO.File]::Copy($source, $destination, $false)
        ++$copiedCount
    }
    Write-ReferenceInventory -ReferenceDirectory $ReferenceDirectory -Version $Version -Build $Build
    if ($copiedCount -gt 0) { Write-Host "Copied $copiedCount direct project reference DLL(s) from the installed Rider." }
}


function Get-DownloadedReferences {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )
    $downloadProperty = $Release.Downloads.PSObject.Properties['windowsZip']
    if ($null -eq $downloadProperty -or $null -eq $downloadProperty.Value) {
        throw "windowsZip is unavailable for Rider $($Release.Version)."
    }
    $download = $downloadProperty.Value
    $workspaceId = Get-WorkspaceId -Version $Release.Version -Build $Release.Build
    $cacheParent = Join-Path $WorkRoot $workspaceId
    $referenceDirectory = Join-Path $cacheParent 'References'
    if (Test-Path -LiteralPath $cacheParent) {
        Assert-CachedReferences -ReferenceDirectory $referenceDirectory -ExpectedMarketingVersion $Release.Version
        Write-Host "Using cached Rider payload: $cacheParent"
        return $referenceDirectory
    }

    $parent = $WorkRoot
    $null = [IO.Directory]::CreateDirectory($parent)
    $stage = Join-Path $parent ('.download-' + [Guid]::NewGuid().ToString('N'))
    $ownsStage = $false
    try {
        $null = [IO.Directory]::CreateDirectory($stage)
        $ownsStage = $true
        $script:RangeBytesDownloaded = 0L
        $archive = Get-RemoteArchiveInfo -Client $Client -Uri ([string]$download.link) -ExpectedLength ([long]$download.size)
        $entries = Get-RemoteZipEntries -Client $Client -Archive $archive
        $files = @()
        foreach ($name in $remoteEntryNames) {
            $matches = @($entries | Where-Object { $_.Name -ceq $name })
            if ($matches.Count -ne 1) { throw "Expected one ZIP entry named $name; found $($matches.Count)." }
            $destination = Join-Path $stage ($name.Replace('/', [IO.Path]::DirectorySeparatorChar))
            Expand-RemoteZipEntry -Client $Client -Archive $archive -Entry $matches[0] -Destination $destination
            $files += [ordered]@{
                file = $name
                sha256 = Get-Sha256 -Path $destination
                size = (Get-Item -LiteralPath $destination).Length
            }
        }
        $stageReferences = Join-Path $stage 'References'
        $null = [IO.Directory]::CreateDirectory($stageReferences)
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $stage 'lib\ReSharperHost') -File)) {
            [IO.File]::Move($file.FullName, (Join-Path $stageReferences $file.Name))
        }
        Remove-DirectoryTree -Path (Join-Path $stage 'lib')
        Assert-CachedReferences -ReferenceDirectory $stageReferences -ExpectedMarketingVersion $Release.Version
        Write-PatchJson -Path (Join-Path $stage 'download.json') -Value ([ordered]@{
            schemaVersion = 1
            productCode = 'RD'
            type = $Release.Type
            version = $Release.Version
            build = $Release.Build
            architecture = 'managed-anycpu'
            archive = [ordered]@{
                url = [string]$download.link
                resolvedUrl = $archive.Uri
                size = $archive.Length
                etag = $archive.ETag
                rangeBytesDownloaded = $script:RangeBytesDownloaded
            }
            files = $files
        })
        Move-DirectoryTree -Source $stage -Destination $cacheParent
        $ownsStage = $false
        Write-Host "Downloaded $($script:RangeBytesDownloaded) of $($archive.Length) archive bytes for Rider $($Release.Version) ($($Release.Build))."
        return $referenceDirectory
    }
    finally {
        if ($ownsStage -and (Test-Path -LiteralPath $stage)) { Remove-DirectoryTree -Path $stage }
    }
}

function Get-RelativeFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    $basePath = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath($TargetPath)
    $baseUri = [Uri]::new($basePath)
    $targetUri = [Uri]::new($target)
    if ($baseUri.Scheme -cne $targetUri.Scheme) { return $target }
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')
}

function Set-ProjectBuildConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ReferenceDirectory,
        [Parameter(Mandatory = $true)][byte[]]$PublicKey,
        [string]$CppProjectReference
    )
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.Load($Path)
    $targetFrameworks = @($document.SelectNodes("/*[local-name()='Project']/*[local-name()='PropertyGroup']/*[local-name()='TargetFramework']"))
    if ($targetFrameworks.Count -ne 1 -or $targetFrameworks[0].ParentNode.HasAttribute('Condition')) {
        throw "Project must contain one unconditional TargetFramework: $Path"
    }
    $targetFrameworks[0].InnerText = 'net48'
    if ($PublicKey.Length -eq 0) { throw "Assembly public key is empty: $Path" }
    $propertyGroup = $targetFrameworks[0].ParentNode
    $signingProperties = [ordered]@{
        SignAssembly = 'true'
        PublicSign = 'true'
        AssemblyOriginatorKeyFile = 'JetBrains.ReSharper.PublicKey.snk'
    }
    foreach ($entry in $signingProperties.GetEnumerator()) {
        $propertyNodes = @($document.SelectNodes(
            "/*[local-name()='Project']/*[local-name()='PropertyGroup']/*[local-name()='$($entry.Key)']"))
        if ($propertyNodes.Count -gt 1) { throw "Project contains multiple $($entry.Key) values: $Path" }
        if ($propertyNodes.Count -eq 0) {
            $propertyNode = $document.CreateElement($entry.Key)
            $null = $propertyGroup.AppendChild($propertyNode)
        }
        else {
            $propertyNode = $propertyNodes[0]
            if ($propertyNode.ParentNode.HasAttribute('Condition') -or $propertyNode.HasAttribute('Condition')) {
                throw "Project contains a conditional $($entry.Key) value: $Path"
            }
        }
        $propertyNode.InnerText = $entry.Value
    }
    $referenceDefinitions = @($document.SelectNodes("/*[local-name()='Project']/*[local-name()='ItemDefinitionGroup']/*[local-name()='Reference']"))
    if ($referenceDefinitions.Count -gt 1) { throw "Project contains multiple Reference item definitions: $Path" }
    if ($referenceDefinitions.Count -eq 0) {
        $itemDefinitionGroup = $document.CreateElement('ItemDefinitionGroup')
        $referenceDefinition = $document.CreateElement('Reference')
        $null = $itemDefinitionGroup.AppendChild($referenceDefinition)
        $firstItemGroup = $document.SelectSingleNode("/*[local-name()='Project']/*[local-name()='ItemGroup']")
        if ($null -eq $firstItemGroup) { $null = $document.DocumentElement.AppendChild($itemDefinitionGroup) }
        else { $null = $document.DocumentElement.InsertBefore($itemDefinitionGroup, $firstItemGroup) }
    }
    else {
        $referenceDefinition = $referenceDefinitions[0]
    }
    $privateMetadata = @($referenceDefinition.SelectNodes("*[local-name()='Private']"))
    if ($privateMetadata.Count -gt 1) { throw "Reference item definition contains multiple Private values: $Path" }
    if ($privateMetadata.Count -eq 0) {
        $private = $document.CreateElement('Private')
        $null = $referenceDefinition.AppendChild($private)
    }
    else {
        $private = $privateMetadata[0]
    }
    $private.InnerText = 'false'
    if (-not [string]::IsNullOrWhiteSpace($CppProjectReference)) {
        $cppReferences = @($document.SelectNodes(
            "/*[local-name()='Project']/*[local-name()='ItemGroup']/*[local-name()='Reference']") |
            Where-Object { $_.GetAttribute('Include').Split(',')[0].Trim() -ceq 'JetBrains.ReSharper.Cpp' })
        if ($cppReferences.Count -ne 1) {
            throw "Feature project must contain exactly one JetBrains.ReSharper.Cpp assembly reference: $Path"
        }
        $cppReference = $cppReferences[0]
        $unexpectedMetadata = @($cppReference.ChildNodes | Where-Object {
            $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.LocalName -cne 'HintPath'
        })
        if ($unexpectedMetadata.Count -gt 0) {
            throw "JetBrains.ReSharper.Cpp reference contains unsupported metadata: $Path"
        }
        $projectReference = $document.CreateElement('ProjectReference')
        $projectReference.SetAttribute('Include', $CppProjectReference)
        $null = $cppReference.ParentNode.ReplaceChild($projectReference, $cppReference)
    }
    $projectDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    foreach ($reference in @($document.SelectNodes("/*[local-name()='Project']/*[local-name()='ItemGroup']/*[local-name()='Reference']"))) {
        foreach ($hint in @($reference.SelectNodes("*[local-name()='HintPath']"))) {
            $null = $reference.RemoveChild($hint)
        }
        $name = $reference.GetAttribute('Include').Split(',')[0].Trim()
        if ($name -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw "Invalid project reference name: $name" }
        $assembly = Join-Path $ReferenceDirectory ($name + '.dll')
        if (Test-Path -LiteralPath $assembly -PathType Leaf) {
            $hint = $document.CreateElement('HintPath')
            $hint.InnerText = Get-RelativeFilePath -BaseDirectory $projectDirectory -TargetPath $assembly
            $null = $reference.AppendChild($hint)
        }
    }
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.NewLineChars = "`n"
    $settings.NewLineHandling = [Xml.NewLineHandling]::None
    $settings.OmitXmlDeclaration = $true
    $builder = [Text.StringBuilder]::new()
    $writer = [Xml.XmlWriter]::Create($builder, $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
    [IO.File]::WriteAllText($Path, $builder.ToString() + "`n", [Text.UTF8Encoding]::new($false))
    $keyPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) 'JetBrains.ReSharper.PublicKey.snk'
    [IO.File]::WriteAllBytes($keyPath, $PublicKey)
}

function Write-SourceGitIgnore {
    param([Parameter(Mandatory = $true)][string]$Path)
    $content = @'
bin/
obj/
artifacts/

*.dll
*.exe
*.pdb

packages/
*.nupkg
project.assets.json
*.cache

.vs/
.idea/
*.user
*.suo
*.DotSettings.user

Thumbs.db
Desktop.ini
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}


$script:Crc32Table = New-Object 'uint32[]' 256
for ($tableIndex = 0; $tableIndex -lt 256; ++$tableIndex) {
    [uint32]$value = $tableIndex
    for ($bit = 0; $bit -lt 8; ++$bit) {
        $value = if (($value -band 1) -ne 0) { [uint32](0xedb88320 -bxor ($value -shr 1)) } else { [uint32]($value -shr 1) }
    }
    $script:Crc32Table[$tableIndex] = $value
}
$script:RangeBytesDownloaded = 0L

$packageRoot = Get-PatchPackageRoot
if (-not $PSBoundParameters.ContainsKey('WorkRoot')) { $WorkRoot = Join-Path $packageRoot 'Work' }
if ([string]::IsNullOrWhiteSpace($WorkRoot)) { throw 'WorkRoot must not be empty.' }
$work = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\', '/')
$toolRoot = Join-Path $packageRoot 'Tools'
Assert-PatchPlainPath -Path $work
Assert-PatchPlainPath -Path $toolRoot
$null = [IO.Directory]::CreateDirectory($work)
$null = [IO.Directory]::CreateDirectory($toolRoot)

$httpClient = New-RiderHttpClient -UserAgent 'ReSharperCppCx-Workspace/1.0'
try {
    $catalog = $null
    $inputs = @()
    if ($PSCmdlet.ParameterSetName -ceq 'Download') {
        $catalog = Get-RiderCatalog -Client $httpClient
        foreach ($identifier in $DownloadVersion) {
            $release = Resolve-RiderCatalogRelease -Catalog $catalog -Identifier $identifier
            $references = Get-DownloadedReferences -Client $httpClient -Release $release -WorkRoot $work
            $inputs += [pscustomobject]@{
                Version = $release.Version
                Build = $release.Build
                Type = $release.Type
                ReferenceDirectory = $references
                DiscoveryReferenceDirectory = $references
                Origin = "download:$($release.Version)"
                RemoteRelease = $release
            }
        }
    }
    else {
        try { $catalog = Get-RiderCatalog -Client $httpClient }
        catch { Write-Warning "Could not query Rider metadata; installed product versions will be used as labels: $_"; $catalog = @() }
        foreach ($directory in $RiderDirectory) {
            $rider = (Resolve-Path -LiteralPath $directory).ProviderPath
            $productInfoPath = Join-Path $rider 'product-info.json'
            if (-not (Test-Path -LiteralPath $productInfoPath -PathType Leaf)) { throw "Rider product metadata is missing: $productInfoPath" }
            $productInfo = [IO.File]::ReadAllText($productInfoPath) | ConvertFrom-Json
            $installedVersion = [string]$productInfo.version
            $installedBuild = [string]$productInfo.buildNumber
            if ($productInfo.productCode -cne 'RD' -or [string]::IsNullOrWhiteSpace($installedVersion) -or
                $installedBuild -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                throw "Invalid Rider product metadata: $productInfoPath"
            }
            $catalogMatch = @($catalog | Where-Object { $_.Build -ceq $installedBuild })
            $canonicalVersion = $installedVersion
            $releaseType = if ($catalogMatch.Count -eq 1) { $catalogMatch[0].Type } else { 'installed' }
            $sourceReferences = [IO.Path]::GetFullPath((Join-Path $rider 'lib\ReSharperHost'))
            if (-not (Test-Path -LiteralPath $sourceReferences -PathType Container)) { throw "Rider ReSharperHost directory is missing: $sourceReferences" }
            Assert-PatchPlainPath -Path $sourceReferences
            $references = Get-InstalledReferences -SourceReferenceDirectory $sourceReferences -WorkRoot $work `
                -Version $canonicalVersion -Build $installedBuild
            $inputs += [pscustomobject]@{
                Version = $canonicalVersion
                Build = $installedBuild
                Type = $releaseType
                ReferenceDirectory = $references
                DiscoveryReferenceDirectory = $sourceReferences
                Origin = $rider
                RemoteRelease = $null
            }
        }
    }

    $resolved = @()
    $workspacePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($input in $inputs) {
        $workspaceId = Get-WorkspaceId -Version $input.Version -Build $input.Build
        foreach ($spec in $assemblySpecs) {
            $original = Find-PristineAssembly -ReferenceDirectory $input.ReferenceDirectory -Spec $spec `
                -ExpectedMarketingVersion $input.Version
            Assert-PatchPlainPath -Path $original.Path
            $sha256 = Get-Sha256 -Path $original.Path
            $assemblyName = [IO.Path]::GetFileNameWithoutExtension($spec.FileName)
            $workspace = Join-Path (Join-Path $work $workspaceId) $assemblyName
            if (-not $workspacePaths.Add($workspace)) { throw "Duplicate workspace input: $workspace" }
            if (Test-Path -LiteralPath $workspace) { throw "Workspace already exists; nothing was changed: $workspace" }
            $resolved += [pscustomobject]@{
                Spec = $spec
                Original = $original
                Sha256 = $sha256
                AssemblyName = $assemblyName
                Workspace = $workspace
                WorkspaceId = $workspaceId
                Version = $input.Version
                Build = $input.Build
                Type = $input.Type
                ReferenceDirectory = $input.ReferenceDirectory
                DiscoveryReferenceDirectory = $input.DiscoveryReferenceDirectory
                Origin = $input.Origin
                RemoteRelease = $input.RemoteRelease
            }
        }
    }

    $ilspy = Ensure-IlSpy -ToolRoot $toolRoot
    foreach ($item in $resolved) {
        $workspaceParent = [IO.Path]::GetDirectoryName($item.Workspace)
        $null = [IO.Directory]::CreateDirectory($workspaceParent)
        $stage = Join-Path $workspaceParent ('.setup-' + [Guid]::NewGuid().ToString('N'))
        $ownsStage = $false
        try {
            $null = [IO.Directory]::CreateDirectory($stage)
            $ownsStage = $true
            $copiedAssembly = Join-Path $stage $item.Spec.FileName
            [IO.File]::Copy($item.Original.Path, $copiedAssembly, $false)
            if ((Get-Sha256 -Path $copiedAssembly) -cne $item.Sha256 -or
                [Reflection.AssemblyName]::GetAssemblyName($copiedAssembly).FullName -cne $item.Original.Identity.FullName) {
                throw "Copied original failed verification: $copiedAssembly"
            }
            Assert-JetBrainsSignature -Path $copiedAssembly
            $null = Assert-RiderAssemblyMarketingVersion -Path $copiedAssembly -ExpectedVersion $item.Version

            $sourceCompanion = Join-Path $item.ReferenceDirectory ($item.AssemblyName + '.xml')
            if (-not (Test-Path -LiteralPath $sourceCompanion -PathType Leaf)) { throw "XML documentation is missing: $sourceCompanion" }
            $destinationCompanion = Join-Path $stage ($item.AssemblyName + '.xml')
            [IO.File]::Copy($sourceCompanion, $destinationCompanion, $false)

            $discoverySource = Join-Path $stage 'ReferenceDiscovery'
            $null = Invoke-PatchNative -FilePath $ilspy -Arguments @(
                '--disable-updatecheck', '-p', '--no-dead-code', '--no-dead-stores',
                '-lv', $languageVersion, '-r', $item.DiscoveryReferenceDirectory, '-o', $discoverySource, $copiedAssembly
            ) -WorkingDirectory $stage -Quiet
            $discoveryProject = Join-Path $discoverySource ($item.AssemblyName + '.csproj')
            if (-not (Test-Path -LiteralPath $discoveryProject -PathType Leaf)) {
                throw "Decompiler did not produce the reference-discovery project: $discoveryProject"
            }
            if ($null -ne $item.RemoteRelease) {
                Ensure-RemoteProjectReferences -Client $httpClient -Release $item.RemoteRelease `
                    -ReferenceDirectory $item.ReferenceDirectory -ProjectPath $discoveryProject
            }
            else {
                Ensure-InstalledProjectReferences -SourceReferenceDirectory $item.DiscoveryReferenceDirectory `
                    -ReferenceDirectory $item.ReferenceDirectory -ProjectPath $discoveryProject `
                    -Version $item.Version -Build $item.Build
            }
            Remove-DirectoryTree -Path $discoverySource

            $source = Join-Path $stage 'Source'
            Write-Host "Decompiling pristine $($item.Spec.FileName) for $($item.WorkspaceId)..."
            $null = Invoke-PatchNative -FilePath $ilspy -Arguments @(
                '--disable-updatecheck', '-p', '--no-dead-code', '--no-dead-stores',
                '-lv', $languageVersion, '-r', $item.ReferenceDirectory, '-o', $source, $copiedAssembly
            ) -WorkingDirectory $stage
            [IO.File]::Delete($destinationCompanion)

            $project = Join-Path $source ($item.AssemblyName + '.csproj')
            if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Decompiler did not produce the expected project: $project" }
            $cppProjectReference = $null
            if ($item.AssemblyName -ceq 'JetBrains.ReSharper.Feature.Services.Cpp') {
                $engineItems = @($resolved | Where-Object {
                    $_.WorkspaceId -ceq $item.WorkspaceId -and $_.AssemblyName -ceq 'JetBrains.ReSharper.Cpp'
                })
                if ($engineItems.Count -ne 1) {
                    throw "Expected exactly one ReSharper.Cpp workspace for $($item.WorkspaceId)."
                }
                $featureSourceDirectory = Join-Path $item.Workspace 'Source'
                $engineProject = Join-Path (Join-Path $engineItems[0].Workspace 'Source') 'JetBrains.ReSharper.Cpp.csproj'
                $cppProjectReference = Get-RelativeFilePath -BaseDirectory $featureSourceDirectory -TargetPath $engineProject
            }
            Set-ProjectBuildConfiguration -Path $project -ReferenceDirectory $item.ReferenceDirectory `
                -PublicKey ([byte[]]$item.Original.Identity.GetPublicKey()) -CppProjectReference $cppProjectReference

            Write-SourceGitIgnore -Path (Join-Path $source '.gitignore')
            $emptyTemplate = Join-Path $stage 'EmptyGitTemplate'
            $null = [IO.Directory]::CreateDirectory($emptyTemplate)
            $gitOptions = @(
                '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', '-c', 'core.filemode=false',
                '-c', 'core.ignorecase=false', '-c', 'core.quotePath=true',
                '-c', ('core.hooksPath=' + $emptyTemplate)
            )
            $null = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @(
                'init', '--quiet', ('--template=' + $emptyTemplate), '--initial-branch=baseline', '.'
            )) -WorkingDirectory $source -Quiet
            $null = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @('add', '--all', '--', '.')) -WorkingDirectory $source -Quiet
            $null = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @(
                '-c', 'user.name=PatchWorkspace', '-c', 'user.email=patch-workspace@invalid',
                '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--no-verify', '-m', 'Clean decompile baseline'
            )) -WorkingDirectory $source -Quiet
            Remove-DirectoryTree -Path $emptyTemplate

            $hookDirectory = Join-Path $source '.git\hooks'
            $null = [IO.Directory]::CreateDirectory($hookDirectory)
            $hook = @'
#!/bin/sh
echo "ERROR: Commits are disabled in this disposable repository."
echo "This repository exists only for diff purposes."
exit 1
'@
            [IO.File]::WriteAllText((Join-Path $hookDirectory 'pre-commit'), $hook.Replace("`r`n", "`n"), [Text.Encoding]::ASCII)
            Write-AssemblyPatchShortcut -Path (Join-Path $stage 'GeneratePatchesForThisDll.bat')

            Move-DirectoryTree -Source $stage -Destination $item.Workspace
            $ownsStage = $false
            Write-Host "Workspace: $($item.Workspace)"
            Write-Host "Source: $(Join-Path $item.Workspace 'Source')"
        }
        finally {
            if ($ownsStage -and (Test-Path -LiteralPath $stage)) { Remove-DirectoryTree -Path $stage }
        }
    }

    foreach ($input in $inputs) {
        $workspaceId = Get-WorkspaceId -Version $input.Version -Build $input.Build
        $versionRoot = Join-Path $work $workspaceId
        $solutionBaseName = 'ReSharperCppCx_' + (ConvertTo-SafeSegment -Value $input.Version -Field 'version')
        $solution = Join-Path $versionRoot ($solutionBaseName + '.slnx')
        if (Test-Path -LiteralPath $solution) { throw "Solution already exists: $solution" }
        $solutionItems = @($resolved | Where-Object { $_.WorkspaceId -ceq $workspaceId })
        if ($solutionItems.Count -ne $assemblySpecs.Count) {
            throw "Workspace does not contain every solution project: $versionRoot"
        }
        $null = Invoke-PatchNative -FilePath 'dotnet' -Arguments @(
            'new', 'sln', '--format', 'slnx', '--name', $solutionBaseName,
            '--output', $versionRoot, '--no-update-check'
        ) -WorkingDirectory $versionRoot -Quiet
        $projects = @($solutionItems | ForEach-Object {
            Join-Path (Join-Path $_.Workspace 'Source') ($_.AssemblyName + '.csproj')
        })
        $null = Invoke-PatchNative -FilePath 'dotnet' -Arguments (@('sln', $solution, 'add') + $projects) `
            -WorkingDirectory $versionRoot -Quiet
        Write-Host "Solution: $solution"
    }
}
finally { $httpClient.Dispose() }

Write-Host 'Pristine source workspaces are ready. No patches were applied and nothing was built.'
