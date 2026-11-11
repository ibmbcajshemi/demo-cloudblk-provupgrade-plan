---
name: tf-plan
description: '# `/tf-plan` Slash Command'
metadata:
  user-invocable: true
  disable-model-invocation: true
---

# `/tf-plan` Slash Command

Generate a comprehensive migration plan and human-in-the-loop state runbook for transitioning this repository from Terraform CE to Terraform Enterprise.

```prompt
Activate the `tf-migration-plan` skill.
Target TFE host, organization and workspace: use only what the user supplied. If none was supplied, write `<tfe-hostname>`, `<org-name>` and `<workspace-name>` as placeholders marked "to be confirmed", and do not select an organization yourself.
Based on the repository code and estate inventory:
1. Establish target TFE Workspace hierarchy and naming mappings (<app>-<env>-<region>).
2. Validate workspace configuration parameters using `tfctl create workspace -a name=<workspace-name> -o <org-name> --dry-run` (only when the organization was supplied; otherwise skip this step and list it as an action item).
3. Map environment and input variables to TFE Variable Sets without exposing plaintext secrets.
4. Generate the step-by-step human-in-the-loop State Migration Runbook (pre-migration backup, terraform init -migrate-state, zero-diff verification plan).
5. Document rollback and contingency procedures.

Output the full plan in the standard migration plan markdown format.
```
