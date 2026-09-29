<#
.SYNOPSIS
    Runs Evaluate-STIG on tagged Azure Windows and Linux VMs.
.DESCRIPTION
    Azure Automation PowerShell 7 runbook. The Automation account's managed
    identity discovers and invokes running VMs. Each guest's own managed identity
    downloads a pinned Evaluate-STIG ZIP from Azure Files and uploads results
    through AzCopy over HTTPS. No account key or SAS is passed through Run Command.
    Results use a unique run path; this script does not delete prior assessments.
.PARAMETER ConfigPath
    Path to a JSON configuration file matching config.example.json.
.PARAMETER ConfigurationJson
    JSON configuration supplied directly, for example from an Automation variable.
.NOTES
    Requires Az.Accounts, Az.Compute, Az.Resources; AzCopy and PowerShell 7 on
    guest VMs. Validate Azure Files OAuth over REST support in the target cloud.
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'Inline')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Value {
    param([object]$Value, [string]$Name, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace([string]$Value) -or [string]$Value -notmatch $Pattern) {
        throw "Invalid or missing configuration value: $Name"
    }
}

foreach ($module in 'Az.Accounts', 'Az.Compute', 'Az.Resources') {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        throw "Install required module $module in the Automation account."
    }
}

$json = if ($PSCmdlet.ParameterSetName -eq 'File') {
    Get-Content -LiteralPath $ConfigPath -Raw
} else {
    $ConfigurationJson
}
$config = $json | ConvertFrom-Json
Assert-Value $config.subscriptionId 'subscriptionId' '^[0-9a-fA-F-]{36}$'
Assert-Value $config.cloud 'cloud' '^(AzureCloud|AzureUSGovernment)$'
Assert-Value $config.tagName 'tagName' '^[A-Za-z0-9_.:-]{1,128}$'
Assert-Value $config.tagValue 'tagValue' '^[A-Za-z0-9_.:-]{1,256}$'
Assert-Value $config.storageAccount 'storageAccount' '^[a-z0-9]{3,24}$'
Assert-Value $config.fileShare 'fileShare' '^[a-z0-9-]{3,63}$'
Assert-Value $config.packagePath 'packagePath' '^[A-Za-z0-9._/-]+\.zip$'
Assert-Value $config.packageSha256 'packageSha256' '^[0-9a-fA-F]{64}$'
Assert-Value $config.resultsPrefix 'resultsPrefix' '^[A-Za-z0-9._/-]+$'
if ($config.packagePath.StartsWith('/') -or $config.packagePath -match '(^|/)\.\.(/|$)') { throw 'packagePath must be relative and cannot contain .. segments.' }
if ($config.resultsPrefix.StartsWith('/') -or $config.resultsPrefix -match '(^|/)\.\.(/|$)') { throw 'resultsPrefix must be relative and cannot contain .. segments.' }
$throttle = [int]$config.throttleLimit
if ($throttle -lt 1 -or $throttle -gt 32) { throw 'throttleLimit must be between 1 and 32.' }

$cloudSettings = switch ($config.cloud) {
    'AzureCloud' { @{ FileSuffix = 'file.core.windows.net'; AadEndpoint = 'https://login.microsoftonline.com' } }
    'AzureUSGovernment' { @{ FileSuffix = 'file.core.usgovcloudapi.net'; AadEndpoint = 'https://login.microsoftonline.us' } }
}

Connect-AzAccount -Identity -Environment $config.cloud | Out-Null
Set-AzContext -SubscriptionId $config.subscriptionId | Out-Null
$resources = @(Get-AzResource -TagName $config.tagName -TagValue $config.tagValue -ResourceType 'Microsoft.Compute/virtualMachines')
if ($resources.Count -eq 0) {
    Write-Warning 'No VMs matched the configured tag.'
    return
}

