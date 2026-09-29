# Security policy

## Supported scope

This is an example project. Maintainers accept reports about vulnerabilities in this repository's code and documentation. Issues in Evaluate-STIG, Azure, AzCopy, or an organization's deployment should be reported to their respective maintainers and operators.

## Reporting a vulnerability

Do not post credentials, tokens, host results, tenant details, or exploit material in a public issue. Use GitHub private vulnerability reporting if available. Otherwise, open a public issue asking the maintainer for a private contact method without including sensitive details.

## Deployment security

- Keep the Automation identity's VM discovery and Run Command permissions narrowly scoped.
- Give guest identities only the Azure Files data permissions needed for package download and result upload. The sample's privileged contributor role is broad; isolate the storage account.
- Review and pin the Evaluate-STIG ZIP and validate its integrity through an approved distribution process before making it available to guests.
- Keep assessment output private. CKL files and logs can expose host configuration and findings.
- Do not add storage keys, SAS tokens, VM names, tenant IDs, or customer-specific data to issues, examples, screenshots, or commit history.
- Review Azure Run Command logs and activity records; they reflect commands executed on guest VMs.

The example intentionally contains no account key or SAS token. Guest AzCopy uses each VM's managed identity and Azure Files OAuth over REST. Validate cloud support and role assignments during a pilot.
