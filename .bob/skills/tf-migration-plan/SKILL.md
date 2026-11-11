---
name: tf-migration-plan
description: Use when generating a migration plan and human-in-the-loop state runbook for migrating a Terraform repository from Community Edition (CE/OSS) to Terraform Enterprise (TFE). Covers workspace mapping, variable set planning, state backup/migration recipes, and rollback checkpoints.
---

# Terraform CE to TFE Migration Planning & Runbook Generation (`tf-migration-plan`)

This skill generates a concrete, actionable **Migration Plan** and a **Human-in-the-Loop State Migration Runbook** for transitioning a Terraform configuration from Community Edition (CE/OSS) to self-hosted Terraform Enterprise (TFE).

It integrates with:
- Findings from the `tf-inventory` assessment.
- Live platform grounding and dry-run scaffolding via `tfctl`.
- Optional verification gates from `/terraform-devops`, if that skill is installed.
- Enterprise pipeline conventions (`cloud-deploy`).

---

## Step 1: Establish Workspace Hierarchy & Mapping

### Target Resolution Rule (applies to the whole plan)
The target TFE hostname, organization and workspace must come from the user's request, the repository's own `cloud`/`remote` block, or the `tfctl` profile's `default_organization`. If none names them:
- **Do not choose an organization** because it is first in a list or appears accessible, and do not run `tfctl` workspace checks against one.
- Write the target as `NOT SPECIFIED` in the plan, present workspace names as proposals only, and list "confirm target host, organization and workspace" as the first action item.
- Every command in the runbook must use placeholders (`<TFE_HOSTNAME>`, `<ORG_NAME>`, `<WORKSPACE_NAME>`), never example or guessed values.

Determine how the existing repository, directory structure, or local workspaces map to target TFE Workspaces.

1. **Mapping Models**:
   - **Single Workspace per Directory**: Each root module or environment folder (`infra/envs/prod`) maps to a distinct TFE Workspace (e.g., `app-frontend-prod`).
   - **Local CLI Workspaces to TFE Workspaces**: If the CE repository uses `terraform.workspace` (e.g., `dev`, `stage`, `prod`), map each to a dedicated TFE workspace using the tag-based or explicit naming convention:
     - Project: `<project-name>` (e.g., `CoreBanking`)
     - Workspace: `<app-name>-<environment>-<region>` (e.g., `payment-service-prod-us-east-1`)
2. **Execution Mode & Credential Strategy**:
   - Standard TFE Default: `remote` (runs and speculative plans execute in TFE container workers).
   - **Credential Attachment Invariant for Remote Execution**: When `execution-mode=remote` is used, provider cloud credentials (e.g. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, or OIDC/dynamic credentials) must be configured in a TFE Variable Set and attached to the target workspace *before* running any verification plan (`terraform plan`), otherwise the remote runner cannot authenticate to provider APIs.
   - If local execution is used (`local`), runs execute on the operator's machine using local environment credentials, with state stored remotely in TFE.
   - If private network access or specialized runner requirements exist, specify `agent` execution mode and the target Agent Pool.
3. **Workspace Pre-provisioning via `tfctl` (Dry-Run)**:
   - When `tfctl` is available, validate workspace creation parameters:
     ```bash
     tfctl create workspace -a name="<workspace-name>" -o "<org-name>" --dry-run
     ```

---

## Step 2: Variable & Secret Migration Planning

Map all configuration inputs into TFE variables without exposing or logging sensitive values:

1. **Environment Variables & Cloud Credentials**:
   - Cloud credentials (`AWS_*`, `ARM_*`, `IC_*`, `GOOGLE_*`) -> Map to TFE Variable Sets configured with dynamic credentials / OIDC provider or sensitive environment variables.
   - For remote execution, attach required credential Variable Sets to the workspace before executing the verification plan.
2. **Terraform Variables (`TF_VAR_*` / `*.tfvars`)**:
   - Common shared variables -> Map to shared TFE Variable Sets scoped to the Project or Organization.
   - Workspace-specific variables -> Define in the plan as TFE Workspace Variables (HCL or string type).
3. **Sensitive Variables Rule**:
   - Flag all secrets (`sensitive = true`, API keys, DB passwords).
   - **Zero Plaintext Principle**: The migration plan must *never* record the secret values. The runbook instructs operators to enter sensitive values directly in the TFE UI, via TFE Variable Sets, or through enterprise CI/CD (`cloud-deploy`).

---

## Step 3: State Migration Strategy & Cutover Sequence

State migration must never be performed unattended. Formulate a step-by-step, human-in-the-loop operational runbook enforcing strict state backup before cutover.

### Ordering & Approval Invariants
- **Backup on Legacy Backend First**: The pre-migration backup MUST be extracted (`terraform state pull`) while the **legacy backend is still active and configured** in code. A state pulled after the `cloud` block is in place comes from the new empty workspace and does not contain legacy state.
- **Human Approval at PR Review**: The Pull Request review is the explicit human approval point before applying backend swaps or running provider constraint bumps and `terraform init -upgrade` (as required by `terraform-devops` section 1).

### State Migration Cutover Sequence:
The authoritative sequence is in `.bob/rules/03-cutover-verification.md`. If `.bob/scripts/tf-cutover-verify.sh` is present, reference it in the runbook as the operator's helper (the operator runs it, Bob does not): `--phase backup` on the legacy configuration, `--phase migrate --confirm` after the backend change is merged, then `--phase verify`. Use `--dry-run` to preview. The manual commands below remain valid without the script.

