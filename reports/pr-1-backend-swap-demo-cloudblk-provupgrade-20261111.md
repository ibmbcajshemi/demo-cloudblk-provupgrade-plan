# PR 1: Replace S3 backend with HCP Terraform `cloud` block (backend only)

Branch: `migration/tfe-demo-cloudblk-provupgrade` -> `main`
Commit: `d8ab838`

## What changes

One file, `infra/versions.tf`: the `backend "s3"` block is replaced by a `cloud` block.

```hcl
cloud {
  hostname     = "app.terraform.io"
  organization = "tce-to-tfe-migration"

  workspaces {
    name = "demo-cloudblk-provupgrade"
  }
}
```

## What does not change

- `required_version` (`>= 1.11.0, < 2.0.0`; the workspace runs Terraform 1.14.3).
- `required_providers`: `hashicorp/aws ~> 4.67.0`. No provider change in this PR (that is PR 2).
- `infra/.terraform.lock.hcl`, all resources, variables and outputs.

## Checks run on the branch

- `terraform fmt -check`: pass.
- `terraform init -backend=false` and `terraform validate` in a temporary copy: pass ("The configuration is valid").
- Not run: any plan or apply. A plan against the `cloud` block needs the state to be copied first (Phase B of the runbook).

## Reviewer checklist

- [ ] Host, organization and workspace match the intended target (workspace `ws-EBiJXXTP3UDJrDFG`, remote execution, auto-apply off).
- [ ] No provider, lock file or resource change is in the diff.
- [ ] No secrets in the diff. AWS credentials live in the Variable Set `demo-cloudblk-provupgrade-aws` (names only here).
- [ ] The operator has taken the Phase A backup from the S3 backend and recorded its SHA-256 **before** this PR is merged.

## Merging is the approval to move state

Merging does not move state by itself. After merge, the operator runs the cutover from
`reports/migration-plan-demo-cloudblk-provupgrade-20261110-233055.md`:

1. `--phase migrate --confirm` (interactive `terraform init`; answer `yes` to copy state).
2. `--phase verify` must exit 0 (`0 to add, 0 to change, 0 to destroy`). Exit 2 means drift: roll back (runbook section 4). Exit 1 means diagnose.

## Known unverified items

- The Variable Set AWS key has not been exercised; the first remote plan (Phase C) is the real test.
- Whether state `serial` or `lineage` change after the copy is not yet measured.

## Rollback

Restore the S3 backend block (`git checkout <pre-migration-commit> -- infra/versions.tf`), `terraform -chdir=infra init -reconfigure`, and `state push` the Phase A backup only if S3 state was modified or locked.
