# Azure VM STIG Assessment

A generic PowerShell example for orchestrating [Evaluate-STIG](https://github.com/NUWCDIVNPT/Evaluate-STIG) assessments across tagged Azure Windows and Linux virtual machines.

```text
Automation managed identity
  → discover tagged, running VMs
  → Azure VM Run Command (parallel)
  → guest VM managed identity + AzCopy
  → download pinned Evaluate-STIG package from Azure Files
  → run assessment
  → upload CKL results to a unique run directory
```

This repository is an example architecture, not a pre-approved compliance assessment. Validate the Evaluate-STIG package, flags, findings, and Azure Files behavior in your own environment before operational use.

## Contents

| File | Purpose |
|---|---|
| `Invoke-AzureVMStigAssessment.ps1` | Self-contained orchestrator and guest scripts |
| `config.example.json` | Placeholder configuration; contains no credentials |
| `SECURITY.md` | Security model and disclosure guidance |
| `LICENSE` | MIT license |

## Prerequisites

- Azure Automation PowerShell 7 (or a PowerShell 7 host with managed identity) with `Az.Accounts`, `Az.Compute`, and `Az.Resources`.
- An Automation account managed identity that can list/read the targeted VMs and invoke Azure VM Run Command in the chosen subscription.
- System-assigned managed identities on the guest VMs. The sample expects those identities to access a dedicated Azure Files storage account through OAuth over REST.
- Current, approved AzCopy v10 and PowerShell 7 installed on both Windows and Linux guests; `unzip` installed on Linux.
- HTTPS access from guests to the Azure Files endpoint and Microsoft Entra endpoint for the selected cloud.
- An approved `Evaluate-STIG.zip` at the configured file-share path. Package contents must contain `Evaluate-STIG.ps1`.

For the sample's shared package/results account, each guest identity needs **Storage File Data Privileged Contributor** to read the package and write results. That built-in role has broad data access across the storage account. Use a dedicated account and narrow scope or a suitable custom role after testing. [Azure Files OAuth roles](https://learn.microsoft.com/en-us/azure/storage/files/authorize-oauth-rest) and [AzCopy managed identity setup](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-managed-identity) describe the model.

## Configure

Copy `config.example.json` to `config.json`, replace the placeholders, and keep `config.json` out of the public repository. The sample configuration uses Azure public cloud. For Azure US Government, set `cloud` to `AzureUSGovernment`; the script selects the corresponding Azure Files and Entra endpoints. Check service availability and endpoint behavior in the actual tenant before use.

| Field | Meaning |
|---|---|
| `subscriptionId` | Subscription containing the target VMs. |
| `cloud` | `AzureCloud` or `AzureUSGovernment`. |
| `tagName`, `tagValue` | Exact tag pair used to select VMs. |
| `storageAccount`, `fileShare` | Dedicated Azure Files location for the package and results. |
| `packagePath` | Exact ZIP path relative to the share root; pin a reviewed version. |
| `packageSha256` | SHA-256 checksum of that reviewed ZIP, verified inside each guest before execution. |
| `resultsPrefix` | Directory prefix for uploaded results. |
| `throttleLimit` | Maximum concurrent Run Command requests (1–32). Start low. |

The script rejects malformed path fields and `..` segments. It does not accept account keys, SAS tokens, or passwords.

### Local or Hybrid Runbook Worker

```powershell
pwsh ./Invoke-AzureVMStigAssessment.ps1 -ConfigPath ./config.json
```

The host must have a managed identity that can call Azure Resource Manager. The guest VMs use their own identities for Azure Files.

### Azure Automation cloud runbook

Import the script as a PowerShell 7 runbook. Supply the JSON content as its `ConfigurationJson` parameter, for example from an Automation variable or a caller that reads a reviewed config. Azure Automation cloud runbooks do not automatically receive files placed beside the imported script.

Configuration JSON is not a secret, but can reveal resource naming and topology; restrict access according to your organization's policy. Do not put credentials in it.

## Outputs and status

Each run creates a GUID and uploads under:

```text
<share>/<resultsPrefix>/<VM-name>/<run-id>/
```

The script reports a per-VM status and fails the overall job if any guest does not report a completed upload. Existing results are retained. Review the Azure Run Command output and uploaded CKL files for each VM; successful transfer alone does not establish STIG compliance.

## Pilot checks

1. Start with a small, deliberately tagged set containing one Windows and one Linux VM.
2. Confirm that both guest identities can read the pinned ZIP and write to the results path using AzCopy without a SAS or storage key.
3. Confirm the package's supported OS versions, required modules/data files, Evaluate-STIG flags, and CKL output structure.
4. Confirm that failures in package download, scanning, and upload mark the run as failed.
5. Confirm results appear under distinct run IDs and are readable only by authorized reviewers.
6. Increase `throttleLimit` only after observing Run Command and Azure Files limits.

## Design limits

- This example uses Azure Files OAuth over REST. Azure Files support, AzCopy version, identity roles, and Government cloud availability should be checked in the target environment.
- The guest must already have approved tools installed. The script does not download or install system packages.
- Run Command is an execution channel with its own time and output limits. A large or long-running assessment may need a guest agent, scheduled task, or orchestration service instead.
- The sample verifies that CKL files exist and upload completes. It does not interpret findings or determine compliance.
- Results may contain sensitive host information. Apply access controls, retention, and encryption policies to the storage account.
