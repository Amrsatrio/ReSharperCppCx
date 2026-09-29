#requires -Version 5.1
<#
.SYNOPSIS
Transactionally installs or restores the paired Rider C++/CX assemblies.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Restore')]
    [string]$Action,
    [Parameter(Mandatory)]
    [string]$RiderDirectory,
    [string]$WorkspaceDirectory,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')

$rider = (Resolve-Path -LiteralPath $RiderDirectory -ErrorAction Stop).ProviderPath.TrimEnd('\')
Assert-PatchPlainPath -Path $rider
$riderInfo = Get-RiderInstallationInfo -RiderDirectory $rider -Source 'deployment'
if (-not [string]::IsNullOrWhiteSpace($riderInfo.ValidationError)) {
    throw "Rider installation validation failed: $($riderInfo.ValidationError)"
}
$recordPath = Get-RiderInstallStatePath -RiderDirectory $rider
$record = if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
    [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
} else { $null }

function Assert-RiderClosed {
    if (@(Get-Process -Name rider64, Rider.Backend, JetBrains.ReSharper.Host -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Close every Rider frontend/backend process before installation or restoration.'
    }
}

function Assert-TargetAssembly {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][string]$ExpectedIdentity,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [switch]$RequireJetBrainsSignature
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Assembly is missing: $Path" }
    $identity = [Reflection.AssemblyName]::GetAssemblyName($Path)
    if ($identity.Name -cne $ExpectedName -or $identity.FullName -cne $ExpectedIdentity) {
        throw "Assembly identity mismatch: $Path"
    }
    $null = Assert-RiderAssemblyMarketingVersion -Path $Path -ExpectedVersion $ExpectedVersion
    if ($RequireJetBrainsSignature) { Assert-JetBrainsSignature -Path $Path }
}

function Get-CanonicalTargetDirectories {
    param([Parameter(Mandatory)]$Originals)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hostDirectory = Join-Path $rider 'lib\ReSharperHost'
    $null = $directories.Add($hostDirectory)
    $cacheRoots = @(
        (Join-Path $rider 'r2r'),
        (Join-Path ([IO.Path]::GetDirectoryName($rider)) 'Rider\r2r')
    )
    foreach ($cacheRoot in $cacheRoots) {
        if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) { continue }
        foreach ($engine in @(Get-ChildItem -LiteralPath $cacheRoot -File -Filter 'JetBrains.ReSharper.Cpp.dll' -Recurse -ErrorAction Stop)) {
            $feature = Join-Path $engine.DirectoryName 'JetBrains.ReSharper.Feature.Services.Cpp.dll'
            if (-not (Test-Path -LiteralPath $feature -PathType Leaf)) { continue }
            if ((Get-Sha256 $engine.FullName) -ceq $Originals['JetBrains.ReSharper.Cpp.dll'].sha256 -and
                (Get-Sha256 $feature) -ceq $Originals['JetBrains.ReSharper.Feature.Services.Cpp.dll'].sha256) {
                $null = $directories.Add($engine.DirectoryName)
            }
        }
    }
    return @($directories | Sort-Object)
}

function Get-RecordlessRestoreDirectories {
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $roots = @(
        (Join-Path $rider 'lib\ReSharperHost'),
        (Join-Path $rider 'r2r'),
        (Join-Path ([IO.Path]::GetDirectoryName($rider)) 'Rider\r2r')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($backup in @(Get-ChildItem -LiteralPath $root -File -Filter 'JetBrains.ReSharper.Cpp.bak.dll' -Recurse -ErrorAction Stop)) {
            $featureBackup = Join-Path $backup.DirectoryName 'JetBrains.ReSharper.Feature.Services.Cpp.bak.dll'
            if (Test-Path -LiteralPath $featureBackup -PathType Leaf) { $null = $directories.Add($backup.DirectoryName) }
        }
    }
    return @($directories | Sort-Object)
}

function Remove-InstallRecord {
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return }
    [IO.File]::Delete($recordPath)
    $directory = [IO.Path]::GetDirectoryName($recordPath)
    if ([IO.Directory]::Exists($directory) -and [IO.Directory]::GetFileSystemEntries($directory).Length -eq 0) {
        [IO.Directory]::Delete($directory)
    }
}

Assert-RiderClosed
$entries = @()
$artifacts = @{}
$workspace = $null
$buildDirectory = $null

