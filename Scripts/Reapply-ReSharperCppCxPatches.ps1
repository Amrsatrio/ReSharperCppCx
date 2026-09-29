#requires -Version 5.1
<#
.SYNOPSIS
Resets both generated source repositories to their baseline and applies a selected patch set.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceDirectory,
    [string]$PatchSetName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')

$workspace = (Resolve-Path -LiteralPath $WorkspaceDirectory -ErrorAction Stop).ProviderPath
$state = Read-RiderWorkspaceState -WorkspaceDirectory $workspace
if ($state.patchMode -cne 'All') {
    throw 'Workspace state does not select complete patching.'
}
$selectedPatchSet = if ([string]::IsNullOrWhiteSpace($PatchSetName)) { [string]$state.patchSet } else { $PatchSetName }
if ([string]::IsNullOrWhiteSpace($selectedPatchSet)) { throw 'No patch set was selected.' }
$patchSets = @(Get-RiderPatchSets -PatchRoot (Join-Path (Get-PatchPackageRoot) 'Patches'))
$matches = @($patchSets | Where-Object { $_.Name -ceq $selectedPatchSet })
if ($matches.Count -ne 1) { throw "Selected patch set is unavailable: $selectedPatchSet" }
$patchSet = $matches[0]

$description = "Reset both generated Git repositories to baseline and reapply $($patchSet.Name)"
if (-not $PSCmdlet.ShouldProcess($workspace, $description)) { return }

foreach ($project in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
    $source = Join-Path (Join-Path $workspace $project) 'Source'
    if (-not (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container)) {
        throw "Source Git baseline is missing: $source"
    }
    $null = Invoke-PatchNative -FilePath git -Arguments @('reset', '--hard', 'HEAD') -WorkingDirectory $source -Quiet
    $null = Invoke-PatchNative -FilePath git -Arguments @('clean', '-fd') -WorkingDirectory $source -Quiet
}

$state.patchSet = $patchSet.Name
$state.patchSetSha256 = $patchSet.Sha256
$state.patchStatus = 'pristine'
$state.patchError = $null
$state.sourceTrees = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace)
$state | Add-Member -MemberType NoteProperty -Name failedPatches -Value @() -Force
Write-AtomicPatchJson -Path (Join-Path $workspace 'workspace.json') -Value $state

$null = Invoke-RiderPatchSet -WorkspaceDirectory $workspace -PatchSetDirectory $patchSet.Directory
Write-Host "Patch set reapplied: $($patchSet.Name)"