$targets = @(
    foreach ($resource in $resources) {
        $vm = Get-AzVM -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -ErrorAction Stop
        $status = Get-AzVM -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -Status -ErrorAction Stop
        $power = @($status.Statuses | Where-Object { $_.Code -eq 'PowerState/running' })
        if ($power.Count -eq 0) {
            Write-Warning "Skipping stopped VM $($vm.Name)."
            continue
        }
        $os = [string]$vm.StorageProfile.OsDisk.OsType
        if ($os -notin @('Windows', 'Linux')) {
            Write-Warning "Skipping VM $($vm.Name) with unsupported OS type $os."
            continue
        }
        [pscustomobject]@{ Name = $vm.Name; ResourceGroupName = $vm.ResourceGroupName; OsType = $os }
    }
)
if ($targets.Count -eq 0) {
    Write-Warning 'No running Windows or Linux VMs matched.'
    return
}

$runId = [guid]::NewGuid().ToString('N')
$shareRoot = "https://$($config.storageAccount).$($cloudSettings.FileSuffix)/$($config.fileShare)"
$packageUrl = "$shareRoot/$($config.packagePath)"
$packageSha256 = [string]$config.packageSha256
$outputRoot = "$shareRoot/$($config.resultsPrefix.TrimEnd('/'))"
$aadEndpoint = $cloudSettings.AadEndpoint

