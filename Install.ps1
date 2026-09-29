#requires -Version 5.1
<#
.SYNOPSIS
Prepares, builds, installs, or restores Rider C++/CX support.
.DESCRIPTION
With no arguments, opens a numbered console workflow. Use -NonInteractive with
explicit parameters for automation. Rider installation versions always come from
product-info.json; registry metadata is discovery-only.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('List', 'Prepare', 'Build', 'Install', 'Restore')]
    [string]$Action,
    [string]$RiderDirectory,
    [string]$DownloadVersion,
    [ValidateSet('All', 'None')]
    [string]$PatchMode = 'All',
    [string]$PatchSet = 'Auto',
    [switch]$IncludePrerelease,
    [string]$WorkRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$ResetWorkspace,
    [switch]$AllowUacPrompt,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scripts = Join-Path $PSScriptRoot 'Scripts'
. (Join-Path $scripts 'Patch.Common.ps1')
Add-Type -AssemblyName System.Net.Http

if (-not $PSBoundParameters.ContainsKey('WorkRoot')) { $WorkRoot = Join-Path $PSScriptRoot 'Work' }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$interactiveLaunch = [string]::IsNullOrWhiteSpace($Action)

function Assert-WorkflowPrerequisites {
    param([Parameter(Mandatory)][string]$RequestedAction)
    if ($RequestedAction -in @('List', 'Restore')) { return }
    $null = Get-Command git -CommandType Application -ErrorAction Stop
    $dotnet = Invoke-PatchNative -FilePath dotnet -Arguments @('--version') -WorkingDirectory $PSScriptRoot -Quiet
    if ($dotnet.StdOut.Trim() -notmatch '^(\d+)\.' -or [int]$Matches[1] -lt 10) {
        throw '.NET SDK 10 or newer is required.'
    }
}

function Show-RiderInstallations {
    param([Parameter(Mandatory)][object[]]$Installations)
    Write-Host ''
    Write-Host 'Detected Rider installations:'
    if ($Installations.Count -eq 0) {
        Write-Host '  (none)'
        return
    }
    for ($index = 0; $index -lt $Installations.Count; ++$index) {
        $item = $Installations[$index]
        Write-Host ('  [{0}] Rider {1} ({2}) [{3}]' -f ($index + 1), $item.Version, $item.Build, $item.InstallStatus)
        Write-Host "      $($item.RiderDirectory)"
        if (-not [string]::IsNullOrWhiteSpace($item.ValidationError)) {
            Write-Host "      ERROR: $($item.ValidationError)" -ForegroundColor Red
        }
    }
}

function Select-RiderInstallation {
    param([object[]]$Installations, [string]$ExplicitPath)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $explicit = Get-RiderInstallationInfo -RiderDirectory $ExplicitPath -Source 'explicit'
        return $explicit
    }
    if ($NonInteractive) { throw '-RiderDirectory is required in non-interactive mode.' }
    Show-RiderInstallations -Installations $Installations
    $selection = Read-Host 'Select installation number or M for another folder'
    if ($selection -ieq 'M') {
        $manual = Read-Host 'Rider installation folder'
        return Get-RiderInstallationInfo -RiderDirectory $manual -Source 'manual'
    }
    [int]$number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $Installations.Count) {
        throw "Invalid Rider selection: $selection"
    }
    return $Installations[$number - 1]
}