1. **Pre-requisites**:
   - Target TFE Workspace created and configured with required Variable Sets attached.
   - Pull Request with backend code changes approved and ready for merge.
   - Operator authenticated to both the source backend and target TFE (`terraform login` or `TFE_TOKEN`).
2. **State Backup (On Legacy Backend)**:
   - Pull and archive the latest state file locally with a timestamped backup before modifying backend blocks:
     ```bash
     terraform state pull > "terraform_state_backup_$(date +%Y%m%d%H%M%S).tfstate"
     ```
   - Record SHA-256 checksum of the backup file.
3. **Backend Re-Initialization & Cutover**:
   - Merge the approved backend PR (switching configuration to the new TFE `cloud` or `remote` block).
   - Execute backend initialization and state migration:
     ```bash
     # cloud block:
     terraform init
     # backend "remote" block:
     terraform init -migrate-state
     ```
   - Operator responds `yes` when prompted to copy existing state to the new backend.
4. **Alternative: Direct State Push via CLI / `tfctl`**:
   - If migrating state via direct upload:
     ```bash
     terraform state push "terraform_state_backup_<timestamp>.tfstate"
     ```

---

## Step 4: Verification & Zero-Diff Plan Gate

Ensure that post-migration plan execution produces zero changes before decommissioning the legacy backend:

1. **Zero-Diff Plan Check**:
   - Execute a speculative plan in TFE or locally against the new backend:
     ```bash
     terraform plan -detailed-exitcode
     ```
   - **Expected Result**: Exit code `0` (`No changes. Your infrastructure matches the configuration.`).
2. **Discrepancy Remediation**:
   - If differences (`~`, `+`, `-`) appear, stop immediately. Check for:
     - Missing variable definitions in TFE.
     - Provider version drift between CE runtime and TFE workspace runner.
     - Environment variable differences.
3. **Old Backend Decommissioning**:
   - Only after a clean zero-diff plan is confirmed in TFE and verified by the pipeline:
     - Mark legacy storage (e.g., S3 state bucket key) as read-only or archive.

---

## Step 5: Rollback & Contingency Procedure

Every migration plan must document clear rollback steps:
1. Revert the repository code branch to the pre-migration commit (restoring the legacy backend block).
2. Run `terraform init -reconfigure` pointing back to the original backend.
3. If state was modified during migration, restore from the timestamped `terraform_state_backup_<timestamp>.tfstate` file using `terraform state push`.

---

## Step 6: Generate Migration Plan Document

Output the completed migration plan using the standard template:

```markdown
# Migration Plan & State Runbook: <repository-name>

## 1. Scope & Target Architecture
- **Source Repository**: `<repo-path>`
- **Source Backend**: `<s3 | local | azurerm | gcs>`
- **Target TFE Hostname**: `<hostname | NOT SPECIFIED>`
- **Target Organization**: `<tfe-org-name | NOT SPECIFIED>`
- **Target Workspace(s)**:
  - `<workspace-name-1>` (Execution Mode: `remote`, Terraform Version: `>= 1.1.0`)

## 2. Variable Sets & Secret Management
- **Target Variable Sets**: `<list of TFE Variable Sets to attach>`
- **Sensitive Variables to Populate**:
  - `<var_name_1>` (Enter securely in TFE UI / Variable Set)
  - `<var_name_2>` (Enter securely in TFE UI / Variable Set)

## 3. Human-in-the-Loop State Migration Runbook

### Phase A: Pre-Migration Backup
```bash
# 1. Ensure clean git status and checkout migration branch
git checkout -b migration/tfe-<workspace-name>

# 2. Pull and verify the current state backup
terraform state pull > state-backup-$(date +%Y%m%d%H%M%S).tfstate
ls -lh state-backup-*.tfstate
```

### Phase B: State Cutover & Initialization
```bash
# 3. Apply the updated backend configuration (cloud or remote block)
# (Automated via tf-code-migrate)

# 4. Initialize and migrate state to TFE
#    cloud block:            terraform init
#    backend "remote" block: terraform init -migrate-state
#    (Operator answers 'yes' when prompted to copy state. Optional helper:
#     .bob/scripts/tf-cutover-verify.sh --phase migrate --confirm)
terraform init
```

### Phase C: Zero-Diff Plan Verification
```bash
# 5. Run verification plan (exit 0 = zero diff, 2 = drift -> roll back, 1 = error)
terraform plan -detailed-exitcode -no-color

# EXPECTED OUTPUT: 0 to add, 0 to change, 0 to destroy.
```

## 4. Rollback Plan
If plan verification fails or unexpected drift occurs:
```bash
git checkout main
terraform init -reconfigure
# If state restoration is needed:
# terraform state push state-backup-<timestamp>.tfstate
```

## 5. Teardown Runbook (Operator-Run)
*Note: Bob never executes `terraform destroy` or `tfctl ... delete` commands. All decommissioning steps are executed manually by the operator after migration demo completion.*

```bash
# 1. Destroy provisioned infrastructure via TFE workspace runner
terraform destroy

# 2. Decommission legacy CE state storage (e.g. S3 state bucket)
# (Ensure bucket is empty before deleting)
aws s3 rm s3://<state-bucket-name> --recursive
aws s3 rb s3://<state-bucket-name>

# 3. Clean up target TFE platform resources via tfctl (after human review)
tfctl delete workspace -a name="<workspace-name>" -o "<org-name>"
tfctl delete varset -a name="<varset-name>" -o "<org-name>"
```
```
