# Terraform Estate Inventory & Pre-Migration Assessment

Generated: 2026-11-10 22:47 (local time). Scope: read-only. Nothing was created, changed or deleted.

## 1. Executive Summary
- **Repository**: `demo-cloudblock-providerupgrade` (module in `infra/`), inventoried at tag `baseline-s3-aws4` (commit `cdff073`). `git diff` of `infra/` against that tag is empty, so the code matches the baseline.
- **Current Backend**: `s3` (native S3 locking, `use_lockfile = true`)
- **Terraform Core Version Constraint**: `>= 1.11.0, < 2.0.0` (Upgrade Required: No. This already satisfies the `cloud` block floor of 1.1.0. Local CLI is 1.14.3.)
- **Target (confirmed by the user)**: `app.terraform.io` / org `tce-to-tfe-migration` / workspace `demo-cloudblk-provupgrade`
- **Migration Readiness**: `ACTION_REQUIRED`. Nothing in the code blocks the migration. The target workspace and its credentials do not exist yet (items 1 to 5 in section 6).

## 2. Backend & State Assessment
- **Backend Type**: `s3`
- **Configuration Details**: bucket `statebucket-ajs11102026`, key `demo-cloudblk-provupgrade/terraform.tfstate`, region `us-east-1`, `encrypt = true`, `use_lockfile = true`. The state bucket has versioning enabled.
- **Live state (verified read-only as `ajs-nonroot`)**: 5 resources, serial 1, written by Terraform 1.14.3. `terraform plan -detailed-exitcode` returned exit 0 (`No changes`). A manual reference copy of the state exists outside the repo with SHA-256 `47dce3e5fa05f6504b049cbee940f0d25d92f7ae4d1284c7fdf4ee327c79b18c`.
- **Target TFE Block Recommendation**: `cloud` block. Terraform is above 1.1.0, so the legacy `backend "remote"` block is not needed.
- **Target Workspace Name**: `demo-cloudblk-provupgrade`
- **Workspace name collision check**: none. The org `tce-to-tfe-migration` has 4 workspaces and none is named `demo-cloudblk-provupgrade` or similar. The workspace does not exist yet.
- **Does state change?** Not known until the cutover. The backend swap copies state with the same resources. The state's `serial` and `lineage` may change, and that has not been measured. The provider upgrade is the step more likely to change state contents.

## 3. Providers & Version Compatibility
| Provider | Source Address | Constraint | Status / Upgrade Recommendation |
| :--- | :--- | :--- | :--- |
| `aws` | `hashicorp/aws` | `~> 4.67.0` (lock file: `4.67.0`) | `OK` for the backend swap. A provider upgrade is a separate PR (sub-task 7). |

Version facts, from the public Terraform Registry API (the MCP server was not used, see section 7):
- `4.67.0` is the last 4.x release.
- Latest stable per major: `5.100.0` and `6.72.0`. The latest stable overall is `6.72.0`.
- Next major from the baseline is 5.x. Moving to 6.x would skip a major. Which target to use is a decision for sub-task 7 and needs the upgrade guides read first. Breaking changes for this configuration have not been checked.

Vulnerability check:
- One query to OSV.dev for `github.com/hashicorp/terraform-provider-aws` at `4.67.0` (Go ecosystem) returned 0 advisories. This is a single lookup, not an exhaustive audit.
- The `check_package_vulnerabilities` tool does not support the Go ecosystem. My first attempt used the wrong ecosystem and returned an error, so the OSV API was queried directly instead.
- No CVE or deprecation was found that forces an upgrade. The upgrade in this demo is a demonstration choice, not a security fix.

## 4. Module Dependencies
| Module Name | Source Type | Current Source | Target Recommendation |
| :--- | :--- | :--- | :--- |
| none | n/a | No `module` blocks | No Change |

## 5. Variables & Sensitive Data
- **Total Variables Declared**: 3 (`region`, `name_prefix`, `demo_bucket_name`). All have defaults.
- **Sensitive Variables Identified**: none. None is marked `sensitive = true` and none looks like a secret by name.
- **Plaintext Secrets in Files**: none found by pattern scan of `infra/*.tf` (access keys, passwords, tokens, private keys). No `.tfvars` or `.tfvars.json` file is tracked in git.
- **Provider credentials**: the `aws` provider block has no credential arguments. It relies on the default credential chain, so a remote run needs `AWS_*` environment variables supplied by a Variable Set.
- **Existing Variable Set in the org**: one set named `aws-credentials` (not global). Its contents were not inspected and nothing says it is meant for this demo. Whether to reuse it or create a new one is a decision for sub-task 4.
- **Recommended TFE Variable Sets**: one set holding the AWS credentials as sensitive environment variables, attached to `demo-cloudblk-provupgrade`. The operator enters the values in the TFE UI. Terraform variables need no Variable Set because the defaults are fine.

## 6. Pre-Migration Action Items
1. `[ ]` Create workspace `demo-cloudblk-provupgrade` (remote execution, auto-apply off) after a `tfctl ... --dry-run` review and your approval (sub-task 4).
2. `[ ]` Set the workspace Terraform version so it satisfies `>= 1.11.0`. The `cloud-deploy` skill's example value `>= 1.1.0` would not guarantee that. Confirm the value with the dry-run.
3. `[ ]` Decide which Variable Set holds the AWS credentials: reuse `aws-credentials` or create a new one. Do not assume the existing one is correct.
4. `[ ]` **Credential lifetime.** The credentials used so far came from a login session with a session token, which expires. A TFE workspace needs credentials that stay valid across runs: long-lived keys for a dedicated IAM user, or dynamic credentials. Choose before the first remote plan.
5. `[ ]` Do not reuse the `tfe-s1-aws-upgrade` user by default. It belongs to an earlier project, was denied access to the state bucket, and its permissions for creating buckets, parameters and topics have not been checked.
6. `[ ]` The operator needs Terraform CLI access to `app.terraform.io` for the `cloud` block `init` (`terraform login`, or the `TF_TOKEN_app_terraform_io` environment variable). A `TFE_TOKEN` variable is set in this shell and `tfctl` works with it. I have not verified that the Terraform CLI honours `TFE_TOKEN`, so do not rely on it.
7. `[ ]` Take the state backup on the S3 backend before the backend swap (`tf-cutover-verify.sh --phase backup`), as the cutover rules require.
8. `[ ]` Complete the AWS cost check (S3, SSM Parameter Store, SNS). It is still unverified.
9. `[ ]` Add the `terraform` MCP server's Docker image to the setup if you want registry lookups through MCP. See section 7.

## 7. Evidence and What Was Not Verified
- **tfctl**: v0.4.0, authenticated (`TFE_TOKEN` is set; the value was not read). Org-scoped read-only calls to `tce-to-tfe-migration` succeeded: workspaces, Variable Sets and projects (one project, `Default Project`).
- **Terraform MCP server**: configured in `.bob/mcp.json`, but not shown to be connected. The Docker image `hashicorp/terraform-mcp-server` is not pulled locally and no container is running. Provider versions here come from the registry API directly.
- **AWS pricing**: not verified.
- **Breaking changes between provider majors**: not checked.
- **Existing Variable Set contents and the other three workspaces**: not inspected beyond names and settings.
