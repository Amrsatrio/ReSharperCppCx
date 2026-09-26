#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'Scripts\Patch.Common.ps1')
Add-Type -AssemblyName System.Net.Http

$script:Passed = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    ++$script:Passed
}
function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
    try { & $Action; throw "Expected failure matching: $Pattern" }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
    }
    ++$script:Passed
}

Assert-True ((Compare-RiderBuild '262.10315.191' '262.9437.287') -eq 1) 'Build comparison used string order.'
Assert-True ((Compare-RiderBuild '261.1.0' '261.1') -eq 1) 'Multipart component-count ordering is wrong.'
Assert-True ((Compare-RiderBuild 'RD-261.27258.64' '261.27258.64') -eq 0) 'RD prefix normalization failed.'
Assert-Throws { ConvertTo-RiderBuild '261.*' } 'Invalid concrete Rider build'
Assert-Throws { ConvertTo-RiderBuild '261.999999999999999999999' } 'out of range'

$sets = @(
    [pscustomobject]@{ Name = 'old_253.10.1'; Build = '253.10.1' },
    [pscustomobject]@{ Name = 'current_261.27258.64'; Build = '261.27258.64' }
)
Assert-True ((Resolve-RiderPatchSet $sets '261.27258.64' 'Auto').IsExact) 'Exact patch selection failed.'
Assert-True ((Resolve-RiderPatchSet $sets '261.27258.81' 'Auto').PatchSet.Name -ceq 'current_261.27258.64') 'Preceding patch selection failed.'
Assert-True ((Resolve-RiderPatchSet $sets '262.1.1' 'Auto').PatchSet.Name -ceq 'current_261.27258.64') 'Cross-branch fallback failed.'
Assert-Throws { Resolve-RiderPatchSet $sets '252.1.1' 'Auto' } 'No patch set precedes'
Assert-True ((Resolve-RiderPatchSet $sets '252.1.1' 'current_261.27258.64').IsNewer) 'Explicit newer patch set was not retained.'

