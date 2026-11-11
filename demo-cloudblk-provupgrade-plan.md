# Demo Plan: Terraform CE (S3 backend) to HCP Terraform with AWS Provider Upgrade

## Top-Level Overview

**Goal.** Demonstrate an end-to-end Terraform CE to TFE migration on real, very cheap AWS infrastructure using the `tf-migrator` mode and the skills `tf-inventory`, `tf-migration-plan`, `tf-code-migrate` (plus `cloud-deploy`), with `tfctl`, the Terraform MCP server and `terraform-devops`. The demo covers a backend change (S3 to `cloud` block) and an AWS provider upgrade. Every code change goes through a PR reviewed by a human.

**Confirmed target (from the user).**

| Item | Value |
| :--- | :--- |
| TFE hostname | `app.terraform.io` (HCP Terraform) |
| Organization | `tce-to-tfe-migration` |
| Workspace | `demo-cloudblk-provupgrade` (not yet created; created in sub-task 4) |
| Execution mode | `remote` |
| Source backend | S3 bucket with native S3 locking |
| Credentials | AWS credentials entered by the operator as sensitive environment variables in a TFE Variable Set via the UI. Never in files, chat or logs. |

**Approach.**
- Two separate PRs: PR 1 swaps the backend only; PR 2 upgrades the AWS provider only. This isolates which change, if any, alters state or produces a plan diff.
- State handling is unknown up front. A backend swap copies state as is (serial and lineage metadata change, resources do not). A provider upgrade can rewrite attributes to the new schema on the next apply or refresh. The demo is designed to observe and report this, not to assume it.
- Bob never runs `apply`, `destroy`, `state rm`, or any `tfctl ... delete` (see `.bob/rules/01-safety-guardrails.md`). Applies, state migration and teardown are operator-run runbook steps.
- Zero-diff gate: `terraform plan -detailed-exitcode` must give exit 0 after PR 1 (see `.bob/rules/03-cutover-verification.md`).

**Cheap AWS resource set (proposal; pricing to be verified against AWS docs in sub-task 2).**
- State bucket for the CE backend: one S3 bucket, versioning on, created by the operator outside the demo config.
- Demo config: one empty S3 bucket (public access block, versioning, separate `aws_s3_bucket_*` resources), one standard-tier SSM parameter, one SNS topic.
- Nothing with an hourly charge (no EC2, NAT, RDS, load balancers).

**Decisions confirmed by the user.**
1. Two PRs (backend, then provider) rather than one.
2. AWS region `us-east-1`.
3. Include an optional negative test: a resource rename without a `moved` block (sub-task 6b).
4. Skill and tooling fixes (sub-task 1) are done first.
5. Plan approved for implementation.

**Still to be supplied by the user (needed before sub-tasks 2 and 6).**
1. Git remote URL for the demo repo, so PRs can be opened. The current workspace has no Terraform code and appears as an untracked folder in a parent repository.
2. A globally unique state bucket name.

---

## Sub-Tasks

### Sub-task 1: Fix skill and tooling gaps

**Status:** [x] done

**Intent.** The reviewed skills have gaps that would stall or contradict the demo. Fix them before using them, and record what changed so the demo shows improved skills.

**Expected Outcomes.**
- The skills describe a provider-upgrade procedure and an S3-to-`cloud` conversion.
- The Terraform MCP server is configured (read-only) and referenced where a provider version lookup is needed.
- `tf-migrator` mode can edit the files the demo needs.
- The `terraform-devops` stop-and-ask rules and the migration skills agree.