function Get-OnlineReleaseSelection {
    param([string]$Identifier)
    $client = New-RiderHttpClient -UserAgent 'ReSharperCppCx-Workflow/1.0'
    try { $catalog = @(Get-RiderCatalog -Client $client) }
    finally { $client.Dispose() }
    if (-not [string]::IsNullOrWhiteSpace($Identifier)) {
        $release = Resolve-RiderCatalogRelease -Catalog $catalog -Identifier $Identifier
        if ($release.Type -in @('eap', 'rc') -and -not $IncludePrerelease) {
            throw "Rider $($release.Version) is prerelease; specify -IncludePrerelease."
        }
        if (-not $release.WindowsZipAvailable) { throw "windowsZip is unavailable for Rider $($release.Version)." }
        return $release
    }
    if ($NonInteractive) { throw '-DownloadVersion is required for online preparation in non-interactive mode.' }
    $include = Read-Host 'Include EAP and RC releases? [y/N]'
    $allowPrerelease = $include -match '^(?i:y|yes)$'
    $prefix = Read-Host 'Version/build prefix [blank for newest 20]'
    $matches = @($catalog | Where-Object {
        ($_.Type -ceq 'release' -or $allowPrerelease) -and $_.WindowsZipAvailable -and
        ([string]::IsNullOrWhiteSpace($prefix) -or
            $_.Version.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $_.Build.StartsWith($prefix, [StringComparison]::Ordinal))
    } | Select-Object -First 20)
    if ($matches.Count -eq 0) { throw 'No matching online Rider releases have a Windows x64 ZIP.' }
    Write-Host ''
    for ($index = 0; $index -lt $matches.Count; ++$index) {
        Write-Host ('  [{0}] {1} ({2}) [{3}]' -f ($index + 1), $matches[$index].Version, $matches[$index].Build, $matches[$index].Type)
    }
    $selection = Read-Host 'Select online release'
    [int]$number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $matches.Count) {
        throw "Invalid online Rider selection: $selection"
    }
    return $matches[$number - 1]
}

function Get-WorkspaceRequest {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$SelectedPatchMode,
        [Parameter(Mandatory)][string]$SelectedPatchSet
    )
    $sets = @(Get-RiderPatchSets -PatchRoot (Join-Path $PSScriptRoot 'Patches'))
    $resolution = $null
    if ($SelectedPatchMode -ceq 'All') {
        $resolution = Resolve-RiderPatchSet -PatchSets $sets -TargetBuild $Source.Build -Selection $SelectedPatchSet
        if (-not $resolution.IsExact) {
            Write-Host "Using preceding patch set $($resolution.PatchSet.Name) for Rider $($Source.Version) ($($Source.Build))." -ForegroundColor Yellow
        }
        if ($resolution.IsNewer) {
            Write-Host "Selected patch set $($resolution.PatchSet.Name) is newer than Rider $($Source.Build)." -ForegroundColor Yellow
            if (-not $NonInteractive) {
                if ((Read-Host 'Continue with this explicit newer patch set? [y/N]') -notmatch '^(?i:y|yes)$') {
                    throw 'Patch selection cancelled.'
                }
            }
        }
    }
    return [pscustomobject]@{ Source = $Source; PatchMode = $SelectedPatchMode; Resolution = $resolution }
}