# The Windows guest receives only non-secret configuration encoded as JSON.
$windowsGuest = @'
param([Parameter(Mandatory)][string]$Configuration)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Configuration)) | ConvertFrom-Json
$env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
$env:AZCOPY_ACTIVE_DIRECTORY_ENDPOINT = $settings.aadEndpoint
$work = Join-Path $env:TEMP ("stig-assessment-" + [guid]::NewGuid().ToString('N'))
$package = Join-Path $work 'Evaluate-STIG.zip'
$tool = Join-Path $work 'tool'
$results = Join-Path $work 'results'
try {
    foreach ($command in 'azcopy', 'pwsh') {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing guest prerequisite: $command" }
    }
    New-Item -ItemType Directory -Path $work, $tool, $results -Force | Out-Null
    & azcopy copy $settings.packageUrl $package --check-md5=FailIfDifferent
    if ($LASTEXITCODE -ne 0) { throw "Package download failed (AzCopy exit $LASTEXITCODE)." }
    $actualHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($actualHash -ne $settings.packageSha256) { throw 'Package SHA-256 did not match the reviewed configuration.' }
    Expand-Archive -LiteralPath $package -DestinationPath $tool -Force
    $entry = Get-ChildItem -LiteralPath $tool -Filter 'Evaluate-STIG.ps1' -File -Recurse | Select-Object -First 1
    if (-not $entry) { throw 'Evaluate-STIG.ps1 was absent from the package.' }
    Push-Location $entry.DirectoryName
    try {
        & pwsh -NoProfile -File $entry.FullName -ScanType Unclassified -Output CKL -OutputPath $results
        if ($LASTEXITCODE -ne 0) { throw "Evaluate-STIG failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }
    if (-not (Get-ChildItem -LiteralPath $results -Filter '*.ckl' -File -Recurse | Select-Object -First 1)) {
        throw 'No CKL checklist was produced.'
    }
    & azcopy copy (Join-Path $results '*') $settings.destinationUrl --recursive=true
    if ($LASTEXITCODE -ne 0) { throw "Result upload failed (AzCopy exit $LASTEXITCODE)." }
    Write-Output 'ASSESSMENT_RESULT=SUCCESS'
} catch {
    Write-Error "Assessment failed: $($_.Exception.Message)"
    throw
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
'@

# The Linux guest uses validated URL fields; no shell metacharacters are allowed
# in the configurable path fields above. It also uses its own managed identity.
$linuxGuest = @'
#!/usr/bin/env bash
set -Eeuo pipefail
export AZCOPY_AUTO_LOGIN_TYPE=MSI
export AZCOPY_ACTIVE_DIRECTORY_ENDPOINT='__AAD_ENDPOINT__'
package_url='__PACKAGE_URL__'
package_sha256='__PACKAGE_SHA256__'
destination_url='__DESTINATION_URL__'
work=$(mktemp -d /tmp/stig-assessment.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
command -v azcopy >/dev/null || { echo 'Missing guest prerequisite: azcopy' >&2; exit 1; }
command -v pwsh >/dev/null || { echo 'Missing guest prerequisite: pwsh' >&2; exit 1; }
command -v unzip >/dev/null || { echo 'Missing guest prerequisite: unzip' >&2; exit 1; }
mkdir -p "$work/tool" "$work/results"
azcopy copy "$package_url" "$work/Evaluate-STIG.zip" --check-md5=FailIfDifferent
actual_sha256=$(sha256sum "$work/Evaluate-STIG.zip" | cut -d ' ' -f 1)
[[ "${actual_sha256,,}" == "${package_sha256,,}" ]] || { echo 'Package SHA-256 did not match the reviewed configuration.' >&2; exit 1; }
unzip -q "$work/Evaluate-STIG.zip" -d "$work/tool"
entry=$(find "$work/tool" -type f -name 'Evaluate-STIG.ps1' -print -quit)
[[ -n "$entry" ]] || { echo 'Evaluate-STIG.ps1 was absent from the package.' >&2; exit 1; }
cd "$(dirname "$entry")"
pwsh -NoProfile -File "$entry" -ScanType Unclassified -Output CKL -OutputPath "$work/results"
find "$work/results" -type f -iname '*.ckl' -print -quit | grep -q . || { echo 'No CKL checklist was produced.' >&2; exit 1; }
azcopy copy "$work/results/*" "$destination_url" --recursive=true
echo 'ASSESSMENT_RESULT=SUCCESS'
'@

Write-Output "Run ${runId}: dispatching $($targets.Count) VM(s)."
$results = @($targets | ForEach-Object -Parallel {
    $target = $_
    $destination = "$using:outputRoot/$([uri]::EscapeDataString($target.Name))/$using:runId"
    try {
        if ($target.OsType -eq 'Windows') {
            $guestConfig = @{
                aadEndpoint = $using:aadEndpoint
                packageUrl = $using:packageUrl
                packageSha256 = $using:packageSha256
                destinationUrl = $destination
            } | ConvertTo-Json -Compress
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($guestConfig))
            $response = Invoke-AzVMRunCommand -ResourceGroupName $target.ResourceGroupName -Name $target.Name -CommandId 'RunPowerShellScript' -ScriptString $using:windowsGuest -Parameter @{ Configuration = $encoded } -ErrorAction Stop
        } else {
            $script = $using:linuxGuest
            $script = $script.Replace('__AAD_ENDPOINT__', $using:aadEndpoint).Replace('__PACKAGE_URL__', $using:packageUrl).Replace('__PACKAGE_SHA256__', $using:packageSha256).Replace('__DESTINATION_URL__', $destination)
            $response = Invoke-AzVMRunCommand -ResourceGroupName $target.ResourceGroupName -Name $target.Name -CommandId 'RunShellScript' -ScriptString $script -ErrorAction Stop
        }
        $guestOutput = (@($response.Value) | ForEach-Object { [string]$_.Message }) -join "`n"
        if ($guestOutput -notmatch 'ASSESSMENT_RESULT=SUCCESS') { throw 'Guest did not report a completed result upload; inspect Run Command output.' }
        [pscustomobject]@{ VM = $target.Name; OS = $target.OsType; Status = 'Succeeded'; Detail = $destination }
    } catch {
        [pscustomobject]@{ VM = $target.Name; OS = $target.OsType; Status = 'Failed'; Detail = $_.Exception.Message }
    }
} -ThrottleLimit $throttle)

$results | Sort-Object VM | Format-Table -AutoSize
$failures = @($results | Where-Object Status -eq 'Failed')
if ($failures.Count -gt 0) { throw "$($failures.Count) of $($targets.Count) VM assessments failed." }
