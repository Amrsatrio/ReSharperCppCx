#requires -Version 5.1
<#
.SYNOPSIS
Builds and publishes the paired Rider C++/CX assemblies from a prepared workspace.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceDirectory,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')

$workspace = (Resolve-Path -LiteralPath $WorkspaceDirectory -ErrorAction Stop).ProviderPath
Assert-PatchPlainPath -Path $workspace
$statePath = Join-Path $workspace 'workspace.json'
$stateHash = Get-Sha256 -Path $statePath
$state = Read-RiderWorkspaceState -WorkspaceDirectory $workspace
if ($state.patchStatus -cne 'applied' -or $state.patchMode -cne 'All' -or
    [string]::IsNullOrWhiteSpace([string]$state.patchSet) -or
    [string]$state.patchSetSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Workspace must contain one completely applied patch set before building.'
}
$beforeTrees = @(Assert-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace -State $state)
$solutions = @(Get-ChildItem -LiteralPath $workspace -File -Filter '*.slnx')
if ($solutions.Count -ne 1) { throw "Expected exactly one combined solution in $workspace." }

$sdk = Invoke-PatchNative -FilePath dotnet -Arguments @('--version') -WorkingDirectory $workspace -Quiet
if ($sdk.StdOut.Trim() -notmatch '^(\d+)\.' -or [int]$Matches[1] -lt 10) {
    throw '.NET SDK 10 or newer is required.'
}
$null = Invoke-PatchNative -FilePath dotnet -Arguments @(
    'build', $solutions[0].FullName,
    '--configuration', $Configuration,
    '--verbosity', 'minimal',
    '--no-incremental'
) -WorkingDirectory $workspace

$originals = @{}
foreach ($original in @($state.originals)) { $originals[[string]$original.fileName] = $original }
$artifacts = @()
$artifactSources = @{}
foreach ($name in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
    $fileName = $name + '.dll'
    $path = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $workspace $name) 'Source') 'bin') $Configuration) (Join-Path 'net48' $fileName)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Build output is missing: $path" }
    $expected = $originals[$fileName]
    if ($null -eq $expected) { throw "Workspace original metadata is missing: $fileName" }
    $identity = [Reflection.AssemblyName]::GetAssemblyName($path)
    if ($identity.FullName -cne [string]$expected.assemblyIdentity) {
        throw "Built assembly identity mismatch: $path"
    }
    $null = Assert-RiderAssemblyMarketingVersion -Path $path -ExpectedVersion ([string]$state.version)
    $hash = Get-Sha256 -Path $path
    $artifacts += [ordered]@{
        fileName = $fileName
        sourceOriginalSha256 = [string]$expected.sha256
        builtSha256 = $hash
        assemblyIdentity = $identity.FullName
        waveMarketingName = [string]$state.version
    }
    $artifactSources[$fileName] = $path
}

$afterTrees = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace)
foreach ($before in $beforeTrees) {
    $matches = @($afterTrees | Where-Object { $_.project -ceq $before.project })
    if ($matches.Count -ne 1 -or $matches[0].sha256 -cne $before.sha256 -or
        $matches[0].fileCount -ne $before.fileCount) {
        throw "Source changed during build: $($before.project)"
    }
}
if ((Get-Sha256 -Path $statePath) -cne $stateHash) { throw 'Workspace state changed during build.' }

$buildRoot = Join-Path $workspace 'Build'
$null = [IO.Directory]::CreateDirectory($buildRoot)
$destination = Join-Path $buildRoot $Configuration
$stage = Join-Path $buildRoot ('.publish-' + [Guid]::NewGuid().ToString('N'))
$old = $null
try {
    $null = [IO.Directory]::CreateDirectory($stage)
    foreach ($artifact in $artifacts) {
        $source = $artifactSources[$artifact.fileName]
        [IO.File]::Copy($source, (Join-Path $stage $artifact.fileName), $false)
        $pdb = [IO.Path]::ChangeExtension($source, '.pdb')
        if (Test-Path -LiteralPath $pdb -PathType Leaf) {
            [IO.File]::Copy($pdb, (Join-Path $stage ([IO.Path]::GetFileName($pdb))), $false)
        }
    }
    Write-PatchJson -Path (Join-Path $stage 'build.json') -Value ([ordered]@{
        schemaVersion = 1
        version = [string]$state.version
        build = [string]$state.build
        patchSet = [string]$state.patchSet
        patchSetSha256 = [string]$state.patchSetSha256
        configuration = $Configuration
        workspaceStateSha256 = $stateHash
        sourceTrees = $beforeTrees
        artifacts = $artifacts
    })
    foreach ($artifact in $artifacts) {
        $published = Join-Path $stage $artifact.fileName
        if ((Get-Sha256 $published) -cne $artifact.builtSha256) { throw "Published artifact verification failed: $published" }
    }
    if (Test-Path -LiteralPath $destination) {
        $old = Join-Path $buildRoot ('.old-' + [Guid]::NewGuid().ToString('N'))
        Move-DirectoryTree -Source $destination -Destination $old
    }
    try { Move-DirectoryTree -Source $stage -Destination $destination }
    catch {
        if ($null -ne $old -and -not (Test-Path -LiteralPath $destination)) {
            Move-DirectoryTree -Source $old -Destination $destination
            $old = $null
        }
        throw
    }
    if ($null -ne $old) {
        Remove-DirectoryTree -Path $old
        $old = $null
    }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-DirectoryTree -Path $stage }
    if ($null -ne $old -and (Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $destination)) {
        Move-DirectoryTree -Source $old -Destination $destination
    }
}

Write-Host "Published paired build: $destination"
foreach ($artifact in $artifacts) {
    Write-Host "$($artifact.fileName) SHA256: $($artifact.builtSha256)"
}