**Todo List.**
1. `[x]` `tf-code-migrate/SKILL.md`: add a provider-upgrade section covering changelog and upgrade guide review, `init -upgrade`, `.terraform.lock.hcl` diff review, plan comparison, and the rule that backend swap and provider upgrade are separate PRs.
2. `[x]` `tf-code-migrate/SKILL.md`: add S3-to-`cloud` notes (S3-specific arguments such as bucket, key and lock settings are removed with the block; lock file and `.gitignore` handling).
3. `[x]` `tf-migration-plan/SKILL.md`: make the ordering explicit (backup on the legacy backend first, then `init`), and tie the execution-mode choice to the credential strategy (remote execution needs an AWS Variable Set attached before the verification plan).
4. `[x]` `tf-inventory/SKILL.md`: add a provider version lookup step using the Terraform MCP server (`get_latest_provider_version`, `get_provider_details`) or the registry, replacing the "not verified" fallback when the server is connected.
5. `[x]` `.bob/mcp.json`: add the `terraform` server from the `terraform-devops` asset `assets/mcp.docker.json` (public Registry tools only). Do not add `alwaysAllow`. Do not set `ENABLE_TF_OPERATIONS`. Report "configured" and "connected" separately.
6. `[x]` `.bob/custom_modes.yaml`: extend the `tf-migrator` edit `fileRegex` narrowly to allow `.gitignore` and `.terraform.lock.hcl`.
7. `[x]` Add a note to the migration skills that the PR review is the human approval point for the provider bump and `init -upgrade` required by `terraform-devops` section 1.
8. `[x]` Add a teardown runbook template to `tf-migration-plan` (operator-run destroy, then removal of the state bucket and workspace).

**Completed Changes & Context for Sub-task 2:**
- `.bob/skills/tf-code-migrate/SKILL.md`: Added S3-to-cloud conversion details (removal of S3 arguments, lock file and `.gitignore` practices) and Step 4 dedicated to the two-PR workflow and provider upgrade procedure (changelog review, PR approval gate, `init -upgrade`, lockfile diff, plan review).
- `.bob/skills/tf-migration-plan/SKILL.md`: Explicitly tied remote execution mode to pre-plan Variable Set attachment, specified legacy backend backup before init, highlighted human approval at PR review, and added Section 5 Teardown Runbook template for operator execution.
- `.bob/skills/tf-inventory/SKILL.md`: Added registry and Terraform MCP server provider lookup instructions.
- `.bob/mcp.json`: Configured the read-only `terraform` server (`hashicorp/terraform-mcp-server:1.3.0` with `--toolsets=registry`), without `alwaysAllow` and without `ENABLE_TF_OPERATIONS`.
- `.bob/custom_modes.yaml`: Extended `fileRegex` in `tf-migrator` to `"(.*\\.(tf|tfvars|yaml|yml|json|hcl|sh|md)$|.*\\.gitignore$)"` to support editing `.gitignore` and `.terraform.lock.hcl`.
- **Note for Sub-task 2 baseline**: When creating baseline configs in sub-task 2, ensure `hashicorp/aws` 4.x is explicitly sourced and `.gitignore` ignores `.terraform/`, `*.tfstate*`, and `.state-backups/`, while `.terraform.lock.hcl` remains version-controlled.

---

### Sub-task 2: Build the CE baseline (S3 backend, older AWS provider)

**Status:** [x] done, except the AWS cost check, which remains unverified (see below)

