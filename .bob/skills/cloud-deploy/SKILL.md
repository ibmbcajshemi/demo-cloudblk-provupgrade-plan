---
name: cloud-deploy
description: Use when provisioning, validating, or diagnosing Terraform Enterprise (TFE) platform resources (Workspaces, Projects, Variable Sets) via tfctl or pipeline automation.
---

# `cloud-deploy` Platform Provisioning & Diagnosis (`cloud-deploy`)

This skill handles Level B integration with the Terraform Enterprise (TFE) platform landing zone. It uses `tfctl` or direct API calls to provision or validate Projects, Workspaces, and Variable Sets, and diagnoses plan or configuration output prior to state cutover.

---

## Step 1: Target Resolution & Pre-Flight Verification

Ensure target organization and workspace are specified before running provisioning commands:
1. Target resolution rule: TFE Hostname, Organization, and Workspace name must be explicitly provided or configured in the active `cloud` block.
2. If unspecified, abort with `NOT SPECIFIED`.

---

## Step 2: Workspace & Project Provisioning via `tfctl`

Use `tfctl` to scaffold the destination workspace and enforce organization naming standards:

1. **Dry-Run Validation**:
   ```bash
   tfctl create workspace -a name=<workspace-name> -o <org-name> --dry-run
   ```
2. **Workspace Creation & Execution Mode**:
   - Determine execution mode:
     - `remote` (Default enterprise TFE): Runs execute in TFE container workers (requires cloud credentials in TFE Variable Sets).
     - `local` (Developer / CLI auth): Runs execute locally using local CLI credentials (`az login`, `aws sso`, etc.) while state and locks are stored in TFE.
     - `agent`: Runs execute in a private TFE Agent Pool.
   ```bash
   tfctl create workspace \
     -a name=<workspace-name> \
     -a description="Migrated from CE - <repo-name>" \
     -a execution-mode=<local|remote|agent> \
     -a auto-apply=false \
     -a terraform-version="<version satisfying the repo's required_version>" \
     -o <org-name>
   ```
   The workspace Terraform version must satisfy the repository's `required_version` (read it from the code; for example a repo that needs S3 native locking requires 1.11 or newer). A fixed example such as `>= 1.1.0` can be too low. Use `--json` on `create` to get the new workspace ID from the response.

   *To update an existing workspace's execution mode:*
   ```bash
   tfctl api /workspaces/<workspace-id> -X PATCH -i '{"data":{"attributes":{"execution-mode":"<local|remote|agent>"},"type":"workspaces"}}'
   ```
3. **Project Assignment (Optional)**:
   ```bash
   tfctl api schema search project
   # Assign workspace to designated Project ID if specified
   ```

---

## Step 3: Variable Sets Provisioning & Attachment

1. **Discover Variable Sets**:
   ```bash
   tfctl get varsets -o <org-name> --all --json
   ```
   Do not assume an existing set fits the target. If one is not clearly meant for it, ask the user whether to reuse it or create a new one.
2. **Create a Variable Set shell (no values)**. `-a` only sets attributes, and variable sets need a JSON body (`tfctl create --help`):
   ```bash
   tfctl create varset -o <org-name> --dry-run -i '{"data":{"type":"varsets","attributes":{"name":"<varset-name>","description":"<description>","global":false}}}'
   ```
   Review the dry-run, get the user's approval, then run it without `--dry-run` and add `--json` to read the new ID. The operator enters credential values in the TFE UI as sensitive environment variables. Never put values in the command.
3. **Attach the Variable Set to the workspace.** `tfctl attach` does not exist (tfctl v0.4.0). Use the API operation `applyVarsetToWorkspaces` (find it with `tfctl api schema get applyVarsetToWorkspaces`):
   ```bash
   tfctl api /varsets/<varset-id>/relationships/workspaces -X POST --dry-run -i '{"data":[{"type":"workspaces","id":"<workspace-id>"}]}'
   # after approval, run again without --dry-run (success returns an empty body)
   ```
4. **Verify (read-only)**:
   ```bash
   tfctl api /workspaces/<workspace-id>/varsets --json
   tfctl api /varsets/<varset-id>/relationships/vars --json   # keys, category and sensitive flag only
   ```

---

## Step 4: Diagnostic Analysis of Platform Errors

When platform runs or workspace creation fails:
1. Parse `tfctl` or TFE API HTTP error codes:
   - `401 Unauthorized`: Token missing or expired.
   - `404 Not Found`: Target Organization or Project does not exist.
   - `422 Unprocessable Entity`: Workspace name collision or invalid execution mode.
2. Provide exact remediation steps without modifying local application HCL unnecessarily.
