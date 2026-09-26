#requires -Version 5.1
<#
.SYNOPSIS
Generates patches for both projects in a Rider workspace and optionally publishes them.
.DESCRIPTION
Runs both assembly generators concurrently. With -Publish, replaces the paired
published profile after confirmation when an existing profile differs.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceDirectory,

    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$whatIfRequested = $PSBoundParameters.ContainsKey('WhatIf') -and [bool]$PSBoundParameters['WhatIf']
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')

$projectNames = @(
    'JetBrains.ReSharper.Cpp',
    'JetBrains.ReSharper.Feature.Services.Cpp'
)

function Assert-PlainDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description cannot be a linked directory: $Path"
    }
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-PatchGenerator {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$GeneratorPath,
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string]$WorkDirectory
    )

    $command = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$ProgressPreference = 'SilentlyContinue'"
        'try {'
        ('    & {0} -WorkDir {1} 6>&1' -f (ConvertTo-PowerShellLiteral $GeneratorPath), (ConvertTo-PowerShellLiteral $WorkDirectory))
        '    if (-not $?) { exit 1 }'
        '    exit 0'
        '} catch {'
        '    [Console]::Error.WriteLine(($_ | Out-String))'
        '    exit 1'
        '}'
    ) -join "`n"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellPath
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + $encodedCommand
    $startInfo.WorkingDirectory = $WorkDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "PowerShell did not start for $ProjectName." }
        # Start both asynchronous drains before waiting so a full pipe cannot block either child.
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{
            Project = $ProjectName
            Process = $process
            StandardOutput = $standardOutput
            StandardError = $standardError
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Write-ChildText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][bool]$IsError
    )

    if ($Text.Length -eq 0) { return }
    if ($IsError) {
        [Console]::Error.Write($Text)
        if (-not $Text.EndsWith("`n", [StringComparison]::Ordinal)) { [Console]::Error.WriteLine() }
    } else {
        [Console]::Out.Write($Text)
        if (-not $Text.EndsWith("`n", [StringComparison]::Ordinal)) { [Console]::Out.WriteLine() }
    }
}

function Get-DirectoryInventory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    Assert-PlainDirectory -Path $fullRoot -Description 'Patch directory'
    $files = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[object]]::new()
    $pending.Push([pscustomobject]@{ FullName = $fullRoot; RelativePath = '' })

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $extendedDirectory = ConvertTo-ExtendedPath -Path $directory.FullName
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($extendedDirectory)) {
            $attributes = [IO.File]::GetAttributes($entry)
            $name = [IO.Path]::GetFileName($entry.TrimEnd('\'))
            $relativePath = if ($directory.RelativePath.Length -eq 0) {
                $name
            } else {
                $directory.RelativePath + '/' + $name
            }
            $normalPath = Join-Path $directory.FullName $name
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Linked entries are unsupported in patch directories: $normalPath"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push([pscustomobject]@{ FullName = $normalPath; RelativePath = $relativePath })
            } else {
                $files.Add($relativePath, [pscustomobject]@{
                    RelativePath = $relativePath
                    FullName = $normalPath
                    Sha256 = Get-Sha256 -Path $normalPath
                })
            }
        }
    }
    return ,$files
}

function Get-GeneratedProfileInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string[]]$Projects
    )

    $files = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($project in $Projects) {
        $patchDirectory = Join-Path (Join-Path $Workspace $project) 'Patches'
        $projectFiles = Get-DirectoryInventory -Root $patchDirectory
        foreach ($entry in $projectFiles.GetEnumerator()) {
            $profilePath = $project + '/' + $entry.Key
            $files.Add($profilePath, [pscustomobject]@{
                RelativePath = $profilePath
                FullName = $entry.Value.FullName
                Sha256 = $entry.Value.Sha256
            })
        }
    }
    return ,$files
}