**Progress so far.**
- Done: `infra/` root module written (`versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`); S3 backend with `use_lockfile = true`; `hashicorp/aws` `~> 4.67.0` (4.67.0 is the latest 4.x per the public registry); `.terraform.lock.hcl` generated for `darwin_arm64` and `linux_amd64`; `terraform fmt -check` and `validate` pass (init used `-backend=false`).
- Done: `baseline-runbook.md` (operator-run bucket creation, init, plan, apply, state list, tag).
- Verified: state bucket name `statebucket-ajs11102026` returned 404 on `head-bucket` (name appears free); Terraform v1.14.3 installed; native S3 locking (`use_lockfile`) is documented as GA in the Terraform v1.11 changelog.
- Done: separate git repo in this folder, branch `main`, `origin` = `https://github.com/ibmbcajshemi/demo-cloudblk-provupgrade-plan.git`. Local commits `fe8171a` (Bob bundle, skills, plan) and `cdff073` (infra baseline, `baseline-runbook.md`, `.gitignore`, `infra/.terraform.lock.hcl`). Annotated tag `baseline-s3-aws4` on `cdff073`. Nothing is pushed. `.gitignore` was created by the user because the tool's ignore-pattern guard blocked the write.
- Done: operator ran the baseline (5 added, 0 changed, 0 destroyed). Bob independently verified read-only as `ajs-nonroot` (account `725925681035`, via profile `ajs-demo`): `terraform state list` shows 5 resources; `terraform plan -detailed-exitcode` gives `No changes`, exit 0; state serial is 1, Terraform version 1.14.3; the state object exists in `s3://statebucket-ajs11102026/demo-cloudblk-provupgrade/` (8482 bytes) and the state bucket has versioning enabled; the demo bucket, SSM parameter (Standard, String) and SNS topic exist.
- Credentials issues found along the way are documented in `baseline-runbook.md` (login session not visible to Terraform; wrong IAM user gave a 403; `aws login` refused on a profile with static keys).
- Not done: AWS cost check. Pricing pages could not be parsed, so costs stay marked unverified in `baseline-runbook.md`. The user should confirm against the S3, Systems Manager Parameter Store and SNS pricing pages.
- Done: baseline state reference saved by the user outside the repo at `~/demo-state-backups/baseline-s3-aws4-20261110223848.tfstate` (8483 bytes, serial 1, 5 resources, Terraform 1.14.3), permissions tightened to 600 (directory 700). SHA-256 `47dce3e5fa05f6504b049cbee940f0d25d92f7ae4d1284c7fdf4ee327c79b18c`, verified by Bob against the file. This is the pre-migration reference for the "did state change?" comparison in sub-tasks 6 and 7. It is a manual reference only; the cutover backup is still taken by `tf-cutover-verify.sh --phase backup`, which records its own checksum in `.state-backups/`.
- Context for sub-task 3: inventory the repo at tag `baseline-s3-aws4`. Backend: `s3`, bucket `statebucket-ajs11102026`, key `demo-cloudblk-provupgrade/terraform.tfstate`, `use_lockfile = true`. `required_version` `>= 1.11.0, < 2.0.0`. Provider `hashicorp/aws` `~> 4.67.0` (lock file `4.67.0`; 4.67.0 is the latest 4.x per the public registry, and the latest stable overall was reported as 6.72.0 at that time; re-verify through the MCP server or registry before recommending a target). No modules. Variables have defaults and no sensitive values. `.vscode/` is untracked and intentionally excluded.
- Note: the parent repo's `.gitignore` ignores `.terraform.lock.hcl` and `*.tfvars`. A nested repo in this folder will not inherit those rules, and the lock file must be committed for the provider-upgrade PR.

**Intent.** Create a realistic CE starting point that has real state in S3, so the migration moves actual state.

**Expected Outcomes.**
- A root module on a branch/commit representing "before migration", with an S3 backend, an explicit `hashicorp/aws` source and a pinned 4.x provider.
- A runbook for the operator to create the state bucket, apply the baseline, and confirm resources exist.
- A `.gitignore` covering `.terraform/`, state files, plan files and `.state-backups/`.
- Cost statement for each resource, verified against AWS documentation.

**Todo List.**
1. Confirm region, state bucket name, and the exact 4.x provider version (use the Terraform MCP server or registry; do not assert from memory).
2. Confirm the Terraform CLI version supports the chosen S3 locking setting (native S3 locking requires a recent Terraform release; verify in documentation).
3. Write the root module (`versions.tf`, `main.tf`, `variables.tf`, `outputs.tf`, `.gitignore`) using the cheap resource set.
4. Run `terraform fmt` and `terraform init -backend=false` plus `validate` (via `terraform-devops` `validate.sh` if available).
5. Write the operator runbook: create state bucket (versioning on), `terraform init`, `plan`, `apply`, `state list`. Bob does not run these.
6. Tag the baseline commit so rollback has a known good target.

**Relevant Context.**
- `.bob/rules/02-terraform-conventions.md` (version pinning, formatting), `terraform-devops` section 2 (naming, no credentials in code).
- Credentials come from the operator's shell environment or AWS profile; nothing is written to files.

---

### Sub-task 3: Run `tf-inventory`

**Status:** [x] done (with the gaps listed below)

