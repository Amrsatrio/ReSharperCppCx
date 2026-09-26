# Shared implementation for the distributable scripts; dot-source, do not execute directly.
Set-StrictMode -Version Latest
$script:PatchScriptsDirectory = $PSScriptRoot

function Get-PatchPackageRoot {
    return [IO.Path]::GetFullPath((Join-Path $script:PatchScriptsDirectory '..'))
}

function New-RiderHttpClient {
    param([string]$UserAgent = 'ReSharperCppCx/1.0')
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    return $client
}

function ConvertTo-SafeSegment {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Field)
    $segment = ($Value.Trim() -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.', '_')
    if ($segment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid $Field value: $Value" }
    return $segment
}

function Get-WorkspaceId {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Build)
    return (ConvertTo-SafeSegment -Value $Version -Field 'version') + '_' +
        (ConvertTo-SafeSegment -Value $Build -Field 'build')
}

function ConvertTo-ExtendedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\')) { return '\\?\UNC\' + $fullPath.TrimStart('\') }
    return '\\?\' + $fullPath
}

function Move-DirectoryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    [IO.Directory]::Move((ConvertTo-ExtendedPath -Path $Source), (ConvertTo-ExtendedPath -Path $Destination))
}

function Remove-DirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($fullPath)) { return }
    $extendedPath = ConvertTo-ExtendedPath -Path $fullPath
    foreach ($file in [IO.Directory]::EnumerateFiles($extendedPath, '*', [IO.SearchOption]::AllDirectories)) {
        [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
    }
    [IO.Directory]::Delete($extendedPath, $true)
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    # Direct read-only hashing also works under an installer's inherited -WhatIf.
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead((ConvertTo-ExtendedPath -Path $Path))
        try {
            return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally { $stream.Dispose() }
    } finally { $algorithm.Dispose() }
}

function Write-PatchJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}


function Get-PayloadFiles {
    param([Parameter(Mandatory)][string]$Directory, [switch]$Strict)
    $rootPath = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).ProviderPath.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { throw "Source is not a directory: $Directory" }
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    while ($pending.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            if ($entry.PSIsContainer) {
                if ($entry.Name -in @('bin', 'obj', 'artifacts', '.git', '.vs', '.idea')) {
                    if ($Strict) { throw "Unexpected directory in verified source: $($entry.FullName)" }
                    continue
                }
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked source directory is unsupported: $($entry.FullName)" }
                $pending.Push($entry.FullName)
            } elseif ($entry.Extension -in @('.cs', '.csproj', '.resx', '.snk')) {
                if ($entry.Extension -eq '.csproj' -and $entry.Name -notin @(
                    'JetBrains.ReSharper.Cpp.csproj',
                    'JetBrains.ReSharper.Feature.Services.Cpp.csproj'
                )) {
                    if ($Strict) { throw "Unexpected project in verified source: $($entry.FullName)" }
                    continue
                }
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked source file is unsupported: $($entry.FullName)" }
                $relative = $entry.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
                $files.Add($relative, $entry.FullName)
            } elseif ($Strict) {
                throw "Unexpected file in verified source: $($entry.FullName)"
            }
        }
    }
    foreach ($entry in $files.GetEnumerator()) { [pscustomobject]@{ RelativePath = $entry.Key; FullName = $entry.Value } }
}


function Get-TreeFingerprint {
    param([Parameter(Mandatory)][string]$Directory, [switch]$Strict)
    $files = @(Get-PayloadFiles -Directory $Directory -Strict:$Strict)
    $hash = [Security.Cryptography.SHA256]::Create()
    $encoding = [Text.UTF8Encoding]::new($false)
    try {
        foreach ($file in $files) {
            $bytes = $encoding.GetBytes($file.RelativePath + [char]0 + (Get-Sha256 $file.FullName) + "`n")
            $null = $hash.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
        }
        $null = $hash.TransformFinalBlock([byte[]]@(), 0, 0)
        return [pscustomobject]@{ Sha256 = [BitConverter]::ToString($hash.Hash).Replace('-', '').ToLowerInvariant(); FileCount = $files.Count }
    } finally { $hash.Dispose() }
}

function Invoke-PatchNative {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDirectory, [switch]$Quiet)
    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $isGit = [IO.Path]::GetFileNameWithoutExtension($command.Source) -ieq 'git'
    if ($isGit) {
        $Arguments = @('-c', 'core.longpaths=true') + $Arguments
    }
    $quoted = foreach ($argument in $Arguments) {
        # Windows CRT argv quoting, including embedded quotes and trailing backslashes.
        '"' + [regex]::Replace([regex]::Replace([string]$argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $command.Source
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($WorkingDirectory) { $info.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
    $emptyGitConfig = $null
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) { $info.EnvironmentVariables.Remove($key) }
    }
    $info.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    if ($isGit) {
        $emptyGitConfig = [IO.Path]::GetTempFileName()
        $info.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $emptyGitConfig
    }
    $info.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'
    $info.EnvironmentVariables['DOTNET_NOLOGO'] = '1'
    $info.EnvironmentVariables['DOTNET_SKIP_FIRST_TIME_EXPERIENCE'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result }
        if (-not $Quiet) {
            if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
            if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }
        }
        if ($result.ExitCode -ne 0) { throw "$FilePath failed (exit $($result.ExitCode)).`n$($result.StdOut)`n$($result.StdErr)" }
        return $result
    } finally {
        $process.Dispose()
        if ($null -ne $emptyGitConfig) { [IO.File]::Delete($emptyGitConfig) }
    }
}

