<# Run with: pwsh -NoProfile -File ./tests/Test-ControlFlow.ps1
   Uses local Az cmdlet doubles; makes no Azure calls. #>
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("stig-control-test-" + [guid]::NewGuid().ToString('N'))
$originalModulePath = $env:PSModulePath

function New-TestModule {
    param([string]$Name, [string]$Source)
    $folder = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $folder "$Name.psm1") -Value $Source
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    New-TestModule 'Az.Accounts' @'
function Connect-AzAccount { param([switch]$Identity, $Environment) [pscustomobject]@{ Connected = $true } }
function Set-AzContext { param($SubscriptionId) [pscustomobject]@{ Selected = $true } }
Export-ModuleMember -Function Connect-AzAccount, Set-AzContext
'@
    New-TestModule 'Az.Resources' @'
function Get-AzResource {
    param($TagName, $TagValue, $ResourceType)
    'win-fails', 'linux-no-marker', 'win-succeeds', 'linux-succeeds' |
        ForEach-Object { [pscustomobject]@{ Name = $_; ResourceGroupName = 'rg-example' } }
}
Export-ModuleMember -Function Get-AzResource
'@
    New-TestModule 'Az.Compute' @'
function Get-AzVM {
    param($ResourceGroupName, $Name, [switch]$Status)
    if ($Status) { return [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'PowerState/running' }) } }
    $os = if ($Name -like 'win-*') { 'Windows' } else { 'Linux' }
    return [pscustomobject]@{
        Name = $Name
        ResourceGroupName = $ResourceGroupName
        StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{ OsType = $os } }
    }
}
function Invoke-AzVMRunCommand {
    param($ResourceGroupName, $Name, $CommandId, $ScriptString, $Parameter)
    if ($Name -eq 'win-fails') { throw 'Simulated Run Command failure' }
    $message = if ($Name -eq 'linux-no-marker') { 'Guest upload failed' } else { 'ASSESSMENT_RESULT=SUCCESS' }
    return [pscustomobject]@{ Value = @([pscustomobject]@{ Message = $message }) }
}
Export-ModuleMember -Function Get-AzVM, Invoke-AzVMRunCommand
'@

    $env:PSModulePath = "$testRoot$([IO.Path]::PathSeparator)$originalModulePath"
    Import-Module (Join-Path $testRoot 'Az.Accounts/Az.Accounts.psm1') -Force
    Import-Module (Join-Path $testRoot 'Az.Resources/Az.Resources.psm1') -Force
    Import-Module (Join-Path $testRoot 'Az.Compute/Az.Compute.psm1') -Force

    $config = @{
        subscriptionId = '00000000-0000-0000-0000-000000000000'
        cloud = 'AzureCloud'
        tagName = 'Assessment'
        tagValue = 'Enabled'
        storageAccount = 'exampleaccount'
        fileShare = 'example-share'
        packagePath = 'packages/Evaluate-STIG.zip'
        packageSha256 = '0' * 64
        resultsPrefix = 'results'
        throttleLimit = 2
    } | ConvertTo-Json -Compress

    $records = @(& (Join-Path $root 'Invoke-AzureVMStigAssessment.ps1') -ConfigurationJson $config)
    $vmRecords = @($records | Where-Object { $_ -is [pscustomobject] -and $_.RecordType -eq 'VM' })
    $summary = @($records | Where-Object { $_ -is [pscustomobject] -and $_.RecordType -eq 'Summary' })
    if ($vmRecords.Count -ne 4) { throw "Expected four VM records; got $($vmRecords.Count)." }
    if ($summary.Count -ne 1) { throw "Expected one summary record; got $($summary.Count)." }
    if ($summary[0].Total -ne 4 -or $summary[0].Succeeded -ne 2 -or $summary[0].Failed -ne 2) {
        throw "Unexpected summary: $($summary[0] | ConvertTo-Json -Compress)"
    }
    if (@($vmRecords | Where-Object Status -eq 'Succeeded').Count -ne 2) { throw 'Successful VMs were not retained.' }
    if (@($vmRecords | Where-Object Status -eq 'Failed').Count -ne 2) { throw 'Failed VMs were not recorded.' }
    if (@($vmRecords | Where-Object { $_.VM -eq 'linux-no-marker' -and $_.Status -eq 'Failed' }).Count -ne 1) {
        throw 'A guest response without the upload success marker was accepted.'
    }

    $badConfig = $config | ConvertFrom-Json
    $badConfig.tagName = ''
    $orchestrationFailed = $false
    try {
        & (Join-Path $root 'Invoke-AzureVMStigAssessment.ps1') -ConfigurationJson ($badConfig | ConvertTo-Json -Compress) | Out-Null
    } catch {
        $orchestrationFailed = $true
    }
    if (-not $orchestrationFailed) { throw 'Invalid configuration did not stop the orchestration job.' }
    Write-Output 'PASS: Mixed VM outcomes completed with accurate per-VM records and summary; invalid orchestration config failed.'
} finally {
    $env:PSModulePath = $originalModulePath
    Remove-Module Az.Accounts, Az.Resources, Az.Compute -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