**Result.** Report: `reports/inventory-demo-cloudblk-provupgrade-20261110-224722.md`. Readiness `ACTION_REQUIRED`: no code blocker; the workspace and its credentials do not exist yet.
- Verified: no name collision in org `tce-to-tfe-migration` (4 existing workspaces, none similar); no modules; 3 variables, none sensitive; no secrets found in `infra/*.tf`; no tracked `.tfvars`; code identical to tag `baseline-s3-aws4`; registry shows 4.67.0 is the last 4.x, latest stable 5.x is 5.100.0, latest stable overall is 6.72.0; OSV returned 0 advisories for 4.67.0 (single lookup).
- Not verified: Terraform MCP server (configured, Docker image not pulled, not shown connected); AWS pricing; breaking changes between provider majors; contents of the existing `aws-credentials` Variable Set.
- Context for sub-task 4: an org Variable Set named `aws-credentials` already exists (not global). Do not assume it fits; ask the user whether to reuse it or create a new one. Session credentials from `aws login` expire, so the Variable Set needs long-lived keys for a dedicated IAM user or dynamic credentials. The workspace Terraform version must satisfy `>= 1.11.0` (the `cloud-deploy` skill example `>= 1.1.0` is too low). Do not use `tfe-s1-aws-upgrade` by default. The Terraform CLI needs its own TFE token for the `cloud` block `init`; `TFE_TOKEN` working with `tfctl` does not prove the CLI honours it.

**Intent.** Produce the read-only pre-migration assessment for the baseline.

**Expected Outcomes.**
- `reports/inventory-<repo_slug>-<YYYYMMDD-HHMMSS>.md` with backend, version, provider, module and variable findings.
- Target recorded as `app.terraform.io` / `tce-to-tfe-migration` / `demo-cloudblk-provupgrade`.
- Provider upgrade recommendation backed by a verified source (MCP or registry), not memory.
- No secret values printed.

**Todo List.**
1. Activate `tf-inventory` in `tf-migrator` mode.
2. Scan backend, `required_version`, providers, modules, variables.
3. Use `tfctl` to check for a workspace name collision in `tce-to-tfe-migration` (read-only, `--json`).
4. Use `check_package_vulnerabilities` or the registry for provider findings where applicable.
5. Save the report and list action items.

**Relevant Context.** `.bob/skills/tf-inventory/SKILL.md` Steps 1 to 5 and the report template.

---

### Sub-task 4: Provision the TFE workspace and Variable Set (human approved)

**Status:** [x] done (the AWS key is untested until the first remote plan; see below)

