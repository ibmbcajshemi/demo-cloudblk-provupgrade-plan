#!/usr/bin/env bash
# ==============================================================================
# tf-cutover-verify.sh
#
# Human-in-the-loop state cutover helper for Terraform CE -> Terraform Enterprise.
# Implements the sequence in .bob/rules/03-cutover-verification.md as three
# explicit phases. Works on any Terraform root module (pass --dir).
#
#   backup   Pull legacy state, record SHA-256.           (read-only)
#   migrate  Re-initialise onto the TFE backend.          (MUTATES STATE, needs --confirm)
#   verify   Zero-diff plan gate (plan -detailed-exitcode). (read-only)
#
# Safety properties:
#   * No secrets are embedded or injected. Provide TF_VAR_* in your environment.
#   * Fails closed: any unexpected condition stops the run with a non-zero code.
#   * Never runs apply, destroy, or state push/rm. Rollback is printed, not run.
# ==============================================================================

set -euo pipefail

# Exit codes
readonly EX_OK=0
readonly EX_ERROR=1
readonly EX_DRIFT=2
readonly EX_CONFIRM=4
readonly EX_USAGE=64

log_info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()    { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_success() { printf '\033[0;32m[SUCCESS]\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: tf-cutover-verify.sh --phase <backup|migrate|verify> [options]

Required:
  --phase <name>        backup | migrate | verify

Options:
  --dir <path>          Terraform root module directory (default: .)
  --backup-dir <path>   Where state backups and evidence are stored
                        (default: <dir>/.state-backups)
  --backup-file <path>  Backup to use for the migrate phase (default: newest
                        state-backup-*.tfstate in --backup-dir)
  --allow-empty-state   Permit an empty state in the backup phase
                        (only for workspaces that have never been applied)
  --confirm             Required for the migrate phase, which mutates state
  --dry-run             Print the commands that would run; change nothing
  -h, --help            Show this help

Typical flow (run each phase yourself, in order):
  1. On the LEGACY configuration:  --phase backup
  2. Apply the cloud/remote block change (e.g. via /tf-migrate), review, merge
  3. --phase migrate --confirm     (interactive: answer 'yes' to copy state)
  4. --phase verify                (must exit 0; exit 2 = drift -> roll back)

Exit codes: 0 ok, 1 error, 2 drift detected, 4 confirmation required, 64 usage.
EOF
}

# --- Defaults -----------------------------------------------------------------
PHASE=""
TF_DIR="."
BACKUP_DIR=""
BACKUP_FILE=""
ALLOW_EMPTY_STATE=false
CONFIRM=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)             PHASE="${2:-}"; shift 2 ;;
    --dir)               TF_DIR="${2:-}"; shift 2 ;;
    --backup-dir)        BACKUP_DIR="${2:-}"; shift 2 ;;
    --backup-file)       BACKUP_FILE="${2:-}"; shift 2 ;;
    --allow-empty-state) ALLOW_EMPTY_STATE=true; shift ;;
    --confirm)           CONFIRM=true; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -h|--help)           usage; exit "$EX_OK" ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit "$EX_USAGE" ;;
  esac
done

case "$PHASE" in
  backup|migrate|verify) ;;
  "") log_error "--phase is required."; usage >&2; exit "$EX_USAGE" ;;
  *)  log_error "Invalid --phase '${PHASE}'."; usage >&2; exit "$EX_USAGE" ;;
esac

[ -n "$BACKUP_DIR" ] || BACKUP_DIR="${TF_DIR}/.state-backups"
EVIDENCE_FILE="${BACKUP_DIR}/cutover-evidence.txt"

# --- Helpers ------------------------------------------------------------------
tf() { terraform -chdir="$TF_DIR" "$@"; }

# Print the command (dry-run) or run it.
run() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    log_error "Neither shasum nor sha256sum is available; cannot record a checksum."
    exit "$EX_ERROR"
  fi
}