function Get-PublishedProfileInventory {
    param([Parameter(Mandatory = $true)][string]$ProfileDirectory)

    return ,(Get-DirectoryInventory -Root $ProfileDirectory)
}

function Test-InventoryEqual {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($entry in $Left.GetEnumerator()) {
        if (-not $Right.ContainsKey($entry.Key) -or
            $entry.Value.Sha256 -cne $Right[$entry.Key].Sha256) {
            return $false
        }
    }
    return $true
}

function New-ProfileStage {
    param(
        [Parameter(Mandatory = $true)][string]$StageDirectory,
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string[]]$Projects
    )

    $null = [IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath -Path $StageDirectory))
    foreach ($project in $Projects) {
        $null = [IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath -Path (Join-Path $StageDirectory $project)))
    }
    foreach ($entry in $Inventory.GetEnumerator()) {
        $relativeWindowsPath = $entry.Key.Replace('/', '\')
        $destination = Join-Path $StageDirectory $relativeWindowsPath
        $parent = [IO.Path]::GetDirectoryName($destination)
        $null = [IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath -Path $parent))
        [IO.File]::Copy(
            (ConvertTo-ExtendedPath -Path $entry.Value.FullName),
            (ConvertTo-ExtendedPath -Path $destination),
            $false
        )
    }
}

function Publish-PatchProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)]$GeneratedInventory,
        [Parameter(Mandatory = $true)]$CommandContext,
        [Parameter(Mandatory = $true)][bool]$WhatIfRequested
    )

    $patchRoot = Join-Path (Get-PatchPackageRoot) 'Patches'
    Assert-PlainDirectory -Path $patchRoot -Description 'Repository patch root'
    $destination = Join-Path $patchRoot $ProfileName
    $destinationExists = Test-Path -LiteralPath $destination
    if ($destinationExists -and -not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw "Published patch profile is not a directory: $destination"
    }

    if ($destinationExists) {
        $publishedInventory = Get-PublishedProfileInventory -ProfileDirectory $destination
        $hasBothProjectDirectories = $true
        foreach ($project in $projectNames) {
            $projectDirectory = Join-Path $destination $project
            if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
                $hasBothProjectDirectories = $false
                continue
            }
            Assert-PlainDirectory -Path $projectDirectory -Description "Published $project patch directory"
        }
        if ($hasBothProjectDirectories -and
            (Test-InventoryEqual -Left $GeneratedInventory -Right $publishedInventory)) {
            Write-Host "Published patch profile is already identical: $destination"
            return
        }
        if (-not $CommandContext.ShouldProcess($destination, 'Atomically replace both project patch directories')) {
            return
        }
    } else {
        # A new profile is unambiguous, so publishing it never prompts. Honor -WhatIf
        # without calling ShouldProcess, which would honor an explicit -Confirm as well.
        if ($WhatIfRequested) {
            Write-Host "What if: Publishing both project patch directories to $destination"
            return
        }
    }

    $token = [Guid]::NewGuid().ToString('N')
    $stage = Join-Path $patchRoot ('.' + $ProfileName + '.' + $token + '.stage')
    $old = Join-Path $patchRoot ('.' + $ProfileName + '.' + $token + '.old')
    $oldMoved = $false
    $newMoved = $false
    try {
        New-ProfileStage -StageDirectory $stage -Inventory $GeneratedInventory -Projects $projectNames
        $stagedInventory = Get-PublishedProfileInventory -ProfileDirectory $stage
        if (-not (Test-InventoryEqual -Left $GeneratedInventory -Right $stagedInventory)) {
            throw 'Staged patch profile did not match the generated patch inventory.'
        }

        if ($destinationExists) {
            Move-DirectoryTree -Source $destination -Destination $old
            $oldMoved = $true
        }
        Move-DirectoryTree -Source $stage -Destination $destination
        $newMoved = $true
    } catch {
        $publishError = $_
        if ($newMoved -and (Test-Path -LiteralPath $destination -PathType Container)) {
            Remove-DirectoryTree -Path $destination
            $newMoved = $false
        }
        if ($oldMoved -and (Test-Path -LiteralPath $old -PathType Container)) {
            Move-DirectoryTree -Source $old -Destination $destination
            $oldMoved = $false
        }
        throw $publishError
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Container) {
            Remove-DirectoryTree -Path $stage
        }
    }

    if ($oldMoved -and (Test-Path -LiteralPath $old -PathType Container)) {
        Remove-DirectoryTree -Path $old
    }
    Write-Host "Published both project patch directories: $destination"
}

