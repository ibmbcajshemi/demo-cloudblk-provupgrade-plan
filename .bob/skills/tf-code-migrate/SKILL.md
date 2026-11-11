---
name: tf-code-migrate
description: Use when refactoring Terraform Community Edition (CE/OSS) code for Terraform Enterprise (TFE). Automates backend block conversion to cloud or remote blocks, version constraint upgrades, provider pinning, and formatting validation.
---

# Terraform Code Migration & Refactoring (`tf-code-migrate`)

This skill guides the automated, deterministic transformation of Terraform code from Community Edition (CE/OSS) to self-hosted Terraform Enterprise (TFE). It focuses on backend block conversion, core/provider version upgrades, and code validation before creating a Git Pull Request.

---

## Step 1: Pre-Transformation Inspection

### Target Resolution Rule (check before any edit)
The target TFE hostname, organization and workspace must come from the user's request, the repository's own `cloud`/`remote` block, or the `tfctl` profile's `default_organization`. Every angle-bracket value in this skill (for example `<tfe-hostname>`, `<target-org-name>`) is a placeholder, never a default. If the target is not named:
- **Stop before changing the backend block.** Do not create the branch, and do not write a `cloud`/`remote` block containing a guessed or example value.
- Do not choose an organization because it is first in a list, appears accessible, or looks like a good fit.
- Report the target as `NOT SPECIFIED` and ask the user to confirm host, organization and workspace.
- Edits that need no target (for example `required_version` or provider pinning) may proceed only if the user asks for them separately.

Before making edits, inspect the configuration files in the repository:
1. Locate the file containing the `terraform { ... }` configuration block (typically `versions.tf`, `terraform.tf`, or `main.tf`).
2. Identify the active backend configuration and existing version constraints (`required_version` and `required_providers`).
3. Ensure you are on a dedicated migration branch:
   ```bash
   git checkout -b migration/tfe-<workspace-name>
   ```

---

## Step 2: Backend Block Transformation

Replace legacy or local backend blocks with the target TFE configuration.

### S3-to-Cloud Backend Conversion Notes
- When converting from an `s3` backend to a `cloud` (or `backend "remote"`) block, all S3-specific backend arguments (such as `bucket`, `key`, `region`, `dynamodb_table`, `encrypt`, or `use_lockfile`) are removed along with the `backend "s3"` block itself. TFE manages state storage, locking, and encryption natively within the workspace.
- **Lock file & `.gitignore` Handling**:
  - The dependency lock file (`.terraform.lock.hcl`) tracks provider selections and should remain tracked in git.
  - Local state artifacts (`*.tfstate`, `*.tfstate.*`, `.terraform/`, `.state-backups/`) must be included in `.gitignore` so local or pulled state files are never committed to version control.

### Pattern A: Modern `cloud` Block (Recommended for Terraform v1.1.0+)

**Before (CE Local or Remote Cloud Backend):**
```hcl
terraform {
  required_version = ">= 0.14.0"

  backend "s3" {
    bucket = "my-company-tfstate"
    key    = "networking/vpc.tfstate"
    region = "us-east-1"
  }
}
```

**After (TFE `cloud` Block):**
```hcl
terraform {
  required_version = ">= 1.1.0"

  cloud {
    hostname     = "<tfe-hostname>" # Target self-hosted TFE hostname
    organization = "<target-org-name>"

    workspaces {
      name = "<target-workspace-name>"
    }
  }
}
```

---

### Pattern B: Fallback `backend "remote"` Block (For Terraform < v1.1.0 or Specific Workspace Tagging)