if ($Action -ceq 'Install') {
    if ([string]::IsNullOrWhiteSpace($WorkspaceDirectory)) { throw '-WorkspaceDirectory is required for Install.' }
    $workspace = (Resolve-Path -LiteralPath $WorkspaceDirectory -ErrorAction Stop).ProviderPath
    $workspaceStatePath = Join-Path $workspace 'workspace.json'
    $workspaceStateHash = Get-Sha256 $workspaceStatePath
    $workspaceState = Read-RiderWorkspaceState -WorkspaceDirectory $workspace
    if ($workspaceState.patchStatus -cne 'applied' -or $workspaceState.version -cne $riderInfo.Version -or
        $workspaceState.build -cne $riderInfo.Build) {
        throw 'Workspace Rider version/build does not match the deployment target.'
    }
    $null = Assert-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace -State $workspaceState
    $buildDirectory = Join-Path (Join-Path $workspace 'Build') $Configuration
    $buildPath = Join-Path $buildDirectory 'build.json'
    if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) { throw "Published build is missing: $buildPath" }
    $build = [IO.File]::ReadAllText($buildPath) | ConvertFrom-Json
    if ($build.schemaVersion -ne 1 -or $build.version -cne $riderInfo.Version -or $build.build -cne $riderInfo.Build -or
        $build.configuration -cne $Configuration -or $build.workspaceStateSha256 -cne $workspaceStateHash -or
        $build.patchSet -cne $workspaceState.patchSet -or $build.patchSetSha256 -cne $workspaceState.patchSetSha256) {
        throw 'Published build metadata does not match the prepared workspace.'
    }
    foreach ($artifact in @($build.artifacts)) {
        if ($artifact.fileName -notin @('JetBrains.ReSharper.Cpp.dll', 'JetBrains.ReSharper.Feature.Services.Cpp.dll') -or
            $artifact.builtSha256 -cnotmatch '^[0-9a-f]{64}$' -or $artifact.sourceOriginalSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Published artifact metadata is malformed.'
        }
        $path = Join-Path $buildDirectory $artifact.fileName
        Assert-TargetAssembly -Path $path -ExpectedName ([IO.Path]::GetFileNameWithoutExtension($artifact.fileName)) `
            -ExpectedIdentity $artifact.assemblyIdentity -ExpectedVersion $riderInfo.Version
        if ((Get-Sha256 $path) -cne $artifact.builtSha256) { throw "Published artifact hash mismatch: $path" }
        $artifacts[$artifact.fileName] = [pscustomobject]@{
            Metadata = $artifact
            Path = $path
            sha256 = [string]$artifact.sourceOriginalSha256
        }
    }
    if ($artifacts.Count -ne 2) { throw 'Published build must contain exactly two artifacts.' }

    if ($null -ne $record) {
        if ($record.schemaVersion -ne 1 -or $record.riderDirectory -ine $rider -or
            $record.version -cne $riderInfo.Version -or $record.build -cne $riderInfo.Build) {
            throw "Installation record does not match Rider: $recordPath"
        }
        $targetRows = @($record.targets)
    }
    else {
        $targetRows = @()
        foreach ($directory in (Get-CanonicalTargetDirectories -Originals $artifacts)) {
            foreach ($fileName in @('JetBrains.ReSharper.Cpp.dll', 'JetBrains.ReSharper.Feature.Services.Cpp.dll')) {
                $targetRows += [pscustomobject]@{
                    destination = Join-Path $directory $fileName
                    backup = Join-Path $directory ([IO.Path]::GetFileNameWithoutExtension($fileName) + '.bak.dll')
                    originalSha256 = $artifacts[$fileName].Metadata.sourceOriginalSha256
                    installedSha256 = $artifacts[$fileName].Metadata.builtSha256
                    assemblyIdentity = $artifacts[$fileName].Metadata.assemblyIdentity
                    waveMarketingName = $riderInfo.Version
                }
            }
        }
    }
    if ($targetRows.Count -lt 2 -or ($targetRows.Count % 2) -ne 0) { throw 'Installation target set is incomplete.' }
    foreach ($target in $targetRows) {
        $fileName = [IO.Path]::GetFileName([string]$target.destination)
        $artifact = $artifacts[$fileName]
        if ($null -eq $artifact -or [string]$target.originalSha256 -cne $artifact.Metadata.sourceOriginalSha256 -or
            [string]$target.assemblyIdentity -cne $artifact.Metadata.assemblyIdentity -or
            [string]$target.waveMarketingName -cne $riderInfo.Version) {
            throw "Installation target metadata mismatch: $($target.destination)"
        }
        $destination = [IO.Path]::GetFullPath([string]$target.destination)
        $backup = [IO.Path]::GetFullPath([string]$target.backup)
        $currentHash = Get-Sha256 $destination
        $mode = 'fresh'
        $preserveCurrent = $false
        if ($null -ne $record) {
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Original backup is missing: $backup" }
            Assert-TargetAssembly -Path $backup -ExpectedName ([IO.Path]::GetFileNameWithoutExtension($fileName)) `
                -ExpectedIdentity $target.assemblyIdentity -ExpectedVersion $riderInfo.Version -RequireJetBrainsSignature
            if ((Get-Sha256 $backup) -cne $target.originalSha256) { throw "Original backup hash mismatch: $backup" }
            if ($currentHash -cne $target.installedSha256 -and $currentHash -cne $artifact.Metadata.builtSha256) {
                Assert-TargetAssembly -Path $destination -ExpectedName ([IO.Path]::GetFileNameWithoutExtension($fileName)) `
                    -ExpectedIdentity $target.assemblyIdentity -ExpectedVersion $riderInfo.Version
                $preserveCurrent = $true
            }
            $mode = if ($currentHash -ceq $artifact.Metadata.builtSha256) { 'noop' } else { 'update' }
        }
        else {
            if (Test-Path -LiteralPath $backup) { throw "Unrecorded backup already exists: $backup" }
            Assert-TargetAssembly -Path $destination -ExpectedName ([IO.Path]::GetFileNameWithoutExtension($fileName)) `
                -ExpectedIdentity $target.assemblyIdentity -ExpectedVersion $riderInfo.Version -RequireJetBrainsSignature
            if ($currentHash -cne $target.originalSha256) { throw "Original DLL hash mismatch: $destination" }
        }
        $id = [Guid]::NewGuid().ToString('N')
        $base = [IO.Path]::GetFileNameWithoutExtension($destination)
        $entries += [pscustomobject]@{
            Path = $destination
            Backup = $backup
            Stage = Join-Path ([IO.Path]::GetDirectoryName($destination)) ($base + '.' + $id + '.stage.dll')
            Rollback = Join-Path ([IO.Path]::GetDirectoryName($destination)) ($base + '.' + $id + '.rollback.dll')
            Mode = $mode
            Artifact = $artifact
            OriginalHash = [string]$target.originalSha256
            InstalledHash = [string]$artifact.Metadata.builtSha256
            CurrentHash = $currentHash
            PreserveCurrent = $preserveCurrent
            Identity = [string]$target.assemblyIdentity
            BackupCreated = $false
            Replaced = $false
        }
    }
}
else {
    if ($null -ne $record) {
        if ($record.schemaVersion -ne 1 -or $record.riderDirectory -ine $rider -or
            $record.version -cne $riderInfo.Version -or $record.build -cne $riderInfo.Build) {
            throw "Installation record does not match current Rider: $recordPath"
        }
        $targetRows = @($record.targets)
    }
    else {
        $targetRows = @()
        foreach ($directory in (Get-RecordlessRestoreDirectories)) {
            foreach ($fileName in @('JetBrains.ReSharper.Cpp.dll', 'JetBrains.ReSharper.Feature.Services.Cpp.dll')) {
                $destination = Join-Path $directory $fileName
                $backup = Join-Path $directory ([IO.Path]::GetFileNameWithoutExtension($fileName) + '.bak.dll')
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    throw "Recordless restore pair is incomplete: $directory"
                }
                $identity = [Reflection.AssemblyName]::GetAssemblyName($backup)
                $targetRows += [pscustomobject]@{
                    destination = $destination
                    backup = $backup
                    originalSha256 = Get-Sha256 $backup
                    installedSha256 = Get-Sha256 $destination
                    assemblyIdentity = $identity.FullName
                    waveMarketingName = $riderInfo.Version
                }
            }
        }
    }
    if ($targetRows.Count -lt 2 -or ($targetRows.Count % 2) -ne 0) { throw 'No complete Rider C++/CX backup pair is available to restore.' }
    foreach ($target in $targetRows) {
        $destination = [IO.Path]::GetFullPath([string]$target.destination)
        $backup = [IO.Path]::GetFullPath([string]$target.backup)
        $fileName = [IO.Path]::GetFileName($destination)
        $name = [IO.Path]::GetFileNameWithoutExtension($fileName)
        Assert-TargetAssembly -Path $backup -ExpectedName $name -ExpectedIdentity $target.assemblyIdentity `
            -ExpectedVersion $riderInfo.Version -RequireJetBrainsSignature
        if ((Get-Sha256 $backup) -cne $target.originalSha256) { throw "Original backup hash mismatch: $backup" }
        Assert-TargetAssembly -Path $destination -ExpectedName $name -ExpectedIdentity $target.assemblyIdentity `
            -ExpectedVersion $riderInfo.Version
        $currentHash = Get-Sha256 $destination
        $preserveCurrent = $false
        if ($currentHash -cne $target.installedSha256 -and $currentHash -cne $target.originalSha256) {
            $preserveCurrent = $true
        }
        $id = [Guid]::NewGuid().ToString('N')
        $base = [IO.Path]::GetFileNameWithoutExtension($destination)
        $entries += [pscustomobject]@{
            Path = $destination
            Backup = $backup
            Stage = Join-Path ([IO.Path]::GetDirectoryName($destination)) ($base + '.' + $id + '.stage.dll')
            Rollback = Join-Path ([IO.Path]::GetDirectoryName($destination)) ($base + '.' + $id + '.rollback.dll')
            Mode = $(if ($currentHash -ceq $target.originalSha256) { 'noop' } else { 'restore' })
            OriginalHash = [string]$target.originalSha256
            InstalledHash = [string]$target.installedSha256
            CurrentHash = $currentHash
            PreserveCurrent = $preserveCurrent
            Identity = [string]$target.assemblyIdentity
            BackupCreated = $false
            Replaced = $false
        }
    }
}

