---
name: tf-inventory
description: Use when analyzing a Terraform repository for migration from Community Edition (CE/OSS) to Terraform Enterprise (TFE). Scans backends, provider/CLI versions, modules, variables, and platform alignment via tfctl.
---

# Terraform Estate Inventory & Pre-Migration Validation (`tf-inventory`)

This skill performs a read-only, deterministic discovery of a Terraform codebase to evaluate its readiness for migration to Terraform Enterprise (TFE). It assesses backend configurations, version compatibility, module dependencies, variable sources, and target platform alignment.

---

## Step 1: Scan for Backend Configurations

Inspect all `.tf` files in the repository root and subdirectories to identify how state is currently managed.

1. Search for `terraform { ... backend "<type>" ... }` or `cloud` blocks.
2. Record the backend type:
   - `local`: State stored in `terraform.tfstate`.
   - `s3`, `azurerm`, `gcs`, `consul`, `http`, etc.: Remote cloud backend.
   - `remote`: Legacy TFE/HCP backend block.
   - `cloud`: Modern TFE/HCP cloud block.
   - None found: Defaults to local state.
3. Record backend configuration attributes (e.g., bucket name, workspace prefix, key paths).

---

## Step 2: Extract Version Constraints & Pre-Migration Checks

Evaluate whether the repository meets minimum version requirements as mandated by enterprise compliance and TFE platform compatibility:

1. **Terraform Core Version**:
   - Check `required_version` in `terraform { ... }`.
   - **Target Rule**: Modern `cloud` blocks require Terraform CLI `>= 1.1.0`. Flag any repository targeting `< 1.1.0` as requiring a core version upgrade.
2. **Provider Requirements & Version Verification**:
   - Parse `required_providers` blocks for:
     - Explicit source namespaces (e.g., `hashicorp/aws` vs legacy bare `aws`).
     - Version constraints (e.g., pinned `~> 5.0` vs unbounded/unpinned).
     - Identify deprecated providers or providers requiring version upgrades to address known CVEs.
     - A provider that is explicitly sourced and pessimistically pinned is `OK`.
   - **Provider Version Lookup via Terraform MCP Server / Registry**:
     - When the `terraform` MCP server is connected, use its registry tools (e.g., `get_latest_provider_version`, `get_provider_details`) or query the public Terraform Registry to verify the current latest release, major version upgrade paths, and deprecations.
     - When verified via MCP/Registry or `check_package_vulnerabilities`, record the exact verified latest version and upgrade guidance.
     - Never assert a "latest version" from memory. If the MCP server is not connected and registry lookup is not possible, explicitly report the status as "not verified".
3. **Module Sources**:
   - Inspect all `module "..." { source = "..." }` declarations.
   - Categorize module sources:
     - Local relative paths (`./modules/...`).
     - Public Terraform Registry (`terraform-aws-modules/...`).
     - Git / VCS repositories (`git::https://...` or `git@...`).
     - Private Module Registry (PMR) (`<hostname>/<org>/<module>/<provider>`).

---

## Step 3: Scan Variable & Secret Sources

Identify where configuration inputs and credentials originate:

1. Locate input variable declarations (`variables.tf` or `*.tf`).
2. Search for variable definitions files (`*.tfvars`, `*.tfvars.json`, `terraform.tfvars`).
3. **Sensitive Data Detection**:
   - **Never print a secret value.** Report the file, line and variable name only, and describe the finding (for example "hardcoded default", "plaintext assignment"). Do not quote the line, and do not reproduce the value, even if it is labelled fake, test or placeholder.
   - If a `.tfvars` file holding a secret is tracked in git (`git ls-files`), say so. Adding it to `.gitignore` does not untrack it, so the action item must be to remove it from the index and rotate the credential.
   - Check for hardcoded credentials, plain API keys, or embedded tokens in `.tf` and `.tfvars` files.
   - Identify variables marked `sensitive = true` or containing sensitive naming conventions (`password`, `secret`, `token`, `key`).
   - Flag variables that must be migrated to **TFE Variable Sets** instead of code.

---

## Step 4: Live TFE Grounding & Fallback Discovery Strategy

Determine the availability of live platform tools and apply the appropriate discovery strategy:

### Target Resolution Rule (applies to every mode)
The target TFE hostname, organization and workspace must come from the user's request, the repository's own `cloud`/`remote` block, or the `tfctl` profile's `default_organization`. If none of these names an organization:
- **Do not choose one.** Never pick an organization because it is first in a list, appears accessible, or looks like a good fit.
- **Do not run workspace-collision checks**, since a result for an arbitrary organization says nothing about the real target.
- **Do not list the organizations visible to the credentials** in the report.
- Report the target as `NOT SPECIFIED`, present any workspace name as a proposal only, and list "confirm target host, organization and workspace" as an action item.
- Read-only checks that need no organization (for example `tfctl api schema search`) are still allowed.

