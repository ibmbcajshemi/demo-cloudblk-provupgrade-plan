# Cutover Verification & Zero-Diff Safety Guardrails

## 1. Zero-Diff Invariant
- **Strict Verification Gate**: No Terraform CE to TFE migration is deemed complete until a speculative or live `terraform plan` produces exactly `0 to add, 0 to change, 0 to destroy`.
- **Any Plan Drift Requires Rollback**: If `terraform plan` detects additions, modifications, or destructions, cutover must immediately halt and rollback procedures must execute using the pre-migration state backup.

## 2. Deterministic Cutover Sequence
Every automated or manual state cutover runner must strictly follow this atomic sequence. The bundled helper `.bob/scripts/tf-cutover-verify.sh` implements it as three phases (`--phase backup`, `--phase migrate --confirm`, `--phase verify`); run it with `--help` for options. It is a helper for the human operator, never something to run unattended.

The backup must be taken while the **legacy** backend is still configured. A state pulled after the `cloud` block is in place comes from the new, empty workspace and is not a valid backup.

1. **Pre-Cutover Backup**: Extract and checksum the legacy remote or local state:
   ```bash
   terraform state pull > state-backup-$(date +%Y%m%d%H%M%S).tfstate
   ```
2. **State Hash Recording**: Record SHA-256 checksum of the exported state file in the migration log / audit trail.
3. **State Migration**: Re-initialize backend. When using a `cloud` block, standard `terraform init` detects existing state and prompts for migration:
   ```bash
   terraform init
   ```
   *(For legacy remote backends, use `terraform init -migrate-state`)*
4. **Verification Plan Execution**:
   ```bash
   terraform plan -detailed-exitcode -no-color
   ```
   - Exit code `0`: Succeeded (Zero diff, no changes).
   - Exit code `2`: Drift detected (Changes present) &rarr; Immediate halt and rollback.
   - Exit code `1`: Execution error &rarr; Immediate halt and diagnose.

## 3. Automated Rollback Protocol
If state migration fails or drift is detected:
1. Restore original backend configuration block (`backend "<type>"`).
2. Re-initialize legacy backend:
   ```bash
   terraform init -reconfigure
   ```
3. Push restored state backup if legacy state was modified or locked:
   ```bash
   terraform state push <backup-file>.tfstate
   ```
4. Document the anomaly in the migration audit manifest. The manifest is the report produced by `.bob/scripts/tf-audit-report.sh` from the evidence file `<repo>/.state-backups/cutover-evidence.txt`; record any anomaly alongside it in your change ticket or PR.