$description = if ($Action -ceq 'Install') { 'Install paired C++/CX assemblies' } else { 'Restore JetBrains-signed Rider assemblies' }
if (-not $PSCmdlet.ShouldProcess(($entries.Path -join ', '), $description)) {
    Write-Host "$description validation succeeded; no files changed."
    return
}

$committed = $false
$recoveryDirectory = $null
try {
    $preservedEntries = @($entries | Where-Object { $_.PreserveCurrent })
    if ($preservedEntries.Count -gt 0) {
        $recoveryDirectory = Join-Path ([IO.Path]::GetDirectoryName($recordPath)) `
            (Join-Path 'Recovery' ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')))
        [IO.Directory]::CreateDirectory($recoveryDirectory) | Out-Null
        [IO.File]::Copy($recordPath, (Join-Path $recoveryDirectory 'install.json'), $false)
        $recoveryTargets = @()
        for ($index = 0; $index -lt $preservedEntries.Count; ++$index) {
            $entry = $preservedEntries[$index]
            $recoveryFile = '{0:D3}-{1}' -f $index, [IO.Path]::GetFileName($entry.Path)
            $recoveryPath = Join-Path $recoveryDirectory $recoveryFile
            [IO.File]::Copy($entry.Path, $recoveryPath, $false)
            if ((Get-Sha256 $recoveryPath) -cne $entry.CurrentHash) {
                throw "Recovery copy hash mismatch: $recoveryPath"
            }
            $recoveryTargets += [ordered]@{
                source = $entry.Path
                sha256 = $entry.CurrentHash
                recoveryFile = $recoveryFile
            }
        }
        Write-AtomicPatchJson -Path (Join-Path $recoveryDirectory 'recovery.json') -Value ([ordered]@{
            schemaVersion = 1
            riderDirectory = $rider
            version = $riderInfo.Version
            build = $riderInfo.Build
            createdUtc = [DateTime]::UtcNow.ToString('o')
            reason = 'unrecordedInstalledAssemblies'
            targets = $recoveryTargets
        })
        Write-Warning "Installed assemblies differ from the installation record. Preserved them in: $recoveryDirectory"
    }
    foreach ($entry in $entries) {
        if ($entry.Mode -eq 'noop') { continue }
        $inputPath = if ($Action -ceq 'Install') { $entry.Artifact.Path } else { $entry.Backup }
        [IO.File]::Copy($inputPath, $entry.Stage, $false)
        $expectedHash = if ($Action -ceq 'Install') { $entry.InstalledHash } else { $entry.OriginalHash }
        if ((Get-Sha256 $entry.Stage) -cne $expectedHash) { throw "Staged DLL hash mismatch: $($entry.Stage)" }
    }
    Assert-RiderClosed
    foreach ($entry in $entries) {
        if ($entry.Mode -eq 'noop') { continue }
        if ($entry.Mode -eq 'fresh') {
            [IO.File]::Move($entry.Path, $entry.Backup)
            $entry.BackupCreated = $true
            [IO.File]::Move($entry.Stage, $entry.Path)
        }
        else {
            [IO.File]::Replace($entry.Stage, $entry.Path, $entry.Rollback)
        }
        $entry.Replaced = $true
        $expectedHash = if ($Action -ceq 'Install') { $entry.InstalledHash } else { $entry.OriginalHash }
        if ((Get-Sha256 $entry.Path) -cne $expectedHash) { throw "Installed DLL verification failed: $($entry.Path)" }
    }
    if ($Action -ceq 'Install') {
        $targetState = @(
            foreach ($entry in $entries) {
                [ordered]@{
                    destination = $entry.Path
                    backup = $entry.Backup
                    originalSha256 = $entry.OriginalHash
                    installedSha256 = $entry.InstalledHash
                    assemblyIdentity = $entry.Identity
                    waveMarketingName = $riderInfo.Version
                }
            }
        )
        Write-AtomicPatchJson -Path $recordPath -Value ([ordered]@{
            schemaVersion = 1
            riderDirectory = $rider
            version = $riderInfo.Version
            build = $riderInfo.Build
            patchSet = (Read-RiderWorkspaceState $workspace).patchSet
            targets = $targetState
        })
    }
    $committed = $true
}
catch {
    $failure = $_
    for ($index = $entries.Count - 1; $index -ge 0; --$index) {
        $entry = $entries[$index]
        try {
            if ($entry.Replaced) {
                if (Test-Path -LiteralPath $entry.Rollback -PathType Leaf) {
                    if (Test-Path -LiteralPath $entry.Path) { [IO.File]::Delete($entry.Path) }
                    [IO.File]::Move($entry.Rollback, $entry.Path)
                }
                elseif ($entry.BackupCreated -and (Test-Path -LiteralPath $entry.Backup -PathType Leaf)) {
                    if (Test-Path -LiteralPath $entry.Path) { [IO.File]::Delete($entry.Path) }
                    [IO.File]::Move($entry.Backup, $entry.Path)
                }
            }
        }
        catch { Write-Warning "DLL rollback failed. Recover with $($entry.Rollback) or $($entry.Backup): $_" }
    }
    if ($Action -ceq 'Install' -and (Test-Path -LiteralPath $recordPath)) {
        try { Remove-InstallRecord } catch { Write-Warning "Could not remove failed installation record: $_" }
    }
    throw $failure
}
finally {
    foreach ($entry in $entries) {
        if (Test-Path -LiteralPath $entry.Stage) { [IO.File]::Delete($entry.Stage) }
        if ($committed -and (Test-Path -LiteralPath $entry.Rollback)) { [IO.File]::Delete($entry.Rollback) }
    }
}

if ($Action -ceq 'Restore') {
    $cleanupFailed = $false
    foreach ($entry in $entries) {
        try {
            Assert-TargetAssembly -Path $entry.Path -ExpectedName ([IO.Path]::GetFileNameWithoutExtension($entry.Path)) `
                -ExpectedIdentity $entry.Identity -ExpectedVersion $riderInfo.Version -RequireJetBrainsSignature
            if ((Get-Sha256 $entry.Path) -cne $entry.OriginalHash) { throw "Restored hash mismatch: $($entry.Path)" }
            if (Test-Path -LiteralPath $entry.Backup) { [IO.File]::Delete($entry.Backup) }
        }
        catch {
            $cleanupFailed = $true
            Write-Warning $_
        }
    }
    if (-not $cleanupFailed) { Remove-InstallRecord }
    else { throw 'Rider DLLs were restored, but backup cleanup was incomplete. Do not update Rider yet.' }
}

Write-Host "$description completed."
if (-not [string]::IsNullOrWhiteSpace($recoveryDirectory)) {
    Write-Host "Previous unrecorded assemblies: $recoveryDirectory"
}
foreach ($entry in $entries) { Write-Host "$($entry.Path) SHA256: $(Get-Sha256 $entry.Path)" }