$handlerSource = @'
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class WorkflowCatalogHandler : HttpMessageHandler
{
    private readonly string json;
    public WorkflowCatalogHandler(string json) { this.json = json; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) });
    }
}
'@
Add-Type -TypeDefinition $handlerSource -ReferencedAssemblies System.Net.Http
$catalogJson = @'
[{"code":"RD","releases":[{"type":"release","version":"2026.1.5.1","majorVersion":"2026.1","build":"261.27258.64","date":"2026-09-01","downloads":{"windowsZip":{"link":"https://x64.invalid/rider.zip","size":123},"windowsZipARM64":{"link":"https://arm.invalid/rider.zip","size":456}}},{"type":"eap","version":"2026.2-EAP1","majorVersion":"2026.2","build":"262.1.1","date":"2026-09-02","downloads":{"windowsZip":{"link":"https://x64.invalid/eap.zip","size":789}}}]}]
'@
$catalogClient = [Net.Http.HttpClient]::new([WorkflowCatalogHandler]::new($catalogJson))
try { $catalog = @(Get-RiderCatalog $catalogClient) } finally { $catalogClient.Dispose() }
Assert-True ($catalog.Count -eq 2) 'Catalog fixture was not normalized.'
Assert-True ($catalog[0].Build -ceq '262.1.1') 'Catalog was not numerically sorted.'
Assert-True ($catalog[1].Downloads.windowsZip.link -ceq 'https://x64.invalid/rider.zip') 'Windows x64 ZIP metadata was not retained.'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('ReSharperCppCx-tests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temp)
try {
    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = @($cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($csc.Count -ne 1) { throw 'The .NET Framework C# compiler is unavailable.' }
    foreach ($fixture in @(
        [pscustomobject]@{ Directory = 'one'; Version = '2026.1.5.1' },
        [pscustomobject]@{ Directory = 'two'; Version = '2026.1.5.2' }
    )) {
        $directory = Join-Path $temp $fixture.Directory
        $null = [IO.Directory]::CreateDirectory($directory)
        $source = Join-Path $directory 'Fixture.cs'
        $code = @"
using System.ComponentModel;
using System.Reflection;
[assembly: AssemblyVersion("777.0.0.0")]
[assembly: Editor("WaveMarketingName", "$($fixture.Version)")]
[assembly: AssemblyMetadata("WaveMarketingName", "$($fixture.Version)")]
[assembly: Editor("WaveMarketingNameCompressed", "$($fixture.Version)")]
[assembly: AssemblyMetadata("WaveMarketingNameCompressed", "$($fixture.Version)")]
public sealed class Marker { }
"@
        [IO.File]::WriteAllText($source, $code, [Text.UTF8Encoding]::new($false))
        $output = Join-Path $directory 'WaveFixture.dll'
        $null = Invoke-PatchNative -FilePath $csc[0] -Arguments @('/nologo', '/target:library', ('/out:' + $output), $source) -WorkingDirectory $directory -Quiet
    }
    $first = Join-Path $temp 'one\WaveFixture.dll'
    $second = Join-Path $temp 'two\WaveFixture.dll'
    Assert-True ((Assert-RiderAssemblyMarketingVersion $first '2026.1.5.1') -ceq '2026.1.5.1') 'Expected wave metadata failed.'
    Assert-True ((Assert-RiderAssemblyMarketingVersion $second '2026.1.5.2') -ceq '2026.1.5.2') 'Second same-identity fixture was unified incorrectly.'
    Assert-Throws { Assert-RiderAssemblyMarketingVersion $second '2026.1.5.1' } 'Expected.*2026\.1\.5\.1.*found.*2026\.1\.5\.2'

    $workspace = Join-Path $temp 'workspace'
    $patchSet = Join-Path $temp 'patchset'
    foreach ($project in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
        $sourceRoot = Join-Path (Join-Path $workspace $project) 'Source'
        $patchRoot = Join-Path $patchSet $project
        $null = [IO.Directory]::CreateDirectory($sourceRoot)
        $null = [IO.Directory]::CreateDirectory($patchRoot)
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'Sample.cs'), "class Sample { }`n", [Text.UTF8Encoding]::new($false))
        $null = Invoke-PatchNative git @('init', '--quiet', '--initial-branch=baseline', '.') $sourceRoot -Quiet
        $null = Invoke-PatchNative git @('add', '--all', '--', '.') $sourceRoot -Quiet
        $null = Invoke-PatchNative git @('-c','user.name=Tests','-c','user.email=tests@invalid','commit','--quiet','-m','baseline') $sourceRoot -Quiet
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'Sample.cs'), "class Sample { int Value; }`n", [Text.UTF8Encoding]::new($false))
        $patchPath = Join-Path $patchRoot 'Sample.cs.patch'
        $null = Invoke-PatchNative git @('diff','--binary','--full-index',('--output='+$patchPath),'--','Sample.cs') $sourceRoot -Quiet
        $null = Invoke-PatchNative git @('reset','--hard','HEAD') $sourceRoot -Quiet
        if ($project -ceq 'JetBrains.ReSharper.Feature.Services.Cpp') {
            $text = [IO.File]::ReadAllText($patchPath).Replace('class Sample { }', 'class Missing { }')
            [IO.File]::WriteAllText($patchPath, $text, [Text.UTF8Encoding]::new($false))
        }
    }
    [IO.File]::WriteAllText((Join-Path $workspace 'ReSharperCppCx_test.slnx'), '<Solution />', [Text.UTF8Encoding]::new($false))
    Write-PatchJson (Join-Path $workspace 'workspace.json') ([ordered]@{
        schemaVersion=1;version='test';build='1.1';sourceKind='download';sourceRiderDirectory=$null
        originals=@([ordered]@{fileName='a';sha256=('0'*64);assemblyIdentity='a';waveMarketingName='test'},[ordered]@{fileName='b';sha256=('1'*64);assemblyIdentity='b';waveMarketingName='test'})
        patchMode='All';patchSet='test_1.1';patchSetSha256=('2'*64);patchStatus='pristine';patchError=$null;failedPatches=@()
        sourceTrees=@([ordered]@{project='JetBrains.ReSharper.Cpp';sha256=('3'*64);fileCount=1},[ordered]@{project='JetBrains.ReSharper.Feature.Services.Cpp';sha256=('4'*64);fileCount=1})
    })
    Assert-Throws { Invoke-RiderPatchSet $workspace $patchSet } 'patch|apply'
    $engineSource = Join-Path (Join-Path $workspace 'JetBrains.ReSharper.Cpp') 'Source'
    $featureSource = Join-Path (Join-Path $workspace 'JetBrains.ReSharper.Feature.Services.Cpp') 'Source'
    $engineStatus = (Invoke-PatchNative git @('status','--porcelain') $engineSource -Quiet).StdOut.Trim()
    $featureStatus = (Invoke-PatchNative git @('status','--porcelain') $featureSource -Quiet).StdOut.Trim()
    Assert-True ($engineStatus -ceq 'M  Sample.cs') 'Successful patch was not retained and staged after a peer patch failed.'
    Assert-True ([string]::IsNullOrWhiteSpace($featureStatus)) 'Failed patch modified its repository.'
    $failedState = [IO.File]::ReadAllText((Join-Path $workspace 'workspace.json')) | ConvertFrom-Json
    Assert-True ($failedState.patchStatus -ceq 'failed') 'Patch failure was not recorded.'
    Assert-True (@($failedState.failedPatches).Count -eq 1) 'Failed patch inventory was not recorded.'
    Assert-True ($failedState.failedPatches[0].project -ceq 'JetBrains.ReSharper.Feature.Services.Cpp') 'Wrong failed project was recorded.'
    Assert-True ($failedState.failedPatches[0].patch -ceq 'Sample.cs.patch') 'Wrong failed patch name was recorded.'

    $enginePatch = Join-Path (Join-Path $patchSet 'JetBrains.ReSharper.Cpp') 'Sample.cs.patch'
    $featurePatch = Join-Path (Join-Path $patchSet 'JetBrains.ReSharper.Feature.Services.Cpp') 'Sample.cs.patch'
    [IO.File]::Copy($enginePatch, $featurePatch, $true)
    foreach ($sourceRoot in @($engineSource, $featureSource)) {
        $null = Invoke-PatchNative git @('reset','--hard','HEAD') $sourceRoot -Quiet
        $null = Invoke-PatchNative git @('clean','-fd') $sourceRoot -Quiet
    }
    $failedState.patchStatus = 'pristine'
    $failedState.patchError = $null
    $failedState.failedPatches = @()
    $failedState.sourceTrees = @(Get-RiderWorkspaceSourceTrees -WorkspaceDirectory $workspace)
    Write-AtomicPatchJson -Path (Join-Path $workspace 'workspace.json') -Value $failedState
    $null = Invoke-RiderPatchSet $workspace $patchSet
    foreach ($project in @('JetBrains.ReSharper.Cpp', 'JetBrains.ReSharper.Feature.Services.Cpp')) {
        $sourceRoot = Join-Path (Join-Path $workspace $project) 'Source'
        $staged = (Invoke-PatchNative git @('diff','--cached','--name-only','HEAD') $sourceRoot -Quiet).StdOut.Trim()
        $unstaged = (Invoke-PatchNative git @('diff','--name-only') $sourceRoot -Quiet).StdOut.Trim()
        $untracked = (Invoke-PatchNative git @('ls-files','--others','--exclude-standard') $sourceRoot -Quiet).StdOut.Trim()
        Assert-True ($staged -ceq 'Sample.cs') "Successful patch was not staged in $project."
        Assert-True ([string]::IsNullOrWhiteSpace($unstaged)) "Successful patch left unstaged edits in $project."
        Assert-True ([string]::IsNullOrWhiteSpace($untracked)) "Successful patch left untracked files in $project."
    }
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-DirectoryTree -Path $temp }
}

Write-Host "Workflow behavior tests passed: $script:Passed assertions."
