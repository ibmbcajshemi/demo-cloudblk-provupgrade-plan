# PR 2: Upgrade the AWS provider from 4.67.0 to 5.100.0 (provider only)

Branch: `migration/tfe-demo-cloudblk-provupgrade-aws-upgrade` -> `main`
Follows PR 1 (backend swap, merged and cut over; zero-diff verified).

## What changes

- `infra/versions.tf`: `hashicorp/aws` constraint `~> 4.67.0` becomes `~> 5.100.0`.
- `infra/.terraform.lock.hcl`: provider `4.67.0` becomes `5.100.0`. The file keeps two `h1` hashes (`darwin_arm64` for the operator, `linux_amd64` for the HCP Terraform runner) plus the `zh` archive hashes. It was refreshed with `terraform init -upgrade`, then `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`.

Nothing else changes: no resource, variable, output, backend or `required_version` edit.

## Why 5.100.0 and not 6.x

The AWS provider v6 upgrade guide says to upgrade to the latest 5.x first and confirm a clean plan. 5.100.0 is the last 5.x in the registry. 6.x is deliberately left for a separate step.

## Upgrade guide review (v5, read against this configuration)

Source: the provider's `version-5-upgrade` guide on GitHub `main`. Checked against the provider block (`region`, `default_tags`) and the five resources.

| Area | Guide says | Effect here |
| --- | --- | --- |
| Removed provider arguments (`s3_force_path_style`, `shared_credentials_file`, `skip_get_ec2_platforms`, `duration_seconds`) | Removed in 5.0.0 | None are set in `providers.tf` |
| `default_tags` | Duplicates and empty-string tags now allowed | Not breaking for this config |
| `aws_ssm_parameter` | `overwrite` attribute deprecated | Not set here |
| `aws_s3_bucket`, `aws_s3_bucket_versioning`, `aws_s3_bucket_public_access_block`, `aws_sns_topic` | No entry in the guide | No documented change |

The 5.x and 4.x release notes were not available in the upstream changelog file, so only the upgrade guide was reviewed. A guide lists what the authors documented; the plan below is the actual evidence.

## Checks run on this branch

- `terraform fmt -check`: pass.
- `terraform validate`: pass.
- `tflint`: not installed, so not run.
- Speculative remote plan through the `cloud` block (`run-HJ2hesx3MjCTZLah`, plan-only, Terraform 1.14.3): **exit 0, "No changes"**, all five resources `no-op`. `plan -detailed-exitcode` log kept in `.state-backups/` (git-ignored).
- No IAM `AccessDenied` on the refresh with the 5.100.0 provider.

## Refresh differences reported by the plan (state-only, no infrastructure change)

The plan reported `Drift detected (update)` during refresh and still produced no changes. From the plan JSON:

| Resource | Attributes that differ after refresh |
| --- | --- |
| `aws_s3_bucket.demo` | `bucket_regional_domain_name` (global to regional form), `versioning` (disabled to enabled), `tags` (null to `{}`) |
| `aws_sns_topic.demo` | `archive_policy`, `beginning_archive_time`, `fifo_throughput_scope` (null to empty string), `tags` (null to `{}`) |
| `aws_ssm_parameter.demo` | `tags` (null to `{}`) |

The S3 `versioning` and `tags` lines also appeared in the PR 1 plan under the 4.67 provider. The new ones with 5.100.0 are `bucket_regional_domain_name` and the three SNS attributes. These look like attributes that 5.x reads and 4.x did not. I did not confirm the cause. A speculative plan does not write state: the workspace is still on state version `sv-33pUgTs6zGyBMFZm`, serial 1, 5 resources.

## Reviewer checklist

- [ ] Only `infra/versions.tf` and `infra/.terraform.lock.hcl` changed (plus this description).
- [ ] Lock file records `5.100.0` with `h1` hashes for `darwin_arm64` and `linux_amd64`.
- [ ] You accept 5.100.0 as the target, with 6.x deferred.
- [ ] The plan summary above is zero-diff; no add, change or destroy.

## What merging does not do

Merging changes code only. No apply is run by Bob. The state is not rewritten until someone runs an apply or a state-writing operation in the workspace.

## Open decision after merge (operator)

A zero-diff plan does not prove the stored state stays identical. A later apply or refresh-only apply would write the refreshed attributes above, including a state `schema_version` change if the provider requires one. If the operator wants to test that, take a `state pull` backup immediately before and after and compare them. Nothing in this PR requires it.

## Not verified

- Provider behaviour beyond what the plan exercised: the plan only refreshes and compares; it creates, updates and destroys nothing.
- The cause of each refresh difference above.
- `tflint` results (not installed).
- 4.x to 5.x release notes (not available in the upstream changelog file).

## Rollback

Before merge: close the PR. After merge and before any apply: revert the merge commit, run `terraform -chdir=infra init -upgrade`, then plan; state has not been written by 5.100.0. After an apply: restore from the pre-apply `state pull` backup, because state written by 5.x may not be readable by 4.x.