### Mode A: `tfctl` Available (Preferred)
If `tfctl` is installed and authenticated to target TFE (commands verified against `tfctl` v0.4.0; JSON output is requested with `--json`, and `tfctl --help` shows the syntax of other versions):
1. Verify target organization availability:
   ```bash
   tfctl get organizations --json
   ```
2. Inspect existing workspaces to avoid naming collisions:
   ```bash
   tfctl get workspaces -o <ORG_NAME> --all --json
   ```
3. Discover API schemas for target resources:
   ```bash
   tfctl api schema search workspace
   ```

### Mode B: Direct TFE API / curl Fallback (When `tfctl` is not installed, but `TFE_TOKEN` is present)
If `tfctl` is unavailable, standard HTTP API calls can be used:
1. Validate organization access:
   ```bash
   curl -s -H "Authorization: Bearer $TFE_TOKEN" \
     -H "Content-Type: application/vnd.api+json" \
     https://<TFE_HOSTNAME>/api/v2/organizations/<ORG_NAME>
   ```
2. List workspaces:
   ```bash
   curl -s -H "Authorization: Bearer $TFE_TOKEN" \
     -H "Content-Type: application/vnd.api+json" \
     https://<TFE_HOSTNAME>/api/v2/organizations/<ORG_NAME>/workspaces
   ```

### Mode C: Pure Static Discovery (No TFE Connectivity / Offline / Pre-Onboarding)
If neither `tfctl` nor live API connectivity is available (e.g., consumer-side pre-migration analysis):
1. **Rely entirely on static code heuristics**: Infer workspace names from Git repository names, directory structures, environment prefixes (`dev`, `stage`, `prod`), or local backend workspace tags.
2. **Standard Terraform CLI inspection**:
   - `terraform version`
   - `terraform providers`
   - `terraform fmt -check`
3. **Template-Driven Recommendations**: Generate recommended workspace names and configuration blocks using enterprise naming conventions (e.g., `<app-name>-<env>-<region>`) and flag live TFE verification as a post-PR pipeline task.

---

## Step 5: Save & Present Inventory Report

1. **Format Output Path**:
   - Construct the report path with repository name and timestamp:
     `reports/inventory-<repo_slug>-<YYYYMMDD-HHMMSS>.md` (e.g., `reports/inventory-app-azure-20261106-054500.md`).
2. **Persist the Report**:
   - Use `write_file` to save the complete Markdown report to the constructed path.
3. **Present Summary & Link**:
   - Present the report content in the conversation response and provide a clickable markdown link to the saved file: `[reports/inventory-...](reports/inventory-...)`.

### Output Report Template

```markdown
# Terraform Estate Inventory & Pre-Migration Assessment

## 1. Executive Summary
- **Repository**: `<repo-name>`
- **Current Backend**: `<local | s3 | azurerm | gcs | none>`
- **Terraform Core Version Constraint**: `<version>` (Upgrade Required: Yes/No)
- **Migration Readiness**: `<READY | ACTION_REQUIRED | BLOCKED>`

## 2. Backend & State Assessment
- **Backend Type**: `<backend_type>`
- **Configuration Details**: `<bucket / path / region>`
- **Target TFE Block Recommendation**: `<cloud block | backend "remote">`
- **Target Workspace Name**: `<recommended-workspace-name>`

## 3. Providers & Version Compatibility
| Provider | Source Address | Constraint | Status / Upgrade Recommendation |
| :--- | :--- | :--- | :--- |
| `<name>` | `<source>` | `<version>` | `<OK | Needs Upgrade | Unpinned>` |

## 4. Module Dependencies
| Module Name | Source Type | Current Source | Target Recommendation |
| :--- | :--- | :--- | :--- |
| `<module_name>` | `<Local / Public / Git / PMR>` | `<source_path>` | `<No Change / Rewrite to PMR>` |

## 5. Variables & Sensitive Data
- **Total Variables Declared**: `<count>`
- **Sensitive Variables Identified**: `<list of sensitive variable names>`
- **Plaintext Secrets in Files**: `<None Found | Flagged in file:line>`
- **Recommended TFE Variable Sets**: `<list of recommended variable sets>`

## 6. Pre-Migration Action Items
1. `[ ]` <Action item 1, e.g., Upgrade required_version to >= 1.1.0>
2. `[ ]` <Action item 2, e.g., Move sensitive variables to TFE Variable Set>
3. `[ ]` <Action item 3, e.g., Prepare state backup before cutover>
```