$workspace = (Resolve-Path -LiteralPath $WorkspaceDirectory -ErrorAction Stop).ProviderPath
Assert-PlainDirectory -Path $workspace -Description 'Workspace directory'
$workspaceState = Read-RiderWorkspaceState -WorkspaceDirectory $workspace
$profileName = [IO.DirectoryInfo]::new($workspace).Name
$expectedProfileName = Get-WorkspaceId -Version ([string]$workspaceState.version) -Build ([string]$workspaceState.build)
if ($profileName -cne $expectedProfileName) {
    throw "Workspace directory name '$profileName' does not match workspace state '$expectedProfileName'."
}

$generator = Join-Path $PSScriptRoot 'GeneratePatches.ps1'
if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) { throw "Patch generator is missing: $generator" }
foreach ($project in $projectNames) {
    $projectDirectory = Join-Path $workspace $project
    Assert-PlainDirectory -Path $projectDirectory -Description "$project workspace"
    $sourceDirectory = Join-Path $projectDirectory 'Source'
    Assert-PlainDirectory -Path $sourceDirectory -Description "$project source directory"
    Assert-PlainDirectory -Path (Join-Path $sourceDirectory '.git') -Description "$project Git baseline"
    $patchDirectory = Join-Path $projectDirectory 'Patches'
    if (Test-Path -LiteralPath $patchDirectory) {
        Assert-PlainDirectory -Path $patchDirectory -Description "$project patch directory"
    }
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell is missing: $windowsPowerShell"
}

$jobs = @()
$results = @()
try {
    foreach ($project in $projectNames) {
        $jobs += Start-PatchGenerator -PowerShellPath $windowsPowerShell -GeneratorPath $generator `
            -ProjectName $project -WorkDirectory (Join-Path $workspace $project)
    }
    foreach ($job in $jobs) {
        $job.Process.WaitForExit()
        $results += [pscustomobject]@{
            Project = $job.Project
            ExitCode = $job.Process.ExitCode
            StandardOutput = [string]$job.StandardOutput.Result
            StandardError = [string]$job.StandardError.Result
        }
    }
} finally {
    foreach ($job in $jobs) {
        if (-not $job.Process.HasExited) { $job.Process.WaitForExit() }
        $job.Process.Dispose()
    }
}

foreach ($result in $results) {
    Write-Host ''
    Write-Host "=== $($result.Project) ==="
    Write-ChildText -Text $result.StandardOutput -IsError $false
    Write-ChildText -Text $result.StandardError -IsError $true
    Write-Host "Exit code: $($result.ExitCode)"
}
$failures = @($results | Where-Object { $_.ExitCode -ne 0 })
if ($failures.Count -gt 0) {
    $failedNames = (($failures | ForEach-Object { $_.Project + ' (' + $_.ExitCode + ')' }) -join ', ')
    throw "Patch generation failed: $failedNames. Published patches were not changed."
}

Write-Host ''
Write-Host 'Generated patches for both projects.'
if ($Publish) {
    $generatedInventory = Get-GeneratedProfileInventory -Workspace $workspace -Projects $projectNames
    Publish-PatchProfile -ProfileName $profileName -GeneratedInventory $generatedInventory `
        -CommandContext $PSCmdlet -WhatIfRequested $whatIfRequested
}