function Write-AtomicPatchJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $null = [IO.Directory]::CreateDirectory($directory)
    $id = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($fullPath) + '.' + $id + '.tmp')
    $rollback = Join-Path $directory ('.' + [IO.Path]::GetFileName($fullPath) + '.' + $id + '.rollback.json')
    try {
        Write-PatchJson -Path $temporary -Value $Value
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporary, $fullPath, $rollback)
            [IO.File]::Delete($rollback)
        }
        else { [IO.File]::Move($temporary, $fullPath) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($rollback)) { [IO.File]::Delete($rollback) }
    }
}

function Assert-PatchPlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse-point paths are not supported: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-AssemblyIdentityOrNull {
    param([Parameter(Mandatory)][string]$Path)
    try { return [Reflection.AssemblyName]::GetAssemblyName([IO.Path]::GetFullPath($Path)) }
    catch { return $null }
}

function Test-JetBrainsSignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($null -eq $signature.SignerCertificate) { '' } else { $signature.SignerCertificate.Subject }
    return $signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
        $subject -cmatch '(^|,\s*)CN=JetBrains s\.r\.o\.(,|$)' -and
        $subject -cmatch '(^|,\s*)O=JetBrains s\.r\.o\.(,|$)'
}

function Assert-JetBrainsSignature {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-JetBrainsSignature -Path $Path)) {
        throw "Assembly does not have a valid JetBrains Authenticode signature: $Path"
    }
}

function ConvertTo-RiderBuild {
    param([Parameter(Mandatory)][string]$Build)
    $normalized = $Build.Trim()
    if ($normalized.StartsWith('RD-', [StringComparison]::Ordinal)) { $normalized = $normalized.Substring(3) }
    if ($normalized -cnotmatch '^\d+(?:\.\d+)+$') { throw "Invalid concrete Rider build: $Build" }
    $components = @()
    foreach ($component in $normalized.Split('.')) {
        [long]$value = 0
        if (-not [long]::TryParse($component, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            throw "Rider build component is out of range: $Build"
        }
        $components += $value
    }
    return $components
}

function Compare-RiderBuild {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $leftParts = @(ConvertTo-RiderBuild -Build $Left)
    $rightParts = @(ConvertTo-RiderBuild -Build $Right)
    $shared = [Math]::Min($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $shared; ++$index) {
        if ($leftParts[$index] -lt $rightParts[$index]) { return -1 }
        if ($leftParts[$index] -gt $rightParts[$index]) { return 1 }
    }
    if ($leftParts.Count -lt $rightParts.Count) { return -1 }
    if ($leftParts.Count -gt $rightParts.Count) { return 1 }
    return 0
}

function Get-RiderCatalog {
    param([Parameter(Mandatory)][Net.Http.HttpClient]$Client)
    $uri = 'https://data.services.jetbrains.com/products?code=RD'
    $products = @($Client.GetStringAsync($uri).GetAwaiter().GetResult() | ConvertFrom-Json)
    if ($products.Count -ne 1 -or $products[0].code -cne 'RD') {
        throw "Unexpected Rider product metadata: $uri"
    }
    $releases = [Collections.Generic.List[object]]::new()
    $seenBuilds = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($release in @($products[0].releases)) {
        $version = [string]$release.version
        $build = [string]$release.build
        if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($build)) { continue }
        $components = @(ConvertTo-RiderBuild -Build $build)
        $numericKey = ($components | ForEach-Object { $_.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join '.'
        if ($seenBuilds.ContainsKey($numericKey)) {
            throw "Duplicate Rider catalog build $build for $version and $($seenBuilds[$numericKey])."
        }
        $seenBuilds.Add($numericKey, $version)
        $archive = $release.downloads.PSObject.Properties['windowsZip']
        $archiveValue = if ($null -eq $archive) { $null } else { $archive.Value }
        $archiveAvailable = $null -ne $archiveValue -and
            -not [string]::IsNullOrWhiteSpace([string]$archiveValue.link) -and [long]$archiveValue.size -gt 0
        $printableProperty = $release.PSObject.Properties['printableReleaseType']
        $printableReleaseType = if ($null -eq $printableProperty) { '' } else { [string]$printableProperty.Value }
        $releases.Add([pscustomobject]@{
            Type = [string]$release.type
            Version = $version
            MajorVersion = [string]$release.majorVersion
            Build = $build
            Date = [string]$release.date
            PrintableReleaseType = $printableReleaseType
            Downloads = $release.downloads
            WindowsZipAvailable = $archiveAvailable
        })
    }
    $array = $releases.ToArray()
    [Array]::Sort($array, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            $order = Compare-RiderBuild -Left $left.Build -Right $right.Build
            if ($order -ne 0) { return -$order }
            return [StringComparer]::Ordinal.Compare($left.Version, $right.Version)
        }))
    return @($array)
}