function Assert-ReusableWorkspace {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)]$Request,
        [switch]$ApprovePatchRefresh
    )
    $state = Read-RiderWorkspaceState -WorkspaceDirectory $Workspace
    $expectedPatchSet = if ($null -eq $Request.Resolution) { $null } else { $Request.Resolution.PatchSet.Name }
    $expectedPatchHash = if ($null -eq $Request.Resolution) { $null } else { $Request.Resolution.PatchSet.Sha256 }
    $disposition = Get-RiderWorkspaceDisposition -State $state -ExpectedVersion $Request.Source.Version `
        -ExpectedBuild $Request.Source.Build -ExpectedPatchMode $Request.PatchMode `
        -ExpectedPatchSet $expectedPatchSet -ExpectedPatchSetSha256 $expectedPatchHash
    if ($disposition -ceq 'Incompatible') {
        throw "Existing workspace belongs to another source or patch mode: $Workspace. Use -ResetWorkspace."
    }
    if ($state.patchStatus -ceq 'failed') {
        throw "Patch application previously failed; retained workspace: $Workspace`n$($state.patchError)"
    }
    if ($Request.PatchMode -ceq 'All' -and $state.patchStatus -cne 'applied') {
        throw "Existing workspace is not fully patched: $Workspace. Use -ResetWorkspace."
    }
    $currentOriginals = @(Get-RiderWorkspaceOriginals -WorkspaceDirectory $Workspace -ExpectedVersion $state.version)
    foreach ($expected in @($state.originals)) {
        $matches = @($currentOriginals | Where-Object { $_.fileName -ceq $expected.fileName })
        if ($matches.Count -ne 1 -or $matches[0].sha256 -cne $expected.sha256 -or
            $matches[0].assemblyIdentity -cne $expected.assemblyIdentity -or
            $matches[0].waveMarketingName -cne $expected.waveMarketingName) {
            throw "Workspace original changed: $($expected.fileName)"
        }
    }
    if ($disposition -ceq 'PatchRefreshRequired') {
        Assert-RiderWorkspaceRefreshSafe -WorkspaceDirectory $Workspace -State $state
        if (-not $NonInteractive -and -not $ApprovePatchRefresh) {
            Write-Host ''
            Write-Host "The selected patch set changed from $($state.patchSet) to $expectedPatchSet."
            Write-Host 'Refreshing resets both generated source repositories. Local changes were checked and none were found.'
            if ((Read-Host 'Refresh the generated workspace? [y/N]') -notmatch '^(?i:y|yes)$') {
                throw 'Workspace refresh cancelled.'
            }
        }
        & (Join-Path $scripts 'Reapply-ReSharperCppCxPatches.ps1') -WorkspaceDirectory $Workspace `
            -PatchSetName $expectedPatchSet -Confirm:$false
        $state = Read-RiderWorkspaceState -WorkspaceDirectory $Workspace
        $disposition = Get-RiderWorkspaceDisposition -State $state -ExpectedVersion $Request.Source.Version `
            -ExpectedBuild $Request.Source.Build -ExpectedPatchMode $Request.PatchMode `
            -ExpectedPatchSet $expectedPatchSet -ExpectedPatchSetSha256 $expectedPatchHash
        if ($disposition -cne 'Reusable' -or $state.patchStatus -cne 'applied') {
            throw "Refreshed workspace does not match the selected patch set: $Workspace"
        }
        return $state
    }
    $null = Assert-RiderWorkspaceSourceTrees -WorkspaceDirectory $Workspace -State $state
    return $state
}

function Initialize-WorkflowWorkspace {
    param([Parameter(Mandatory)]$Request, [switch]$ApprovePatchRefresh)
    $workspace = Get-RiderWorkspaceDirectory -WorkRoot $WorkRoot -Version $Request.Source.Version -Build $Request.Source.Build
    if ($ResetWorkspace -and (Test-Path -LiteralPath $workspace)) {
        if (-not $PSCmdlet.ShouldProcess($workspace, 'Delete and recreate the entire generated workspace')) {
            throw 'Workspace reset cancelled.'
        }
        Remove-DirectoryTree -Path $workspace
    }
    if (Test-Path -LiteralPath $workspace -PathType Container) {
        Write-RiderWorkspaceRunConfigurations -WorkspaceDirectory $workspace
        $state = Assert-ReusableWorkspace -Workspace $workspace -Request $Request -ApprovePatchRefresh:$ApprovePatchRefresh
        return [pscustomobject]@{ Directory = $workspace; State = $state }
    }
    $null = [IO.Directory]::CreateDirectory($WorkRoot)
    if ($Request.Source.Kind -ceq 'installed') {
        & (Join-Path $scripts 'Setup-ReSharperCppCx.ps1') -RiderDirectory $Request.Source.RiderDirectory -WorkRoot $WorkRoot
    }
    else {
        & (Join-Path $scripts 'Setup-ReSharperCppCx.ps1') -DownloadVersion $Request.Source.Version -WorkRoot $WorkRoot
    }
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { throw "Setup did not create workspace: $workspace" }
    $originals = @(Get-RiderWorkspaceOriginals -WorkspaceDirectory $workspace -ExpectedVersion $Request.Source.Version)
    $sourceTrees = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace)
    $patchSetName = if ($null -eq $Request.Resolution) { $null } else { $Request.Resolution.PatchSet.Name }
    $patchSetHash = if ($null -eq $Request.Resolution) { $null } else { $Request.Resolution.PatchSet.Sha256 }
    $state = [ordered]@{
        schemaVersion = 1
        version = $Request.Source.Version
        build = $Request.Source.Build
        sourceKind = $Request.Source.Kind
        sourceRiderDirectory = $(if ($Request.Source.Kind -ceq 'installed') { $Request.Source.RiderDirectory } else { $null })
        originals = $originals
        patchMode = $Request.PatchMode
        patchSet = $patchSetName
        patchSetSha256 = $patchSetHash
        patchStatus = 'pristine'
        patchError = $null
        failedPatches = @()
        sourceTrees = $sourceTrees
    }
    Write-AtomicPatchJson -Path (Join-Path $workspace 'workspace.json') -Value $state
    Write-RiderWorkspaceRunConfigurations -WorkspaceDirectory $workspace
    if ($Request.PatchMode -ceq 'All') {
        $null = Invoke-RiderPatchSet -WorkspaceDirectory $workspace -PatchSetDirectory $Request.Resolution.PatchSet.Directory
    }
    return [pscustomobject]@{ Directory = $workspace; State = (Read-RiderWorkspaceState -WorkspaceDirectory $workspace) }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ProtectedRiderPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and
            $full.StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-WorkflowDeployment {
    param(
        [Parameter(Mandatory)][string]$RequestedAction,
        [Parameter(Mandatory)]$Rider,
        [string]$Workspace
    )
    $deploymentScript = Join-Path $scripts 'Install-ReSharperCppCx.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $deploymentScript,
        '-Action', $RequestedAction,
        '-RiderDirectory', $Rider.RiderDirectory,
        '-Configuration', $Configuration
    )
    if (-not [string]::IsNullOrWhiteSpace($Workspace)) { $arguments += @('-WorkspaceDirectory', $Workspace) }
    if ($WhatIfPreference) {
        $arguments += '-WhatIf'
        $null = Invoke-PatchNative -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments $arguments -WorkingDirectory $PSScriptRoot
        return
    }
    $requiresElevation = (Test-ProtectedRiderPath -Path $Rider.RiderDirectory) -and -not (Test-IsAdministrator)
    if (-not $requiresElevation) {
        $null = Invoke-PatchNative -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments $arguments -WorkingDirectory $PSScriptRoot
        return
    }
    if ($NonInteractive -and -not $AllowUacPrompt) {
        throw 'Deployment requires elevation. Run from an elevated host or specify -AllowUacPrompt.'
    }
    $command = "& $(ConvertTo-SingleQuotedLiteral $deploymentScript) -Action $(ConvertTo-SingleQuotedLiteral $RequestedAction) " +
        "-RiderDirectory $(ConvertTo-SingleQuotedLiteral $Rider.RiderDirectory) -Configuration $(ConvertTo-SingleQuotedLiteral $Configuration)"
    if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
        $command += " -WorkspaceDirectory $(ConvertTo-SingleQuotedLiteral $Workspace)"
    }
    $command += '; if (-not $?) { exit 1 }'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -Wait -PassThru `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    if ($process.ExitCode -ne 0) { throw "Elevated deployment failed with exit code $($process.ExitCode)." }
}