**Result so far (created after the user's explicit approval, `terraform-version` 1.14.3).**
- Workspace `demo-cloudblk-provupgrade`, id `ws-EBiJXXTP3UDJrDFG`, org `tce-to-tfe-migration`: `execution-mode` remote, `auto-apply` false, `terraform-version` 1.14.3, unlocked, 0 resources.
- Variable Set `demo-cloudblk-provupgrade-aws`, id `varset-GmkbFgMHSLvmjiRE`, not global, created empty (0 variables).
- Attachment done with API operation `applyVarsetToWorkspaces` (`tfctl attach` does not exist in v0.4.0). Verified read-only: the workspace lists exactly this Variable Set, and the set shows `workspace-count` 1.
- Not touched: the other four workspaces and the existing `aws-credentials` Variable Set (2 variables, 1 workspace).
- `cloud-deploy/SKILL.md` fixed: removed the non-existent `tfctl attach varset`, added the varset create and attach steps with dry-run first, added a verify step, and replaced the fixed `>= 1.1.0` example with "a version satisfying the repo's required_version".

**Operator steps completed.**
1. The operator created IAM user `demo-cloudblk-provupgrade-tfe` with inline policy `demo-cloudblk-provupgrade` (from `iam/demo-cloudblk-provupgrade-policy.json`) and one long-lived access key. The two accidental extra keys were deleted.
2. The operator added `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to the Variable Set in the UI (category env, both sensitive). Bob verified names, category and the sensitive flag read-only; Bob never reads values.

**Not verified.**
- The access key itself is untested: Bob cannot read it. The first remote plan is the real test.
- Policy coverage is untested. The policy is scoped to the demo bucket, the SSM parameter path and the SNS topic, with NO access to the state bucket (after the cutover the state lives in HCP Terraform, and the migrating `init` runs locally with the operator's own credentials; an earlier note saying otherwise was wrong). `iam simulate-custom-policy` allowed all 11 expected actions and implicitly denied 6 out-of-scope actions, but simulation does not prove the AWS provider's real call set is covered. An AccessDenied on the first remote plan means the policy needs another action. Account ID and resource names are hardcoded in the file.
- The Terraform CLI token for `app.terraform.io` (`terraform login` or `TF_TOKEN_app_terraform_io`) is not verified. `TFE_TOKEN` works with `tfctl` only.

**Intent.** Create `demo-cloudblk-provupgrade` and a Variable Set for AWS credentials without exposing secrets.

**Expected Outcomes.**
- Dry-run output for workspace creation reviewed by the user.
- Workspace created (remote execution, auto-apply off) only after the user approves; HCP Terraform writes are on the "ask first" list in `terraform-devops` section 8.
- A Variable Set shell exists with names of the AWS environment variables marked sensitive; the operator enters the values in the UI.
- Variable Set attached to the workspace.

**Todo List.**
1. Run `tfctl api schema search workspace` and `tfctl api schema search varset` to confirm payload fields.
2. Run `tfctl create workspace -a name=demo-cloudblk-provupgrade -o tce-to-tfe-migration --dry-run`; present to the user.
3. After approval, create the workspace with `execution-mode=remote` and `auto-apply=false`.
4. Create the Variable Set and attach it (dry-run first). Do not set any value.
5. Operator populates the AWS credential values in the UI.

**Relevant Context.** `.bob/skills/cloud-deploy/SKILL.md` Steps 2 and 3; `.bob/rules/01-safety-guardrails.md` sections 2 and 3. Never run `tfctl ... delete`.

---

### Sub-task 5: Generate the migration plan and runbook (`tf-migration-plan`)

**Status:** [x] done. Runbook: `reports/migration-plan-demo-cloudblk-provupgrade-20261110-233055.md` (not yet reviewed by the operator).

**Intent.** Produce the human-in-the-loop runbook for PR 1 cutover and PR 2 upgrade.

**Expected Outcomes.**
- `reports/migration-plan-<repo_slug>-<timestamp>.md` with target, variable sets, backup/cutover/verify phases, rollback, and teardown.
- The runbook follows `.bob/rules/03-cutover-verification.md` exactly: backup on the legacy backend, record SHA-256, `terraform init` (cloud block), `terraform plan -detailed-exitcode -no-color`.
- References `.bob/scripts/tf-cutover-verify.sh` phases `backup`, `migrate --confirm`, `verify` as operator helpers, with `--dry-run` previews.

**Todo List.**
1. Activate `tf-migration-plan`; map the single root module to the single workspace.
2. Write the Variable Set section listing variable names only.
3. Write Phases A to C and the rollback plan (restore S3 backend block, `terraform init -reconfigure`, `state push` of the backup if needed).
4. Add the PR 2 section: provider upgrade steps, expected plan review, and a decision point if the plan shows changes.
5. Add the teardown section.

**Relevant Context.** `.bob/skills/tf-migration-plan/SKILL.md`, `.bob/scripts/tf-cutover-verify.sh` (`--dir` must point at the folder containing the backend block).

---

### Sub-task 6: PR 1, backend swap only (`tf-code-migrate`)

**Status:** [x] done. PR 1 merged (`3083c86`) and the operator cutover passed the zero-diff gate.

**Results (operator ran Phases A to C; Bob verified from disk and the HCP Terraform API, read-only).**
- PR: https://github.com/ibmbcajshemi/demo-cloudblk-provupgrade-plan/pull/1. Code change: `infra/versions.tf` only (`backend "s3"` replaced by the `cloud` block). Provider constraint and lock file unchanged.
- Phase A backup (S3 backend still active): `.state-backups/state-backup-20261111001030.tfstate`, SHA-256 `47dce3e5fa05f6504b049cbee940f0d25d92f7ae4d1284c7fdf4ee327c79b18c`, which matches the baseline reference copy. Serial 1, lineage `f1668ffb-0149-65a3-c78e-beb311fdca08`, Terraform 1.14.3, 5 resources.
- Phase B: `init` copied the state to the workspace. New state version `sv-33pUgTs6zGyBMFZm`, serial 1, 5 resources.
- Phase C: remote plan `run-o1rVt559GkB9CCKg`, status `planned_and_finished`, `has-changes` false, all five resources `no-op`. `cutover-evidence.txt` records `plan_exit_code=0`. This also exercised the Variable Set key and the IAM policy: the refresh ran with no AccessDenied.
- Rollback was not needed. The S3 state object is untouched (8,482 bytes, last modified 2026-11-11T03:36:02Z).

**State measurements (before = Phase A backup, after = workspace current state).**
- `serial`: 1 and 1, unchanged.
- `lineage`: changed from `f1668ffb-0149-65a3-c78e-beb311fdca08` to `b4560103-7d79-ca38-7415-45dd1826eafd`. Resources and outputs are identical to the backup. The cause is not verified; the likely explanation is that the migrating `init` creates a new lineage in the new workspace.
- Drift lines in the plan log: the refresh reported `Drift detected (update)` on `aws_s3_bucket.demo` (`versioning` disabled to enabled, `tags` null to `{}`), `aws_sns_topic.demo` and `aws_ssm_parameter.demo` (`tags` null to `{}`). The plan result was still no-op. This is an observation of the plan JSON; the explanation (provider read filling in attributes) is unverified, and the stored state was not compared before and after.

**Not verified.** Why the lineage changed. Whether the stored state differs from the backup in attributes beyond resources and outputs identity (only resource instances and outputs were compared).


**Intent.** Convert the S3 backend to a `cloud` block pointing at the confirmed target, with no provider changes.

**Expected Outcomes.**
- Branch `migration/tfe-demo-cloudblk-provupgrade` with only the backend and `required_version` change.
- Backend block uses `app.terraform.io`, `tce-to-tfe-migration`, `demo-cloudblk-provupgrade`.
- `fmt` and `validate` pass; the PR description links the runbook and lists what the reviewer must check.
- PR is not merged until the operator has taken the legacy state backup.

**Todo List.**
1. Confirm the operator backup (SHA-256 recorded) exists before the cutover; the backup must come from the S3 backend, not from the new workspace.
2. Create the branch; replace the `backend "s3"` block with the `cloud` block; set `required_version` to satisfy `cloud` blocks.
3. `terraform fmt -recursive`; `terraform init -backend=false -input=false`; `terraform validate`.
4. Commit and prepare the PR description; wait for human review and merge.

**Operator cutover (after PR 1 is approved; not run by Bob).**
1. `tf-cutover-verify.sh --phase backup` on the legacy configuration.
2. Merge PR 1; `--phase migrate --confirm`.
3. `--phase verify`: exit 0 means zero-diff; exit 2 means drift, so roll back; exit 1 means diagnose.
4. Record whether the state serial or lineage changed, for the demo write-up.

**Relevant Context.** `.bob/skills/tf-code-migrate/SKILL.md` Steps 1, 2, 5 and 6; `.bob/rules/02-terraform-conventions.md` section 1.

---

### Sub-task 6b (optional): Negative test, resource rename without a `moved` block

**Status:** [x] done (plan-only; branch kept unmerged for the write-up)

**Result.** Branch `demo/negative-rename` (commit `f25cd76`, from tag `baseline-s3-aws4`) renames `aws_sns_topic.demo` to `aws_sns_topic.alerts` in `infra/main.tf` and `infra/outputs.tf`, with no `moved` block. `terraform plan -detailed-exitcode -no-color -lock=false` against the S3 backend exited **2**: `Plan: 1 to add, 0 to change, 1 to destroy.` Created: `aws_sns_topic.alerts`. Destroyed: `aws_sns_topic.demo` ("not in configuration"). The `demo_topic_arn` output changes to "known after apply". The plan log is `.state-backups/negative-rename-plan.log` (git-ignored). Afterwards the S3 state was re-pulled and its SHA-256 matched the baseline (`47dce3e5...79b18c`), serial 1, 5 resources, so nothing was written to state. Nothing was applied. The fix for the record is a `moved { from = aws_sns_topic.demo  to = aws_sns_topic.alerts }` block, not applied here. The branch is never merged; PR 1 is built from `main`.

**Intent.** Show the zero-diff gate and rollback working on a deliberately bad change. Run it after the baseline is applied and before the good PR 1 cutover. It is plan-only: it changes no AWS resources, and the branch is never merged.

**Expected Outcomes.**
- A throwaway branch (for example `demo/negative-rename`) that renames one resource, for example `aws_sns_topic.demo` to `aws_sns_topic.alerts`, with no `moved` block.
- The verification plan reports one destroy and one create (`1 to add, 0 to change, 1 to destroy`) and `terraform plan -detailed-exitcode` exits 2.
- The operator follows the rollback from `.bob/rules/03-cutover-verification.md` and records the anomaly in the audit evidence.
- The branch is discarded. The good PR 1 is built from the unmodified baseline.

**Todo List.**
1. Create the throwaway branch from the tagged baseline commit (S3 backend still active, sub-task 2); make only the rename.
2. Operator runs `terraform plan -detailed-exitcode -no-color` against the S3 backend (read-only, no state moves); expect exit code 2.
3. Present the plan output to the reviewer, listing the destroy and the create by address, as `terraform-devops` section 7 requires.
4. Explain the fix for the record: add a `moved` block mapping the old address to the new one. Do not apply it in this scenario.
5. Operator runs the rollback steps, then discards the branch. Bob applies nothing.

**Relevant Context.** `.bob/rules/03-cutover-verification.md` sections 1 and 3; `terraform-devops` sections 1 (destructive plan actions) and 4 (`moved` blocks).

**Caution.** Do not run `--phase migrate --confirm` with a destructive diff on the branch if state has already been moved to TFE. Run this scenario against a speculative plan or against the legacy S3 backend before the cutover, so no real state operation is needed.

---

### Sub-task 7: PR 2, AWS provider upgrade

**Status:** [ ] pending

**Intent.** Upgrade the AWS provider on the migrated workspace and show exactly what, if anything, changes in plan and state.

**Expected Outcomes.**
- Branch separate from PR 1 containing the provider constraint change and updated `.terraform.lock.hcl`.
- Upgrade guide for the target major version reviewed, with relevant breaking changes listed against this config.
- A remote speculative plan result attached to the PR; summary counts and any diffs explained.
- If the plan shows changes, the PR states them and waits for a human decision. Nothing is applied by Bob.

**Todo List.**
1. Look up the target provider version and upgrade guide via the Terraform MCP server or registry.
2. Update the `required_providers` constraint; run `terraform init -upgrade` (after the PR review/approval noted in sub-task 1); review the lock file diff.
3. Run `terraform plan` through the new backend (speculative); capture counts without any sensitive values.
4. Open the PR with the findings; operator applies from the runbook only after approval.
5. Operator compares state before and after (`state pull` backups) and records any schema-driven attribute changes.

**Relevant Context.** `terraform-devops` section 1 (new dependencies trigger) and section 7 (plan review lists every delete and replace); the provider upgrade section added in sub-task 1.

---

### Sub-task 8: Audit, write-up and teardown

**Status:** [ ] pending

**Intent.** Close the loop with evidence and leave no running cost.

**Expected Outcomes.**
- Audit manifest from `.bob/scripts/tf-audit-report.sh` using `<repo>/.state-backups/cutover-evidence.txt`.
- A short demo write-up: what moved, what changed in state, what each PR contained.
- Operator completes teardown: `terraform destroy` through the workspace, then removal of the legacy state bucket and the TFE workspace and Variable Set. Bob prepares the steps; it runs none of the deletions.
- IAM cleanup (operator): delete the demo user's access key (`aws iam delete-access-key`), its inline policy (`aws iam delete-user-policy --policy-name demo-cloudblk-provupgrade`), then the user (`aws iam delete-user --user-name demo-cloudblk-provupgrade-tfe`). Also delete the Variable Set `demo-cloudblk-provupgrade-aws` and the state reference copy in `~/demo-state-backups/`. The state bucket `statebucket-ajs11102026` is versioned, so emptying it means deleting all object versions and delete markers before the bucket itself can be removed.

**Todo List.**
1. Run the audit report script and attach the output to the PR record.
2. Write up findings, including whether state changed after PR 1 and after PR 2.
3. Provide the teardown checklist and confirm with the operator that no AWS resources remain.

**Relevant Context.** `.bob/scripts/tf-audit-report.sh`, `.bob/rules/03-cutover-verification.md` section 3.

---

## Open Questions

1. State bucket name (names must be globally unique). Region is confirmed as `us-east-1`. User will supply.
2. Git remote URL that will host the demo repo for PRs. User will supply.
