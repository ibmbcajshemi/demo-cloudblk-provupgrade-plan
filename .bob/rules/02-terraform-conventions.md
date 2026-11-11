# Terraform & TFE Migration Conventions

## 1. Backend Block Standards
Values in angle brackets are placeholders. Take the real host, organization and workspace from the user's request, the repository's existing `cloud`/`remote` block, or the `tfctl` profile. If none supplies them, report the target as `NOT SPECIFIED`; never copy a placeholder into a real file.

- **Modern Target (Terraform v1.1.0+)**: Prefer the top-level `cloud` block:
  ```hcl
  terraform {
    cloud {
      hostname     = "<tfe-hostname>" # Target self-hosted TFE hostname
      organization = "<org-name>"

      workspaces {
        name = "<workspace-name>"
      }
    }
  }
  ```
- **Legacy Target (Terraform < v1.1.0 or Remote Backend Pattern)**: Use `backend "remote"`:
  ```hcl
  terraform {
    backend "remote" {
      hostname     = "<tfe-hostname>"
      organization = "<org-name>"

      workspaces {
        name = "<workspace-name>"
      }
    }
  }
  ```

## 2. Version Pinning Rules
- **Terraform Core**: Ensure `required_version` satisfies target TFE minimum requirements (e.g., `>= 1.1.0, < 2.0.0`).
- **Providers**: Ensure all providers in `required_providers` have explicit source addresses and pinned pessimistic version constraints (`~> X.Y.Z`).

## 3. Formatting and Linting
- All modified HCL files must pass canonical formatting: `terraform fmt -check`.
- Configurations should pass syntax and internal reference validation: `terraform validate`.

## 4. State Migration Command Sequence
The authoritative cutover sequence (backup, checksum, init, zero-diff plan, rollback) is defined in `03-cutover-verification.md`. Every generated runbook must follow it exactly; do not restate or vary the commands here.