function Resolve-RiderCatalogRelease {
    param(
        [Parameter(Mandatory)][object[]]$Catalog,
        [Parameter(Mandatory)][string]$Identifier
    )
    $matches = @($Catalog | Where-Object {
        $_.Version -ieq $Identifier -or $_.Build -ceq $Identifier
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) { throw "Rider identifier is ambiguous: $Identifier" }
    $prefixMatches = @($Catalog | Where-Object {
        $_.Version.StartsWith($Identifier, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -ExpandProperty Version -Unique)
    $hint = if ($prefixMatches.Count) { " Matching versions: $($prefixMatches -join ', ')." } else { '' }
    throw "Rider release was not found: $Identifier.$hint"
}

function Get-AssemblyWaveMarketingMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $pathText = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fullPath))
    $childScript = @'
$ErrorActionPreference = 'Stop'
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PATH__'))
$assembly = [Reflection.Assembly]::LoadFrom($path)
$rows = @()
foreach ($attribute in $assembly.GetCustomAttributes([Reflection.AssemblyMetadataAttribute], $false)) {
    if ($attribute.Key -like 'WaveMarketingName*') {
        $rows += [pscustomobject]@{ kind = 'AssemblyMetadata'; key = [string]$attribute.Key; value = [string]$attribute.Value }
    }
}
foreach ($attribute in $assembly.GetCustomAttributes([ComponentModel.EditorAttribute], $false)) {
    if ($attribute.EditorTypeName -like 'WaveMarketingName*') {
        $rows += [pscustomobject]@{ kind = 'Editor'; key = [string]$attribute.EditorTypeName; value = [string]$attribute.EditorBaseTypeName }
    }
}
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Output ($rows | ConvertTo-Json -Compress)
'@
    $childScript = $childScript.Replace('__PATH__', $pathText)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $result = Invoke-PatchNative -FilePath $powershell -Arguments @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    ) -WorkingDirectory ([IO.Path]::GetDirectoryName($fullPath)) -Quiet
    try {
        $parsed = $result.StdOut.Trim() | ConvertFrom-Json
        foreach ($row in @($parsed)) { Write-Output $row }
    }
    catch { throw "Could not read Rider wave marketing metadata from $fullPath`: $_" }
}

function Assert-RiderAssemblyMarketingVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $expected = @(
        'AssemblyMetadata|WaveMarketingName',
        'AssemblyMetadata|WaveMarketingNameCompressed',
        'Editor|WaveMarketingName',
        'Editor|WaveMarketingNameCompressed'
    )
    $rows = @(Get-AssemblyWaveMarketingMetadata -Path $Path)
    $found = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        $key = [string]$row.kind + '|' + [string]$row.key
        if ($expected -cnotcontains $key) { continue }
        if ($found.ContainsKey($key)) { throw "Duplicate $key metadata in $Path" }
        $found.Add($key, $row)
    }
    foreach ($key in $expected) {
        if (-not $found.ContainsKey($key)) { throw "Missing $key metadata in $Path" }
        $value = [string]$found[$key].value
        if ($value -cne $ExpectedVersion) {
            throw "Assembly wave marketing version mismatch: $Path. Expected '$ExpectedVersion'; found '$value' in $key."
        }
    }
    return $ExpectedVersion
}

