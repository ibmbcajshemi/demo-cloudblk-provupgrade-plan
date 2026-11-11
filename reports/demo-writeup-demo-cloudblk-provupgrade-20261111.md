# Demo write-up: Terraform CE to HCP Terraform, with a backend swap and an AWS provider upgrade

Project: `demo-cloudblk-provupgrade`. Date of the run: 10 to 11 November 2026.
The results below come from real runs on real infrastructure, checked against local files and the HCP Terraform API. Where something is my reading rather than a test, or was not verified, it says so.

## 1. What the demo did

A small Terraform CE configuration on an S3 backend was moved to HCP Terraform (`app.terraform.io`, org `tce-to-tfe-migration`, workspace `demo-cloudblk-provupgrade`, remote execution). Then the AWS provider was upgraded from 4.67.0 to 5.100.0. Each code change went through its own GitHub pull request and a human merged it. Bob in `tf-migrator` mode prepared the changes; the operator ran every command that writes state, AWS or HCP Terraform.

Resources (all in `us-east-1`, none with compute): an S3 bucket with versioning and a public access block, an SSM Standard parameter, and an SNS topic. Five resources in state.

## 2. Timeline

| Step | What happened | Result |
| --- | --- | --- |
| Baseline | CE config on S3 backend (`use_lockfile`), `hashicorp/aws ~> 4.67.0`. Operator applied it. | 5 resources, serial 1, plan exit 0 |
| Inventory | `tf-inventory` report | Readiness `ACTION_REQUIRED`, no code blocker, no secrets in code, no modules |
| Provisioning | Workspace and Variable Set created through `tfctl` after approval; the operator created a dedicated IAM user and entered the key in the UI | AWS keys never seen by Bob |
| Runbook | `tf-migration-plan` runbook with backup, cutover, verify, rollback and teardown | Followed for Phases A to C. Rollback was never needed, so it was not exercised. |
| Negative test | Renamed `aws_sns_topic.demo` with no `moved` block; Bob ran a read-only plan against S3 with `-lock=false` | Exit 2, `1 to add, 0 to change, 1 to destroy`; S3 state hash unchanged afterwards |
| PR 1 (#1) | Replaced `backend "s3"` with a `cloud` block. One code file changed. | Merged |
| Cutover | Operator ran backup (S3), `init` (copy state), verify | Zero-diff, exit 0 |
| PR 2 (#2) | `~> 4.67.0` to `~> 5.100.0` and a refreshed lock file | Merged |
| State measurement | Operator ran a refresh-only apply with `state pull` backups before and after | 0 added, 0 changed, 0 destroyed |
| Final check | Plan after the refresh | Exit 0, no drift lines |

## 3. Did state change?

This was the open question at the start.

**Backend swap (S3 to HCP Terraform).**

| Field | Before (S3 backup) | After (workspace) |
| --- | --- | --- |
| `serial` | 1 | 1 |
| `lineage` | `f1668ffb-0149-65a3-c78e-beb311fdca08` | `b4560103-7d79-ca38-7415-45dd1826eafd` |
| Resources and outputs | 5 resources | identical |

The lineage changed and the serial did not. I did not test why. My reading is that the migrating `init` creates a new lineage in the new workspace. The plan was still zero-diff.

**Provider upgrade (4.67.0 to 5.100.0).**

The two plans after PR 2 (branch and merged `main`) were both zero-diff and wrote nothing to state. The state was only rewritten when the operator ran a refresh-only apply:

| Field | Before | After |
| --- | --- | --- |
| `serial` | 1 | 2 |
| `lineage` | `b4560103-…` | unchanged |
| `schema_version` on all five resources | 0 | 0 |
| Resource set, providers, outputs | | identical |

Attribute changes, all state-only (nothing in AWS changed):
- `aws_s3_bucket.demo`: `bucket_regional_domain_name` changed from the global to the regional form; `versioning.enabled` false to true; `tags` null to `{}`.
- `aws_sns_topic.demo`: `archive_policy`, `beginning_archive_time` and `fifo_throughput_scope` added as empty strings; `tags` null to `{}`.
- `aws_ssm_parameter.demo`: `tags` null to `{}`; three new null attributes (`has_value_wo`, `value_wo`, `value_wo_version`); `value_wo` added to `sensitive_attributes`.
- `aws_s3_bucket_public_access_block.demo` and `aws_s3_bucket_versioning.demo`: unchanged.

**Answer for this configuration:** the backend swap changed the state's lineage only. The provider upgrade did not change state until an apply, and then it added attributes and normalized values, with no `schema_version` bump and no resource change. This is a measurement of five simple resources, not a general rule.

## 4. The human-in-the-loop controls that held

- Two separate PRs, one per change, each reviewed and merged by a person.
- Bob ran no `apply`, `destroy` or `state` write. Bob ran read-only plans (the negative test and the checks against the HCP Terraform API). The operator ran the backup, the `init` migration and the refresh-only apply.
- Backup taken on the S3 backend before the cutover, SHA-256 recorded and matched against an independent reference copy.
- The zero-diff gate ran after the cutover (`plan_exit_code=0` recorded) and again after the upgrade and the refresh.
- The negative test showed the gate catching a destructive rename (exit 2) without touching state.
- No secret entered the repository. The AWS key lives only in the Variable Set. Push scans reported none.

## 5. What had to be fixed in the skills and tooling

These came up during the run and are worth keeping:
- `tf-code-migrate` had no provider-upgrade procedure or S3-to-`cloud` notes; both were added.
- `tf-migration-plan` was vague on ordering; it now says to back up on the legacy backend before `init`, ties remote execution to the Variable Set, and includes a teardown runbook.
- `cloud-deploy` told readers to use `tfctl attach varset`, which does not exist in `tfctl` v0.4.0. Varsets are attached with an API call.
- The audit script reads only the top level of the folder it is given. Run with `--repo .` it exits 1 with no message; it worked with `--repo infra --evidence-dir ../.state-backups`. I did not diagnose the exact cause.
- The cutover script writes evidence under `--dir` unless `--backup-dir` is given. The runbook passes `--backup-dir ./.state-backups` so the audit script can find it.
- Sessions from `aws login` last about 15 minutes, and Terraform cannot read them directly. The operator must export credentials (`aws configure export-credentials`) before the backup and migrate phases.
- The workspace is CLI-driven with no VCS connection. A UI run has no code to run from, so the refresh-only apply had to come from the CLI.

## 6. What this demo does not prove

- It does not show the upgrade is safe in general. The upgrade guides for v5 listed no change affecting these resources, but release notes for 4.x and 5.x were not available in the upstream changelog file, so only the guides were reviewed.
- It does not cover provider 6.x. That is deliberately deferred; the v6 guide requires a clean plan on the latest 5.x first (done here).
- Five simple resources with no modules, no sensitive Terraform variables, one workspace and one region. Larger estates may behave differently.
- `tflint` was not installed, so it was not run.
- The AWS cost check was never completed. The resources are expected to be inexpensive, but I did not verify a price for S3, SSM Parameter Store or SNS, so treat any cost figure as unverified.
- The Terraform MCP server was configured but never connected (the Docker daemon was not running). Provider versions came from the public registry API.
- The audit script's output only covers the PR 1 cutover. The PR 2 and refresh-only evidence is in a supplementary section I added by hand.
- The legacy S3 state object has not been retired. It is intentionally kept until teardown.

## 7. Evidence index

| Item | Where |
| --- | --- |
| Master plan and per-step results | `demo-cloudblk-provupgrade-plan.md` |
| Inventory report | `reports/inventory-demo-cloudblk-provupgrade-20261110-224722.md` |
| Migration plan and runbook | `reports/migration-plan-demo-cloudblk-provupgrade-20261110-233055.md` |
| PR 1 and PR 2 | https://github.com/ibmbcajshemi/demo-cloudblk-provupgrade-plan/pull/1 and `/pull/2` |
| Audit manifest | `reports/audit-demo-cloudblk-provupgrade-20261111.md` |
| State backups (local, git-ignored) | `.state-backups/` and `~/demo-state-backups/` |

Run IDs: cutover `run-o1rVt559GkB9CCKg`; PR 2 branch plan `run-HJ2hesx3MjCTZLah`; merged-code plan `run-jNzWHHaifKiAxnfE`; refresh-only apply `run-t5DLU63Qsy1gnavU`; post-refresh plan `run-gdm82Z6B5UJJrgq8`.
