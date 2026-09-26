<#
.SYNOPSIS
Generates one Git patch per changed file in a decompiled assembly workspace.
.DESCRIPTION
Stages source changes and recreates deterministic per-file patches beside one
assembly workspace. GenerateWorkspacePatches.ps1 runs both assemblies.
.PARAMETER WorkDir
The Work\<Version>_<Build>\<AssemblyName> directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Patch.Common.ps1')

$work = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
if (-not (Test-Path -LiteralPath $work -PathType Container)) { throw "Work directory is missing: $work" }
$source = Join-Path $work 'Source'
$patches = Join-Path $work 'Patches'
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Source directory is missing: $source" }
if (-not (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container)) {
    throw "Source does not contain its pristine Git baseline: $source"
}
if (Test-Path -LiteralPath $patches) {
    $patchItem = Get-Item -LiteralPath $patches -Force
    if (-not $patchItem.PSIsContainer -or ($patchItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to replace a non-directory or linked Patches entry: $patches"
    }
}

$emptyTemplate = Join-Path $work ('.git-template-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($emptyTemplate)
$gitOptions = @(
    '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', '-c', 'core.filemode=false',
    '-c', 'core.ignorecase=false', '-c', 'core.quotePath=true',
    '-c', ('core.hooksPath=' + $emptyTemplate)
)
try {
    $null = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @('add', '--all', '--', '.')) -WorkingDirectory $source -Quiet
    $changedOutput = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @(
        'diff', '--cached', '--name-only', '-z', '--no-renames', 'HEAD', '--', '.'
    )) -WorkingDirectory $source -Quiet
    $changedPaths = @($changedOutput.StdOut.Split([char]0) | Where-Object { $_.Length -gt 0 })

    if (Test-Path -LiteralPath $patches) { Remove-DirectoryTree -Path $patches }
    $null = [IO.Directory]::CreateDirectory($patches)
    $patchNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($relativePath in $changedPaths) {
        if ($relativePath.Contains("`r") -or $relativePath.Contains("`n")) {
            throw "Patch filenames containing newlines are unsupported: $relativePath"
        }
        $patchName = ($relativePath.Replace('\', '/').Replace('/', '_')) + '.patch'
        if (-not $patchNames.Add($patchName)) {
            throw "Changed paths collide on patch filename: $patchName"
        }
        $patchPath = Join-Path $patches $patchName
        $null = Invoke-PatchNative -FilePath 'git' -Arguments ($gitOptions + @(
            'diff', '--cached', 'HEAD', '--binary', '--full-index', '--no-ext-diff',
            '--no-color', '--no-textconv', '--no-renames', '--diff-algorithm=myers',
            '--no-indent-heuristic', '--src-prefix=a/', '--dst-prefix=b/', '--unified=3',
            ('--output=' + $patchPath), '--', $relativePath
        )) -WorkingDirectory $source -Quiet
        $extendedPatchPath = ConvertTo-ExtendedPath -Path $patchPath
        if (-not [IO.File]::Exists($extendedPatchPath) -or
            ([IO.FileInfo]::new($extendedPatchPath)).Length -eq 0) {
            throw "Git generated an empty patch for: $relativePath"
        }
        Write-Host "Patched: $relativePath"
    }

    Write-Host ''
    Write-Host "Generated $($changedPaths.Count) per-file patch(es):"
    Write-Host "  $patches"
}
finally {
    if (Test-Path -LiteralPath $emptyTemplate) {
        Remove-DirectoryTree -Path $emptyTemplate
    }
}