function Get-RiderInstallStatePath {
    param([Parameter(Mandatory)][string]$RiderDirectory)
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    $canonical = [IO.Path]::GetFullPath($RiderDirectory).TrimEnd('\').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    return Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'ReSharperCppCx') 'Installations') (Join-Path $id 'install.json')
}

function Get-RiderPatchSets {
    param([Parameter(Mandatory)][string]$PatchRoot)
    $root = [IO.Path]::GetFullPath($PatchRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $sets = [Collections.Generic.List[object]]::new()
    $buildNames = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        if ($directory.Name -cnotmatch '^(.+)_([0-9]+(?:\.[0-9]+)+)$') { continue }
        $version = $Matches[1]
        $build = $Matches[2]
        $components = @(ConvertTo-RiderBuild -Build $build)
        $numericKey = ($components | ForEach-Object { $_.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join '.'
        if ($buildNames.ContainsKey($numericKey)) {
            throw "Duplicate patch-set build $build in $($directory.Name) and $($buildNames[$numericKey])."
        }
        $assemblyDirectories = @(
            (Join-Path $directory.FullName 'JetBrains.ReSharper.Cpp'),
            (Join-Path $directory.FullName 'JetBrains.ReSharper.Feature.Services.Cpp')
        )
        $patchFiles = @()
        foreach ($assemblyDirectory in $assemblyDirectories) {
            if (-not (Test-Path -LiteralPath $assemblyDirectory -PathType Container)) {
                throw "Incomplete patch set $($directory.Name): $assemblyDirectory is missing."
            }
            $files = @(Get-ChildItem -LiteralPath $assemblyDirectory -File -Filter '*.patch' | Sort-Object Name)
            if ($files.Count -eq 0) { throw "Incomplete patch set $($directory.Name): $assemblyDirectory has no patches." }
            $patchFiles += $files
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        $encoding = [Text.UTF8Encoding]::new($false)
        try {
            foreach ($file in @($patchFiles | Sort-Object FullName)) {
                $relative = $file.FullName.Substring($directory.FullName.Length + 1).Replace('\', '/')
                $bytes = $encoding.GetBytes($relative + [char]0 + (Get-Sha256 $file.FullName) + "`n")
                $null = $hash.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
            }
            $null = $hash.TransformFinalBlock([byte[]]@(), 0, 0)
            $fingerprint = [BitConverter]::ToString($hash.Hash).Replace('-', '').ToLowerInvariant()
        }
        finally { $hash.Dispose() }
        $buildNames.Add($numericKey, $directory.Name)
        $sets.Add([pscustomobject]@{
            Name = $directory.Name
            Version = $version
            Build = $build
            Directory = $directory.FullName
            Sha256 = $fingerprint
        })
    }
    return @($sets)
}

function Resolve-RiderPatchSet {
    param(
        [Parameter(Mandatory)][object[]]$PatchSets,
        [Parameter(Mandatory)][string]$TargetBuild,
        [Parameter(Mandatory)][string]$Selection
    )
    $null = ConvertTo-RiderBuild -Build $TargetBuild
    if ($Selection -cne 'Auto') {
        $matches = @($PatchSets | Where-Object { $_.Name -ceq $Selection })
        if ($matches.Count -ne 1) { throw "Patch set was not found: $Selection" }
        return [pscustomobject]@{ PatchSet = $matches[0]; IsExact = ((Compare-RiderBuild $matches[0].Build $TargetBuild) -eq 0); IsNewer = ((Compare-RiderBuild $matches[0].Build $TargetBuild) -gt 0) }
    }
    $best = $null
    foreach ($candidate in $PatchSets) {
        $relation = Compare-RiderBuild -Left $candidate.Build -Right $TargetBuild
        if ($relation -gt 0) { continue }
        if ($null -eq $best -or (Compare-RiderBuild -Left $candidate.Build -Right $best.Build) -gt 0) { $best = $candidate }
    }
    if ($null -eq $best) { throw "No patch set precedes Rider build $TargetBuild." }
    return [pscustomobject]@{ PatchSet = $best; IsExact = ((Compare-RiderBuild $best.Build $TargetBuild) -eq 0); IsNewer = $false }
}

function Get-RiderInstallationInfo {
    param(
        [Parameter(Mandatory)][string]$RiderDirectory,
        [Parameter(Mandatory)][string]$Source,
        [switch]$AllowInvalid
    )
    try {
        $root = (Resolve-Path -LiteralPath $RiderDirectory -ErrorAction Stop).ProviderPath.TrimEnd('\')
        Assert-PatchPlainPath -Path $root
        $productPath = Join-Path $root 'product-info.json'
        if (-not (Test-Path -LiteralPath $productPath -PathType Leaf)) { throw "product-info.json is missing: $root" }
        $product = [IO.File]::ReadAllText($productPath) | ConvertFrom-Json
        if ($product.productCode -cne 'RD' -or [string]::IsNullOrWhiteSpace([string]$product.version) -or
            [string]::IsNullOrWhiteSpace([string]$product.buildNumber)) {
            throw "Not a valid Rider product root: $root"
        }
        $null = ConvertTo-RiderBuild -Build ([string]$product.buildNumber)
        $launches = @($product.launch | Where-Object { $_.os -ceq 'Windows' })
        if ($launches.Count -lt 1) { throw "Rider has no Windows launcher: $root" }
        $launcher = $null
        foreach ($launch in $launches) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $root ([string]$launch.launcherPath)))
            if (-not $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $launcher = [pscustomobject]@{ Path = $candidate; Architecture = [string]$launch.arch }; break }
        }
        if ($null -eq $launcher) { throw "Rider Windows launcher is missing: $root" }
        $hostDirectory = Join-Path $root 'lib\ReSharperHost'
        if (-not (Test-Path -LiteralPath $hostDirectory -PathType Container)) { throw "ReSharperHost is missing: $root" }
        $validationErrors = [Collections.Generic.List[string]]::new()
        $hasBackup = $false
        $canonicalOriginal = $true
        foreach ($fileName in @('JetBrains.ReSharper.Cpp.dll', 'JetBrains.ReSharper.Feature.Services.Cpp.dll')) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($fileName)
            $canonical = Join-Path $hostDirectory $fileName
            $candidates = @(
                [pscustomobject]@{ Path = $canonical; Backup = $false },
                [pscustomobject]@{ Path = (Join-Path $hostDirectory ($baseName + '-.dll')); Backup = $true },
                [pscustomobject]@{ Path = (Join-Path $hostDirectory ($baseName + '.bak.dll')); Backup = $true },
                [pscustomobject]@{ Path = ($canonical + '.cppcx.bak'); Backup = $true }
            )
            if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) { $validationErrors.Add("Canonical DLL is missing: $canonical") }
            foreach ($candidate in $candidates) {
                if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
                try {
                    $identity = Get-AssemblyIdentityOrNull -Path $candidate.Path
                    if ($null -eq $identity -or $identity.Name -cne $baseName -or $identity.GetPublicKeyToken().Length -eq 0) {
                        throw "Assembly identity mismatch: $($candidate.Path)"
                    }
                    $null = Assert-RiderAssemblyMarketingVersion -Path $candidate.Path -ExpectedVersion ([string]$product.version)
                    if ($candidate.Backup) {
                        $hasBackup = $true
                        Assert-JetBrainsSignature -Path $candidate.Path
                    }
                    elseif (-not (Test-JetBrainsSignature -Path $candidate.Path)) { $canonicalOriginal = $false }
                }
                catch { $validationErrors.Add($_.Exception.Message) }
            }
        }
        $recordPath = Get-RiderInstallStatePath -RiderDirectory $root
        $hasRecord = Test-Path -LiteralPath $recordPath -PathType Leaf
        $status = if ($validationErrors.Count -gt 0) { 'Recovery required' }
            elseif ($hasRecord) { 'Patched' }
            elseif ($hasBackup -or -not $canonicalOriginal) { 'Recovery required' }
            else { 'Original' }
        if ($status -ceq 'Original') {
            try {
                $sets = @(Get-RiderPatchSets -PatchRoot (Join-Path (Get-PatchPackageRoot) 'Patches'))
                $null = Resolve-RiderPatchSet -PatchSets $sets -TargetBuild ([string]$product.buildNumber) -Selection 'Auto'
            }
            catch { $status = 'Unsupported' }
        }
        return [pscustomobject]@{
            RiderDirectory = $root
            Version = [string]$product.version
            Build = [string]$product.buildNumber
            Architecture = $launcher.Architecture
            Launcher = $launcher.Path
            DataDirectoryName = [string]$product.dataDirectoryName
            Channel = 'installed'
            Source = $Source
            InstallStatus = $status
            ValidationError = ($validationErrors -join '; ')
        }
    }
    catch {
        if (-not $AllowInvalid) { throw }
        return $null
    }
}

function Get-RiderInstallations {
    param([string[]]$AdditionalPath = @(), [string]$ToolboxRoot)
    $candidates = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-RiderCandidate([string]$Path, [string]$Source) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $full = [IO.Path]::GetFullPath($Path.Trim().Trim('"')).TrimEnd('\') }
        catch { return }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
        if ($candidates.ContainsKey($full)) {
            $null = $candidates[$full].Sources.Add($Source)
        }
        else {
            $sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $null = $sources.Add($Source)
            $candidates.Add($full, [pscustomobject]@{ Path = $full; Sources = $sources })
        }
    }
    function Scan-RiderRoot([string]$Root, [int]$MaxDepth, [string]$Source) {
        if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ Path = [IO.Path]::GetFullPath($Root); Depth = 0 })
        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            if (Test-Path -LiteralPath (Join-Path $item.Path 'product-info.json') -PathType Leaf) {
                Add-RiderCandidate $item.Path $Source
                continue
            }
            if ($item.Depth -ge $MaxDepth) { continue }
            foreach ($directory in @(Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue)) {
                if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $queue.Enqueue([pscustomobject]@{ Path = $directory.FullName; Depth = $item.Depth + 1 })
                }
            }
        }
    }
    foreach ($path in $AdditionalPath) {
        $full = (Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath
        Add-RiderCandidate $full 'explicit'
    }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($null -ne $uninstall) {
                    try {
                        foreach ($name in $uninstall.GetSubKeyNames()) {
                            $entry = $uninstall.OpenSubKey($name)
                            try {
                                $displayName = [string]$entry.GetValue('DisplayName')
                                if ($name -match 'Rider' -or $displayName -match 'Rider') {
                                    Add-RiderCandidate ([string]$entry.GetValue('InstallLocation')) "uninstall:$hive/$view"
                                }
                            }
                            finally { if ($null -ne $entry) { $entry.Dispose() } }
                        }
                    }
                    finally { $uninstall.Dispose() }
                }
                $riderKey = $base.OpenSubKey('SOFTWARE\JetBrains\Rider')
                if ($null -ne $riderKey) {
                    try {
                        foreach ($name in $riderKey.GetSubKeyNames()) {
                            $entry = $riderKey.OpenSubKey($name)
                            try { Add-RiderCandidate ([string]$entry.GetValue('InstallDir')) "jetbrains:$hive/$view" }
                            finally { if ($null -ne $entry) { $entry.Dispose() } }
                        }
                    }
                    finally { $riderKey.Dispose() }
                }
                foreach ($toolboxKeyName in @('Software\JetBrains\Toolbox', 'Software\JetBrains s.r.o.\JetBrainsToolbox')) {
                    $toolboxKey = $base.OpenSubKey($toolboxKeyName)
                    if ($null -eq $toolboxKey) { continue }
                    try {
                        $toolboxExecutable = [string]$toolboxKey.GetValue('')
                        if (-not [string]::IsNullOrWhiteSpace($toolboxExecutable)) {
                            $toolboxRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($toolboxExecutable))
                            if ([IO.Path]::GetFileName($toolboxRoot) -ieq 'bin') { $toolboxRoot = [IO.Path]::GetDirectoryName($toolboxRoot) }
                            Scan-RiderRoot $toolboxRoot 6 "toolbox-registry:$hive/$view"
                        }
                    }
                    finally { $toolboxKey.Dispose() }
                }
            }
            finally { $base.Dispose() }
        }
    }
    if (-not $PSBoundParameters.ContainsKey('ToolboxRoot') -and
        -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $ToolboxRoot = Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox'
    }
    if (-not [string]::IsNullOrWhiteSpace($ToolboxRoot)) {
        $settingsPath = Join-Path $ToolboxRoot '.settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
                $installProperty = $settings.PSObject.Properties['install_location']
                if ($null -ne $installProperty -and
                    -not [string]::IsNullOrWhiteSpace([string]$installProperty.Value)) {
                    $installLocation = [string]$installProperty.Value
                    Scan-RiderRoot $installLocation 3 'toolbox-settings'
                    Scan-RiderRoot (Join-Path $installLocation 'apps') 6 'toolbox1-settings'
                }
            }
            catch { Write-Warning "Ignoring malformed Toolbox settings JSON: $settingsPath" }
        }
        $statePath = Join-Path $ToolboxRoot 'state.json'
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $toolboxState = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
                $toolsProperty = $toolboxState.PSObject.Properties['tools']
                if ($null -eq $toolsProperty) { throw 'Missing tools array.' }
                foreach ($tool in @($toolsProperty.Value)) {
                    if ([string]$tool.productCode -ceq 'RD') {
                        Add-RiderCandidate ([string]$tool.installLocation) 'toolbox-state'
                    }
                }
            }
            catch { Write-Warning "Ignoring malformed Toolbox state JSON: $statePath" }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Scan-RiderRoot (Join-Path $env:LOCALAPPDATA 'Programs') 2 'local-programs'
        Scan-RiderRoot (Join-Path $env:LOCALAPPDATA 'JetBrains\Installations') 3 'jetbrains-installations'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Scan-RiderRoot (Join-Path $env:ProgramFiles 'JetBrains') 2 'program-files'
    }
    ${programFilesX86} = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace(${programFilesX86})) {
        Scan-RiderRoot (Join-Path ${programFilesX86} 'JetBrains\Installations') 3 'program-files-x86'
    }
    $results = @()
    foreach ($candidate in $candidates.Values) {
        $source = (@($candidate.Sources) | Sort-Object) -join ','
        $info = Get-RiderInstallationInfo -RiderDirectory $candidate.Path -Source $source -AllowInvalid
        if ($null -ne $info) { $results += $info }
    }
    $sorted = @($results)
    [Array]::Sort($sorted, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            $order = Compare-RiderBuild -Left $left.Build -Right $right.Build
            if ($order -ne 0) { return -$order }
            return [StringComparer]::OrdinalIgnoreCase.Compare($left.RiderDirectory, $right.RiderDirectory)
        }))
    return $sorted
}

