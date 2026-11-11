# Terraform CE to TFE Migration Bundle

This standalone package contains the IBM Bob skills, rules, custom mode, slash commands and helper scripts for migrating Terraform Community Edition (CE/OSS) estates to Terraform Enterprise (TFE).

Nothing in the bundle is tied to a particular repository. The TFE host, organization and workspace are never defaulted: they must come from you, the repository's own `cloud`/`remote` block, or your `tfctl` profile. Otherwise Bob reports the target as `NOT SPECIFIED` and asks.

## Package Contents

```
tf-migration-bundle/
└── .bob/
    ├── custom_modes.yaml               # Custom mode: 'tf-migrator' with restricted fileRegex write boundaries
    ├── rules/
    │   ├── 01-safety-guardrails.md     # No unattended apply/destroy, no plaintext secrets, PR workflow
    │   ├── 02-terraform-conventions.md # cloud/remote blocks, version pinning, formatting
    │   └── 03-cutover-verification.md  # Authoritative cutover sequence, zero-diff gate, rollback
    ├── skills/
    │   ├── tf-inventory/SKILL.md       # Estate discovery with tfctl / API / static fallback
    │   ├── cloud-deploy/SKILL.md       # TFE workspace / project / variable set provisioning (dry-run first)
    │   ├── tf-migration-plan/SKILL.md  # Workspace mapping and human-in-the-loop state runbooks
    │   ├── tf-code-migrate/SKILL.md    # Backend refactoring and Git PR workflow
    │   ├── tf-plan/SKILL.md            # Invocable /tf-plan entry point (activates tf-migration-plan)
    │   └── tf-migrate/SKILL.md         # Invocable /tf-migrate entry point (activates tf-code-migrate)
    ├── commands/
    │   ├── tf-inventory.md             # /tf-inventory
    │   ├── cloud-deploy.md             # /cloud-deploy
    │   ├── tf-plan.md                  # /tf-plan
    │   └── tf-migrate.md               # /tf-migrate
    └── scripts/
        ├── tf-cutover-verify.sh        # Operator helper: backup / migrate / verify phases
        ├── tf-migration-driver.sh      # Batch driver: runs Bob commands per repo on a migration branch
        └── tf-audit-report.sh          # Evidence-based audit manifest
```

## Install into Any Target Repository

Copy the `.bob` directory into the root of the repository:

```bash
TARGET_REPO="/path/to/your/terraform-repo"
cp -r tf-migration-bundle/.bob "${TARGET_REPO}/"
chmod +x "${TARGET_REPO}"/.bob/scripts/*.sh
```

## Use Inside a Repository

1. `/tf-inventory`: read-only scan of backends, version constraints, modules and variables.
2. `/cloud-deploy`: preview and provision the TFE workspace and variable sets (dry-run first).
3. `/tf-plan`: workspace mapping and the human-in-the-loop state runbook.
4. `/tf-migrate`: backend refactoring on a `migration/tfe-<workspace>` branch, ready for a pull request.
5. Cutover, run by a person (see below).

## Helper Scripts

All scripts take their inputs as flags, have no hardcoded targets or secrets, and print `--help`. They never run `apply`, `destroy`, `state rm` or `state push`.

### `tf-cutover-verify.sh`: state cutover, run by an operator

```bash
S=.bob/scripts/tf-cutover-verify.sh

# 1. On the LEGACY configuration (before the backend change is merged)
$S --phase backup --dir .

# 2. Merge the backend change, then copy state into TFE (interactive, mutates state)
$S --phase migrate --dir . --confirm

# 3. Zero-diff gate: exit 0 = ok, 2 = drift (roll back), 1 = error
$S --phase verify --dir .
```

Add `--dry-run` to any phase to preview. Backups and evidence are written to `<dir>/.state-backups/`; add that folder to `.gitignore`, because state files can contain secrets. Supply any required variables through `TF_VAR_*` or TFE workspace variables; the script injects none.

**Choosing `--dir`:** point it at the root module, the folder that contains the `terraform { ... }` block with the backend. The script reads only the `.tf` files directly in that folder, the same way Terraform does, and does not search subfolders.

- Single root module at the top of the repo: `--dir .`
- Root module in a subfolder (for example `infra/`): `--dir infra`
- Several environments (for example `envs/dev`, `envs/prod`): run the script once per folder, each with its own `--dir`.

If `--dir` points at the wrong folder, the script stops with an error ("No .tf files found" or "No cloud or backend \"remote\" block found") and changes nothing. To find every root module in a large repo, run `/tf-inventory` first.

### `tf-migration-driver.sh`: batch preparation

```bash
.bob/scripts/tf-migration-driver.sh --org <org> --host <tfe-hostname> \
  --dir /path/to/repo --workspace <workspace-name> --dry-run
```

For several repositories, pass `--repos-file <file>` with one `<path> <workspace>` per line. It creates one branch per repository and commits only Terraform code and the generated runbook. You push and open the pull request. Bob runs without auto-approval unless you pass `--bob-auto-approve`.

### `tf-audit-report.sh`: audit manifest

```bash
.bob/scripts/tf-audit-report.sh --repo /path/to/repo --output migration-audit-report.md
# or scan every subdirectory of a folder
.bob/scripts/tf-audit-report.sh --root /path/to/repos
```

A repository is reported as zero-diff verified only when a recorded plan exit code of 0 and a backup checksum exist; otherwise it is `PENDING`.