function New-InstalledSource {
    param([Parameter(Mandatory)]$Rider)
    if (-not [string]::IsNullOrWhiteSpace($Rider.ValidationError)) {
        throw "Rider installation requires recovery: $($Rider.ValidationError)"
    }
    return [pscustomobject]@{
        Kind = 'installed'
        RiderDirectory = $Rider.RiderDirectory
        Version = $Rider.Version
        Build = $Rider.Build
    }
}

function New-OnlineSource {
    param([Parameter(Mandatory)]$Release)
    return [pscustomobject]@{
        Kind = 'download'
        RiderDirectory = $null
        Version = $Release.Version
        Build = $Release.Build
    }
}

function Get-InteractiveRequest {
    $installations = @(Get-RiderInstallations)
    Show-RiderInstallations -Installations $installations
    Write-Host ''
    Write-Host '  [number] Select Rider'
    Write-Host '  [C] Customize / online version'
    Write-Host '  [M] Enter another Rider folder'
    Write-Host '  [Q] Quit'
    $choice = Read-Host 'Choice'
    if ($choice -ieq 'Q') { return $null }
    if ($choice -ieq 'C') {
        $sourceChoice = Read-Host 'Source: [I]nstalled or [O]nline'
        if ($sourceChoice -ieq 'O') {
            $release = Get-OnlineReleaseSelection
            $source = New-OnlineSource -Release $release
        }
        else {
            $rider = Select-RiderInstallation -Installations $installations
            $source = New-InstalledSource -Rider $rider
        }
        $patchChoice = Read-Host 'Patches: [A]uto, [S]pecific, or [N]one'
        if ($patchChoice -ieq 'N') { $mode = 'None'; $selectedSet = 'Auto'; $finish = 'Prepare' }
        else {
            $mode = 'All'
            $selectedSet = if ($patchChoice -ieq 'S') { Read-Host 'Patch-set folder name' } else { 'Auto' }
            $finish = Read-Host 'Finish: [P]repare, [B]uild, or [I]nstall'
            $finish = switch -Regex ($finish) { '^(?i:i)' { 'Install'; break }; '^(?i:b)' { 'Build'; break }; default { 'Prepare' } }
            if ($finish -ceq 'Install' -and $source.Kind -ne 'installed') { throw 'Online sources cannot be installed.' }
        }
        return [pscustomobject]@{ Action = $finish; Rider = $(if ($source.Kind -ceq 'installed') { $rider } else { $null }); Source = $source; PatchMode = $mode; PatchSet = $selectedSet }
    }
    if ($choice -ieq 'M') {
        $manual = Read-Host 'Rider installation folder'
        $rider = Get-RiderInstallationInfo -RiderDirectory $manual -Source 'manual'
    }
    else {
        [int]$number = 0
        if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $installations.Count) {
            throw "Invalid selection: $choice"
        }
        $rider = $installations[$number - 1]
    }
    Write-Host ''
    if ($rider.InstallStatus -ceq 'Patched') { Write-Host '  [I] Update C++/CX support' }
    else { Write-Host '  [I] Install C++/CX support' }
    if ($rider.InstallStatus -in @('Patched', 'Recovery required')) { Write-Host '  [R] Restore original DLLs' }
    Write-Host '  [B] Back'
    $operation = Read-Host 'Choice'
    if ($operation -ieq 'B') { return Get-InteractiveRequest }
    if ($operation -ieq 'R') {
        return [pscustomobject]@{ Action = 'Restore'; Rider = $rider; Source = $null; PatchMode = 'None'; PatchSet = 'Auto' }
    }
    if ($rider.InstallStatus -in @('Recovery required', 'Unsupported')) {
        throw "Install is unavailable: $($rider.InstallStatus). Use Customize or Restore."
    }
    return [pscustomobject]@{ Action = 'Install'; Rider = $rider; Source = (New-InstalledSource $rider); PatchMode = 'All'; PatchSet = 'Auto' }
}