function Invoke-RiderPatchSet {
    param(
        [Parameter(Mandatory)][string]$WorkspaceDirectory,
        [Parameter(Mandatory)][string]$PatchSetDirectory
    )
    $workspace = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $patchSet = [IO.Path]::GetFullPath($PatchSetDirectory)
    $projects = @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')
    $failures = [Collections.Generic.List[object]]::new()
    $sourceTrees = @()
    try {
        foreach ($project in $projects) {
            $source = Join-Path (Join-Path $workspace $project) 'Source'
            if (-not (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container)) {
                throw "Source Git baseline is missing: $source"
            }
            $patchDirectory = Join-Path $patchSet $project
            $patches = @(Get-ChildItem -LiteralPath $patchDirectory -File -Filter '*.patch' | Sort-Object Name)
            if ($patches.Count -eq 0) { throw "No patches found: $patchDirectory" }
            $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $appliedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($patch in $patches) {
                $targetPath = $null
                try {
                    $text = [IO.File]::ReadAllText($patch.FullName)
                    $headers = [regex]::Matches($text, '(?m)^diff --git a/(.+) b/(.+)\r?$')
                    if ($headers.Count -ne 1) { throw 'Patch must contain exactly one diff.' }
                    $left = $headers[0].Groups[1].Value
                    $right = $headers[0].Groups[2].Value
                    if ($left -cne $right -or $left.StartsWith('/') -or $left.Contains('\') -or
                        @($left.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '' }).Count -gt 0) {
                        throw "Unsafe or renamed patch path: $left -> $right"
                    }
                    if (-not $seenPaths.Add($left)) { throw "Duplicate patch target: $left" }
                    $targetPath = $left
                    $null = Invoke-PatchNative -FilePath git -Arguments @(
                        'apply', '--check', '--', $patch.FullName
                    ) -WorkingDirectory $source -Quiet
                    $null = Invoke-PatchNative -FilePath git -Arguments @(
                        'apply', '--', $patch.FullName
                    ) -WorkingDirectory $source -Quiet
                    $null = $appliedPaths.Add($targetPath)
                }
                catch {
                    $failures.Add([pscustomobject]@{
                        project = $project
                        patch = $patch.Name
                        path = $targetPath
                        error = $_.Exception.Message.Trim()
                    })
                }
            }
            $null = Invoke-PatchNative -FilePath git -Arguments @(
                'add', '--all', '--', '.'
            ) -WorkingDirectory $source -Quiet
            $diff = Invoke-PatchNative -FilePath git -Arguments @(
                'diff', '--cached', '--name-only', '-z', '--no-renames', 'HEAD', '--', '.'
            ) -WorkingDirectory $source -Quiet
            $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($path in $diff.StdOut.Split([char]0)) {
                if ($path) { $null = $actual.Add($path.Replace('\', '/')) }
            }
            $unstaged = Invoke-PatchNative -FilePath git -Arguments @(
                'diff', '--name-only', '-z', '--no-renames', '--', '.'
            ) -WorkingDirectory $source -Quiet
            $untracked = Invoke-PatchNative -FilePath git -Arguments @(
                'ls-files', '--others', '--exclude-standard', '-z', '--', '.'
            ) -WorkingDirectory $source -Quiet
            if ($unstaged.StdOut.Length -ne 0 -or $untracked.StdOut.Length -ne 0) {
                throw "Patch application left unstaged paths for $project."
            }
            if (-not $actual.SetEquals($appliedPaths)) {
                throw "Staged paths do not match successfully applied patches for $project."
            }
            $fingerprint = Get-TreeFingerprint -Directory $source
            $sourceTrees += [ordered]@{
                project = $project
                sha256 = $fingerprint.Sha256
                fileCount = $fingerprint.FileCount
            }
        }
    }
    catch {
        $failures.Add([pscustomobject]@{
            project = 'workspace'
            patch = $null
            path = $null
            error = $_.Exception.Message.Trim()
        })
        foreach ($project in $projects) {
            $source = Join-Path (Join-Path $workspace $project) 'Source'
            if (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container) {
                try {
                    $null = Invoke-PatchNative -FilePath git -Arguments @(
                        'add', '--all', '--', '.'
                    ) -WorkingDirectory $source -Quiet
                }
                catch { Write-Warning "Could not stage partial patch workspace $source`: $_" }
            }
        }
        if ($sourceTrees.Count -ne 2) {
            try { $sourceTrees = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace) }
            catch { $sourceTrees = @() }
        }
    }
    $statePath = Join-Path $workspace 'workspace.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $state.patchStatus = if ($failures.Count -eq 0) { 'applied' } else { 'failed' }
        $state.patchError = if ($failures.Count -eq 0) { $null } else {
            (@($failures | ForEach-Object {
                "$($_.project)/$($_.patch): $($_.error)"
            }) -join "`n")
        }
        $state.sourceTrees = $sourceTrees
        $state | Add-Member -MemberType NoteProperty -Name failedPatches -Value @($failures) -Force
        Write-AtomicPatchJson -Path $statePath -Value $state
    }
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "Failed patches ($($failures.Count)):" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "  $($failure.project) :: $($failure.patch)" -ForegroundColor Red
            Write-Host "    $($failure.error)"
        }
        throw "$($failures.Count) patch(es) failed. The workspace was retained with successful patches staged: $workspace"
    }
    return $sourceTrees
}