**Before (CE Local Backend):**
```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

**After (TFE `backend "remote"` Block):**
```hcl
terraform {
  backend "remote" {
    hostname     = "<tfe-hostname>"
    organization = "<target-org-name>"

    workspaces {
      name = "<target-workspace-name>"
    }
  }
}
```

---

## Step 3: Upgrade Version Constraints & Pin Providers

Upgrade outdated constraints to ensure compliance and avoid known CVEs:

1. **`required_version` Floor**:
   - Ensure `required_version` is set to at least `">= 1.1.0, < 2.0.0"` (or the minimum version mandated by your self-hosted TFE instance).
2. **Provider Source & Version Pinning**:
   - Ensure all providers specify their explicit registry source (e.g., `hashicorp/aws`, `IBM-Cloud/ibm`, `hashicorp/azurerm`).
   - Pin provider versions using pessimistic operator constraints (`~> X.Y.Z`) to prevent unexpected upstream breaking changes.

**Example `versions.tf` Standardized:**
```hcl
terraform {
  required_version = ">= 1.1.0, < 2.0.0"

  cloud {
    hostname     = "<tfe-hostname>"
    organization = "<org-name>"

    workspaces {
      name = "<workspace-name>"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40.0"
    }
  }
}
```

---

## Step 4: Provider Upgrade Procedure (Separate PR)

To isolate risks, **always perform backend migration and provider upgrades in separate PRs**:
- **PR 1**: Backend swap only (`backend` to `cloud` block) + `required_version` baseline. Verified by a zero-diff plan.
- **PR 2**: Provider version upgrade (e.g. AWS 4.x to 5.x) + updated lockfile + migration-driven code refactors.

### Provider Upgrade Workflow
1. **Changelog & Upgrade Guide Review**:
   - Before bumping provider constraints, inspect the provider's official upgrade guide (e.g., HashiCorp AWS Provider v5.x Upgrade Guide) and changelog via registry or Terraform MCP tools.
   - Catalog all deprecated/removed arguments, renamed resources, or default attribute behavior changes affecting the configuration.
2. **Human Approval Gate (PR Review Boundary)**:
   - Modifying provider dependencies and running `terraform init -upgrade` introduces new package downloads and dependency changes (as highlighted in `terraform-devops` section 1).
   - The Pull Request review is the explicit human approval point for the provider version bump and the subsequent `init -upgrade` execution.
3. **Upgrade Provider Constraints & Update Lock File**:
   - Update `required_providers` with the target version constraint (e.g., `version = "~> 5.40.0"`).
   - Re-initialize and upgrade providers:
     ```bash
     terraform init -upgrade
     ```
   - Review the `.terraform.lock.hcl` diff to confirm exact provider versions and checksums recorded.
4. **Plan Comparison & Speculative Run**:
   - Run a speculative plan through the new backend:
     ```bash
     terraform plan -detailed-exitcode -no-color
     ```
   - Analyze plan output for any unexpected attribute replacements, in-place updates, or resource recreations triggered by provider schema changes. Attach the summary counts to PR 2.

---

## Step 5: Private Module Registry (PMR) Refactoring (If Applicable)

If modules are being migrated to the internal TFE Private Module Registry:
- Rewrite public or Git module sources:
  - **Before:** `source = "git::https://github.com/myorg/terraform-aws-vpc.git?ref=v2.1.0"`
  - **After:** `source = "<tfe-hostname>/<org-name>/vpc/aws"` and set `version = "2.1.0"`

---

## Step 6: Code Formatting & Syntax Validation

After applying edits, validate the changes locally without modifying state:

1. **Format Code**:
   ```bash
   terraform fmt -recursive
   ```
2. **Validate Syntax & Providers**:
   ```bash
   terraform init -backend=false -input=false
   terraform validate
   ```
3. **Optional Gate Verification**:
   - If `/terraform-devops` or `validate.sh` is present, run the validation gates (fmt, init, validate, tflint).

---

## Step 7: Commit and Create Pull Request

1. Review the git diff:
   ```bash
   git diff
   ```
2. Commit the changes:
   ```bash
   git add .
   git commit -m "refactor(terraform): migrate backend configuration to Terraform Enterprise"
   ```
3. Push branch and prepare Pull Request for human review:
   ```bash
   git push origin migration/tfe-<workspace-name>
   ```
4. Output the Pull Request description template summarizing what changed, the validation status, and the link to the generated state migration runbook.