if ($interactiveLaunch) {
    $interactive = Get-InteractiveRequest
    if ($null -eq $interactive) { Write-Host 'Cancelled.'; return }
    $Action = $interactive.Action
    $selectedRider = $interactive.Rider
    $selectedSource = $interactive.Source
    $PatchMode = $interactive.PatchMode
    $PatchSet = $interactive.PatchSet
    $NonInteractive = $false
}
else {
    if ($RiderDirectory -and $DownloadVersion) { throw '-RiderDirectory and -DownloadVersion are mutually exclusive.' }
    $installations = @(Get-RiderInstallations -AdditionalPath $(if ($RiderDirectory) { @($RiderDirectory) } else { @() }))
    if ($Action -ceq 'List') {
        Show-RiderInstallations -Installations $installations
        return
    }
    if ($Action -in @('Install', 'Restore') -and $DownloadVersion) { throw "$Action requires a local Rider installation." }
    if ($Action -ne 'Prepare' -and $PatchMode -ceq 'None') { throw '-PatchMode None is valid only with -Action Prepare.' }
    if ($DownloadVersion) {
        $release = Get-OnlineReleaseSelection -Identifier $DownloadVersion
        $selectedSource = New-OnlineSource -Release $release
        $selectedRider = $null
    }
    else {
        $selectedRider = Select-RiderInstallation -Installations $installations -ExplicitPath $RiderDirectory
        $selectedSource = if ($Action -ceq 'Restore') { $null } else { New-InstalledSource -Rider $selectedRider }
    }
}