# Concatenate non-comment lines of every .tf file in the module directory.
tf_config_text() {
  local f found=false
  for f in "$TF_DIR"/*.tf; do
    [ -f "$f" ] || continue
    found=true
    grep -vE '^[[:space:]]*(#|//)' "$f" || true
  done
  [ "$found" = "true" ]
}

has_cloud_block()   { tf_config_text | grep -Eq '^[[:space:]]*cloud[[:space:]]*\{'; }
has_remote_block()  { tf_config_text | grep -Eq 'backend[[:space:]]+"remote"'; }
has_legacy_block()  { tf_config_text | grep -Eq 'backend[[:space:]]+"(local|s3|azurerm|gcs|consul|http|pg|kubernetes|oss|cos)"'; }

warn_if_not_ignored() {
  # State backups contain secrets. Warn if they could be committed.
  if command -v git >/dev/null 2>&1 && git -C "$TF_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # git -C changes directory, so a relative BACKUP_DIR must be made absolute first.
    local backup_abs
    backup_abs="$(cd "$BACKUP_DIR" 2>/dev/null && pwd -P || printf '%s' "$BACKUP_DIR")"
    if ! git -C "$TF_DIR" check-ignore -q "$backup_abs/" 2>/dev/null; then
      log_warn "Backup directory '${BACKUP_DIR}' is not git-ignored. State files can contain secrets: add it to .gitignore and never commit it."
    fi
  fi
}

print_rollback() {
  cat >&2 <<EOF

Rollback (run these yourself, in order):
  1. Restore the original backend block:   git checkout <pre-migration-commit> -- <backend .tf file>
  2. Re-initialise the legacy backend:     terraform -chdir=${TF_DIR} init -reconfigure
  3. Only if legacy state was modified or locked, restore the backup:
       terraform -chdir=${TF_DIR} state push <backup-file>.tfstate
  4. Record the anomaly in your migration audit log.
EOF
}

# --- Prerequisites ------------------------------------------------------------
check_prerequisites() {
  command -v terraform >/dev/null 2>&1 || { log_error "terraform CLI is required but not installed."; exit "$EX_ERROR"; }
  [ -d "$TF_DIR" ] || { log_error "Directory not found: ${TF_DIR}"; exit "$EX_ERROR"; }
  tf_config_text >/dev/null || { log_error "No .tf files found in ${TF_DIR}."; exit "$EX_ERROR"; }
}

# --- Phase: backup ------------------------------------------------------------
phase_backup() {
  if has_cloud_block || has_remote_block; then
    log_error "${TF_DIR} already contains a cloud/remote backend block."
    log_error "The backup must come from the LEGACY backend. Run this phase on the pre-migration"
    log_error "commit (before the backend change), or pass an existing backup to the migrate phase."
    exit "$EX_ERROR"
  fi

  local timestamp backup_file checksum
  timestamp="$(date +%Y%m%d%H%M%S)"
  backup_file="${BACKUP_DIR}/state-backup-${timestamp}.tfstate"

  log_info "Phase backup: pulling legacy state to ${backup_file}"
  run mkdir -p "$BACKUP_DIR"
  warn_if_not_ignored

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] terraform -chdir=${TF_DIR} init -input=false   (only if not initialised)"
    log_info "[DRY-RUN] terraform -chdir=${TF_DIR} state pull > ${backup_file}"
    log_info "[DRY-RUN] record SHA-256 in ${backup_file}.sha256 and ${EVIDENCE_FILE}"
    return 0
  fi

  if [ ! -d "${TF_DIR}/.terraform" ]; then
    log_info "Module not initialised; running terraform init (legacy backend, no state change)."
    tf init -input=false >/dev/null
  fi

  if ! tf state pull > "$backup_file"; then
    rm -f "$backup_file"
    log_error "terraform state pull failed. No backup was captured."
    exit "$EX_ERROR"
  fi

  if [ ! -s "$backup_file" ]; then
    rm -f "$backup_file"
    if [ "$ALLOW_EMPTY_STATE" != "true" ]; then
      log_error "State pull returned nothing. If this workspace has never been applied, re-run with --allow-empty-state."
      exit "$EX_ERROR"
    fi
    log_warn "State is empty and --allow-empty-state was given; nothing to back up."
    return 0
  fi

  if grep -Eq '"resources":[[:space:]]*\[\]' "$backup_file" && [ "$ALLOW_EMPTY_STATE" != "true" ]; then
    log_error "Pulled state contains no resources. Refusing to proceed (use --allow-empty-state if intended)."
    exit "$EX_ERROR"
  fi

  chmod 600 "$backup_file"
  checksum="$(sha256_of "$backup_file")"
  printf '%s\n' "$checksum" > "${backup_file}.sha256"
  {
    printf 'backup_file=%s\n' "$backup_file"
    printf 'backup_sha256=%s\n' "$checksum"
    printf 'backup_recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$EVIDENCE_FILE"

  log_success "State backup captured. SHA-256: ${checksum}"
}

# --- Phase: migrate -----------------------------------------------------------
phase_migrate() {
  local backup expected actual
  backup="$BACKUP_FILE"
  if [ -z "$backup" ]; then
    # shellcheck disable=SC2012
    backup="$(ls -1t "${BACKUP_DIR}"/state-backup-*.tfstate 2>/dev/null | head -n1 || true)"
  fi

  if [ -z "$backup" ] || [ ! -s "$backup" ]; then
    log_error "No usable state backup found. Run --phase backup on the legacy configuration first."
    exit "$EX_ERROR"
  fi
  [ -f "${backup}.sha256" ] || { log_error "Missing checksum file ${backup}.sha256."; exit "$EX_ERROR"; }
  expected="$(tr -d '[:space:]' < "${backup}.sha256")"
  actual="$(sha256_of "$backup")"
  if [ "$expected" != "$actual" ]; then
    log_error "Backup checksum mismatch for ${backup}. Refusing to continue."
    exit "$EX_ERROR"
  fi
  log_info "Verified backup ${backup} (SHA-256 ${actual})."

  local init_cmd
  if has_cloud_block; then
    init_cmd="terraform -chdir=${TF_DIR} init"
  elif has_remote_block; then
    init_cmd="terraform -chdir=${TF_DIR} init -migrate-state"
  else
    log_error "No cloud or backend \"remote\" block found in ${TF_DIR}. Apply the backend change first."
    exit "$EX_ERROR"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] ${init_cmd}   (interactive; answer 'yes' to copy state)"
    return 0
  fi

  if [ "$CONFIRM" != "true" ]; then
    log_warn "The migrate phase copies state into TFE. Re-run with --confirm to proceed."
    log_warn "It will run: ${init_cmd}"
    exit "$EX_CONFIRM"
  fi

  log_info "Phase migrate: ${init_cmd} (interactive)"
  if ! ${init_cmd}; then
    log_error "Backend initialisation failed. Halt and diagnose."
    print_rollback
    exit "$EX_ERROR"
  fi
  log_success "Backend initialised against TFE. Now run --phase verify."
}

# --- Phase: verify ------------------------------------------------------------
phase_verify() {
  local log_file plan_exit=0
  log_file="${BACKUP_DIR}/plan-verification-$(date +%Y%m%d%H%M%S)-$$.log"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] terraform -chdir=${TF_DIR} plan -detailed-exitcode -no-color -input=false > ${log_file}"
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  log_info "Phase verify: running zero-diff plan (log: ${log_file})"
  log_info "Provide variables via TF_VAR_* or TFE workspace variables; none are injected by this script."

  set +e
  tf plan -detailed-exitcode -no-color -input=false > "$log_file" 2>&1
  plan_exit=$?
  set -e

  {
    printf 'plan_exit_code=%s\n' "$plan_exit"
    printf 'plan_log=%s\n' "$log_file"
    printf 'plan_recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$EVIDENCE_FILE"

  case "$plan_exit" in
    0)
      log_success "Zero-diff verified: 0 to add, 0 to change, 0 to destroy."
      ;;
    2)
      log_error "DRIFT DETECTED: the plan has pending changes. Halt and roll back."
      log_error "Review ${log_file}"
      print_rollback
      exit "$EX_DRIFT"
      ;;
    *)
      log_error "terraform plan failed (exit ${plan_exit}). Halt and diagnose."
      log_error "Review ${log_file}"
      exit "$EX_ERROR"
      ;;
  esac
}

main() {
  check_prerequisites
  case "$PHASE" in
    backup)  phase_backup ;;
    migrate) phase_migrate ;;
    verify)  phase_verify ;;
  esac
}

main