function Get-RiderWorkspaceDirectory {
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Build
    )
    return Join-Path ([IO.Path]::GetFullPath($WorkRoot)) `
        (Get-WorkspaceId -Version $Version -Build $Build)
}

function ConvertTo-CrlfBatchText {
    param([Parameter(Mandatory)][string]$Text)
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    return $normalized.TrimEnd([char[]]@("`r", "`n")) + "`r`n"
}

function Write-AssemblyPatchShortcut {
    param([Parameter(Mandatory)][string]$Path)
    $generator = Join-Path $script:PatchScriptsDirectory 'GeneratePatches.ps1'
    $content = @'
@echo off
setlocal
set "THIS_DIR=%~dp0"
set "THIS_DIR=%THIS_DIR:~0,-1%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "__SCRIPT__" -WorkDir "%THIS_DIR%"
set "EXIT_CODE=%ERRORLEVEL%"
if /i not "%~1"=="--no-pause" pause
exit /b %EXIT_CODE%
'@
    $content = $content.Replace('__SCRIPT__', $generator)
    [IO.File]::WriteAllText($Path, (ConvertTo-CrlfBatchText -Text $content), [Text.Encoding]::ASCII)
}

function Write-RiderWorkspaceRunConfigurations {
    param([Parameter(Mandatory)][string]$WorkspaceDirectory)
    $workspace = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $runDirectory = Join-Path $workspace '.run'
    $null = [IO.Directory]::CreateDirectory($runDirectory)
    $reapplyScript = Join-Path $script:PatchScriptsDirectory 'Reapply-ReSharperCppCxPatches.ps1'
    if (-not (Test-Path -LiteralPath $reapplyScript -PathType Leaf)) {
        throw "Reapply script is missing: $reapplyScript"
    }


    $batch = @"
@echo off
setlocal
set "THIS_DIR=%~dp0"
set "THIS_DIR=%THIS_DIR:~0,-1%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$reapplyScript" -WorkspaceDirectory "%THIS_DIR%"
set "EXIT_CODE=%ERRORLEVEL%"
if /i not "%~1"=="--no-pause" pause
exit /b %EXIT_CODE%
"@
    [IO.File]::WriteAllText(
        (Join-Path $workspace 'ReapplyPatches.bat'),
        (ConvertTo-CrlfBatchText -Text $batch),
        [Text.Encoding]::ASCII)

    function Write-ShellRunConfiguration {
        param([string]$Name, [string]$RelativeScriptPath, [string]$Options)
        $safeFileName = ($Name -replace '[<>:"/\\|?*]+', '_') + '.run.xml'
        $escapedName = [Security.SecurityElement]::Escape($Name)
        $escapedPath = [Security.SecurityElement]::Escape('$PROJECT_DIR$/' + $RelativeScriptPath.Replace('\', '/'))
        $escapedOptions = [Security.SecurityElement]::Escape($Options)
        $xml = @"
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="$escapedName" type="ShConfigurationType">
    <option name="INDEPENDENT_SCRIPT_PATH" value="false" />
    <option name="SCRIPT_PATH" value="$escapedPath" />
    <option name="SCRIPT_OPTIONS" value="$escapedOptions" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="`$PROJECT_DIR`$" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="true" />
    <method v="2" />
  </configuration>
</component>
"@
        [IO.File]::WriteAllText((Join-Path $runDirectory $safeFileName),
            $xml.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    }

    foreach ($project in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
        Write-AssemblyPatchShortcut -Path (Join-Path (Join-Path $workspace $project) 'GeneratePatchesForThisDll.bat')

        $staleConfigurationName = ("Generate Patches - " + $project) -replace '[<>:"/\\|?*]+', '_'
        [IO.File]::Delete((Join-Path $runDirectory ($staleConfigurationName + '.run.xml')))
    }

    $generateWorkspaceScript = Join-Path $script:PatchScriptsDirectory 'GenerateWorkspacePatches.ps1'
    $workspaceBatchTemplate = @'
@echo off
setlocal
set "THIS_DIR=%~dp0"
set "THIS_DIR=%THIS_DIR:~0,-1%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "__SCRIPT__" -WorkspaceDirectory "%THIS_DIR%"__PUBLISH__
set "EXIT_CODE=%ERRORLEVEL%"
if /i not "%~1"=="--no-pause" pause
exit /b %EXIT_CODE%
'@
    $workspaceBatchTemplate = $workspaceBatchTemplate.Replace('__SCRIPT__', $generateWorkspaceScript)
    $generateWorkspaceBatch = $workspaceBatchTemplate.Replace('__PUBLISH__', '')
    $publishWorkspaceBatch = $workspaceBatchTemplate.Replace('__PUBLISH__', ' -Publish')
    [IO.File]::WriteAllText(
        (Join-Path $workspace 'GeneratePatches.bat'),
        (ConvertTo-CrlfBatchText -Text $generateWorkspaceBatch),
        [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $workspace 'GeneratePatchesAndPublish.bat'),
        (ConvertTo-CrlfBatchText -Text $publishWorkspaceBatch),
        [Text.Encoding]::ASCII)

    Write-ShellRunConfiguration -Name 'Reapply All Patches' -RelativeScriptPath 'ReapplyPatches.bat' -Options '--no-pause'
    Write-ShellRunConfiguration -Name 'Generate Patches' -RelativeScriptPath 'GeneratePatches.bat' -Options '--no-pause'
    Write-ShellRunConfiguration -Name 'Generate Patches and Publish' `
        -RelativeScriptPath 'GeneratePatchesAndPublish.bat' -Options '--no-pause'
}