Assert-WorkflowPrerequisites -RequestedAction $Action

if ($Action -ceq 'Restore') {
    Invoke-WorkflowDeployment -RequestedAction Restore -Rider $selectedRider
    return
}

$request = Get-WorkspaceRequest -Source $selectedSource -SelectedPatchMode $PatchMode -SelectedPatchSet $PatchSet
$approvePatchRefresh = $false
if ($Action -eq 'Install' -and -not $NonInteractive) {
    $workspace = Get-RiderWorkspaceDirectory -WorkRoot $WorkRoot -Version $request.Source.Version -Build $request.Source.Build
    $workspaceDisposition = 'Missing'
    if (Test-Path -LiteralPath $workspace -PathType Container) {
        $workspaceState = Read-RiderWorkspaceState -WorkspaceDirectory $workspace
        $workspaceDisposition = Get-RiderWorkspaceDisposition -State $workspaceState `
            -ExpectedVersion $request.Source.Version -ExpectedBuild $request.Source.Build `
            -ExpectedPatchMode $request.PatchMode -ExpectedPatchSet $request.Resolution.PatchSet.Name `
            -ExpectedPatchSetSha256 $request.Resolution.PatchSet.Sha256
    }
    $installVerb = if ($selectedRider.InstallStatus -ceq 'Patched') { 'update' } else { 'install' }
    Write-Host ''
    Write-Host "Rider: $($selectedRider.RiderDirectory)"
    Write-Host "Version: $($selectedSource.Version) ($($selectedSource.Build))"
    Write-Host "Patch set: $($request.Resolution.PatchSet.Name)"
    Write-Host "Work root: $WorkRoot"
    if ($workspaceDisposition -ceq 'PatchRefreshRequired') {
        Write-Host 'Workspace: the selected patch set changed; generated sources will be refreshed.' -ForegroundColor Yellow
    }
    $prompt = if ($workspaceDisposition -ceq 'PatchRefreshRequired') {
        "Refresh, build, and $installVerb C++/CX support? [y/N]"
    } else {
        "Prepare, build, and $installVerb C++/CX support? [y/N]"
    }
    if ((Read-Host $prompt) -notmatch '^(?i:y|yes)$') {
        Write-Host 'Cancelled.'
        return
    }
    $approvePatchRefresh = $true
}
$prepared = Initialize-WorkflowWorkspace -Request $request -ApprovePatchRefresh:$approvePatchRefresh
Write-Host "Workspace ready: $($prepared.Directory)"
if ($Action -ceq 'Prepare') { return }

& (Join-Path $scripts 'Build-ReSharperCppCx.ps1') -WorkspaceDirectory $prepared.Directory -Configuration $Configuration
if ($Action -ceq 'Build') { return }

Invoke-WorkflowDeployment -RequestedAction Install -Rider $selectedRider -Workspace $prepared.Directory