function Get-RiderWorkspaceOriginals {
    param(
        [Parameter(Mandatory)][string]$WorkspaceDirectory,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $workspace = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $result = @()
    foreach ($name in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
        $path = Join-Path (Join-Path $workspace $name) ($name + '.dll')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workspace original is missing: $path" }
        Assert-JetBrainsSignature -Path $path
        $identity = [Reflection.AssemblyName]::GetAssemblyName($path)
        if ($identity.Name -cne $name -or $identity.GetPublicKeyToken().Length -eq 0) {
            throw "Workspace original identity mismatch: $path"
        }
        $null = Assert-RiderAssemblyMarketingVersion -Path $path -ExpectedVersion $ExpectedVersion
        $result += [ordered]@{
            fileName = $name + '.dll'
            sha256 = Get-Sha256 -Path $path
            assemblyIdentity = $identity.FullName
            waveMarketingName = $ExpectedVersion
        }
    }
    return $result
}

function Get-RiderWorkspaceSourceTrees {
    param([Parameter(Mandatory)][string]$WorkspaceDirectory)
    $workspace = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $trees = @()
    foreach ($name in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
        $source = Join-Path (Join-Path $workspace $name) 'Source'
        $fingerprint = Get-TreeFingerprint -Directory $source
        $trees += [ordered]@{ project = $name; sha256 = $fingerprint.Sha256; fileCount = $fingerprint.FileCount }
    }
    return $trees
}

function Read-RiderWorkspaceState {
    param([Parameter(Mandatory)][string]$WorkspaceDirectory)
    $path = Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'workspace.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workspace state is missing: $path" }
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($null -eq $state -or $state.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$state.version) -or
        [string]::IsNullOrWhiteSpace([string]$state.build) -or
        @($state.originals).Count -ne 2 -or @($state.sourceTrees).Count -ne 2 -or
        $state.patchStatus -notin @('pristine', 'applied', 'failed')) {
        throw "Workspace state is malformed: $path"
    }
    return $state
}

function Assert-RiderWorkspaceSourceTrees {
    param([Parameter(Mandatory)][string]$WorkspaceDirectory, [Parameter(Mandatory)]$State)
    $actual = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $WorkspaceDirectory)
    foreach ($expected in @($State.sourceTrees)) {
        $matches = @($actual | Where-Object { $_.project -ceq [string]$expected.project })
        if ($matches.Count -ne 1 -or $matches[0].sha256 -cne [string]$expected.sha256 -or
            $matches[0].fileCount -ne [int]$expected.fileCount) {
            throw "Workspace source changed outside the selected patch set: $($expected.project)"
        }
    }
    return $actual
}

