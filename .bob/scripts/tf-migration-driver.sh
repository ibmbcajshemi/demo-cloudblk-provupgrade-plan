#!/usr/bin/env bash
# ==============================================================================
# tf-migration-driver.sh
#
# Batch driver for Terraform CE -> Terraform Enterprise (TFE) migrations.
# Orchestrates non-interactive Bob Shell (`bob -p`), `tfctl` and Git, one
# migration branch per repository. Works on any repository: nothing is
# hardcoded, and the target must be supplied explicitly.
#
# What it does NOT do: apply, destroy, state migration, push, or open PRs.
# State cutover stays a human step (see tf-cutover-verify.sh).
# ==============================================================================

set -euo pipefail

readonly EX_ERROR=1
readonly EX_USAGE=64

log_info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()    { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_success() { printf '\033[0;32m[SUCCESS]\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage:
  tf-migration-driver.sh --org <org> --host <tfe-hostname> --dir <repo> --workspace <name> [options]
  tf-migration-driver.sh --org <org> --host <tfe-hostname> --repos-file <file> [options]

Target (all required; there are no defaults and none are guessed):
  --org <name>          TFE organization (or env TARGET_ORG)
  --host <hostname>     TFE hostname     (or env TFE_HOSTNAME)

Single repository:
  --dir <path>          Repository to migrate
  --workspace <name>    Target TFE workspace for that repository

Batch:
  --repos-file <file>   One repository per line: "<path> <workspace>".
                        Blank lines and lines starting with # are ignored.

Options:
  --branch-prefix <p>   Migration branch prefix (default: migration/tfe)
  --bob-auto-approve    Pass --yolo to Bob so it can edit without prompting.
                        Off by default; review the resulting branch diff before merging.
  --dry-run             Print what would run; change nothing
  -h, --help            Show this help

Each repository gets its own branch "<prefix>-<workspace>" and a commit that
contains only Terraform code and the generated runbook. You push and open the
pull request yourself.
EOF
}

TARGET_ORG="${TARGET_ORG:-}"
TFE_HOSTNAME="${TFE_HOSTNAME:-}"
REPO_DIR=""
WORKSPACE=""
REPOS_FILE=""
BRANCH_PREFIX="migration/tfe"
BOB_AUTO_APPROVE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --org)              TARGET_ORG="${2:-}"; shift 2 ;;
    --host)             TFE_HOSTNAME="${2:-}"; shift 2 ;;
    --dir)              REPO_DIR="${2:-}"; shift 2 ;;
    --workspace)        WORKSPACE="${2:-}"; shift 2 ;;
    --repos-file)       REPOS_FILE="${2:-}"; shift 2 ;;
    --branch-prefix)    BRANCH_PREFIX="${2:-}"; shift 2 ;;
    --bob-auto-approve) BOB_AUTO_APPROVE=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit "$EX_USAGE" ;;
  esac
done

# --- Validate inputs ----------------------------------------------------------
check_inputs() {
  if [ -z "$TARGET_ORG" ] || [ -z "$TFE_HOSTNAME" ]; then
    log_error "Target NOT SPECIFIED. Provide --org and --host (confirmed with the TFE owner). No changes made."
    exit "$EX_USAGE"
  fi
  if [ -n "$REPOS_FILE" ] && [ -n "$REPO_DIR" ]; then
    log_error "Use either --repos-file or --dir/--workspace, not both."
    exit "$EX_USAGE"
  fi
  if [ -z "$REPOS_FILE" ]; then
    if [ -z "$REPO_DIR" ] || [ -z "$WORKSPACE" ]; then
      log_error "Single-repository mode needs both --dir and --workspace."
      exit "$EX_USAGE"
    fi
  elif [ ! -f "$REPOS_FILE" ]; then
    log_error "Repos file not found: ${REPOS_FILE}"
    exit "$EX_USAGE"
  fi

  command -v git >/dev/null 2>&1 || { log_error "git is required."; exit "$EX_ERROR"; }
  if ! command -v bob >/dev/null 2>&1 && [ "$DRY_RUN" != "true" ]; then
    log_error "bob CLI not found in PATH; the Bob steps cannot run."
    exit "$EX_ERROR"
  fi

  if command -v tfctl >/dev/null 2>&1; then
    TFCTL_AVAILABLE=true
  else
    TFCTL_AVAILABLE=false
    log_warn "tfctl not found; skipping live platform dry-run checks."
  fi
  if [ "$BOB_AUTO_APPROVE" = "true" ]; then
    log_warn "--bob-auto-approve set: Bob will edit without per-action prompts. Review every diff."
  fi
}

# Run a command, or just print it in dry-run mode.
run() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

# Run a Bob prompt in tf-migrator mode. Optional output file captures stdout.
bob_run() {
  local prompt="$1" out="${2:-}"
  local args=(-p "$prompt" --chat-mode=tf-migrator)
  [ -n "$out" ] && args+=(--hide-intermediary-output)
  [ "$BOB_AUTO_APPROVE" = "true" ] && args+=(--yolo)
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] bob ${args[*]}${out:+ > ${out}}"
    return 0
  fi
  if [ -n "$out" ]; then
    bob "${args[@]}" > "$out"
  else
    bob "${args[@]}"
  fi
}

# --- Process one repository ---------------------------------------------------
process_repo() {
  local repo_dir="$1" workspace="$2"
  local branch="${BRANCH_PREFIX}-${workspace}"

  log_info "------------------------------------------------------------"
  log_info "Repository: ${repo_dir}  Workspace: ${workspace}  Branch: ${branch}"
  log_info "------------------------------------------------------------"

  [ -d "$repo_dir" ] || { log_error "Directory not found: ${repo_dir}"; return 1; }

  # NOTE: this function is called from an `||` list, which disables `set -e`
  # inside it, so every critical step below carries an explicit `|| exit 1`.
  (
    cd "$repo_dir" || exit 1

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { log_error "${repo_dir} is not a git repository."; exit 1; }

    if [ -n "$(git status --porcelain)" ]; then
      log_error "Working tree is not clean in ${repo_dir}. Commit or stash first."
      exit 1
    fi
    if git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null; then
      log_error "Branch ${branch} already exists. Delete or rename it before re-running."
      exit 1
    fi

    # Phase 1: read-only inventory
    log_info "[Phase 1] Estate inventory"
    bob_run "Run /tf-inventory for this repository. Target organization '${TARGET_ORG}', host '${TFE_HOSTNAME}', workspace '${workspace}'." "migration-inventory.md" || exit 1

    # Phase 2: platform dry-run only
    if [ "$TFCTL_AVAILABLE" = "true" ]; then
      log_info "[Phase 2] tfctl workspace dry-run"
      run tfctl create workspace -a "name=${workspace}" -o "${TARGET_ORG}" --dry-run || exit 1
    fi

    # Phase 3: branch + code transformation
    log_info "[Phase 3] Branch and code transformation"
    run git checkout -b "$branch" || exit 1
    bob_run "Execute /tf-migrate for workspace '${workspace}' under organization '${TARGET_ORG}' on hostname '${TFE_HOSTNAME}'." || exit 1

    # Phase 4: migration plan and runbook
    log_info "[Phase 4] Migration plan and runbook"
    bob_run "Generate /tf-plan for workspace '${workspace}' under organization '${TARGET_ORG}' on hostname '${TFE_HOSTNAME}'." "MIGRATION_RUNBOOK.md" || exit 1

    # Phase 5: local validation (no backend, no state)
    if command -v terraform >/dev/null 2>&1; then
      log_info "[Phase 5] Local validation"
      run terraform fmt -recursive || exit 1
      run terraform init -backend=false -input=false || exit 1
      run terraform validate || exit 1
    else
      log_warn "terraform not found; skipping fmt/validate."
    fi

    # Phase 6: commit only code and generated docs
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[DRY-RUN] git add <changed .tf files, .terraform.lock.hcl, MIGRATION_RUNBOOK.md, migration-inventory.md>"
      log_info "[DRY-RUN] git commit"
      exit 0
    fi

    git add -- ':(glob)**/*.tf' ':(glob)**/*.tf.json' '.terraform.lock.hcl' 2>/dev/null || true
    [ -f MIGRATION_RUNBOOK.md ] && git add -- MIGRATION_RUNBOOK.md
    [ -f migration-inventory.md ] && git add -- migration-inventory.md

    if git diff --cached --quiet; then
      log_warn "No migration changes were produced for ${repo_dir}."
      exit 0
    fi

    git commit -m "refactor(terraform): migrate backend configuration to Terraform Enterprise (${workspace})" || exit 1

    cat > MIGRATION_PR_DESCRIPTION.md <<EOF
## Terraform Enterprise migration: ${workspace}

### Summary of changes
- Target organization: \`${TARGET_ORG}\`
- Target workspace: \`${workspace}\`
- Target host: \`${TFE_HOSTNAME}\`
- Backend converted to TFE; \`required_version\` and provider pins updated.

### Human-in-the-loop state cutover required
Review [MIGRATION_RUNBOOK.md](./MIGRATION_RUNBOOK.md) before merging.
Run the cutover yourself: backup, migrate (\`--confirm\`), then verify (zero-diff).
See \`.bob/scripts/tf-cutover-verify.sh --help\`.
EOF
    log_success "Branch '${branch}' is ready for review. Push it and open the pull request yourself."
    log_info "PR description draft: ${repo_dir}/MIGRATION_PR_DESCRIPTION.md (not committed)"
  )
}

# --- Main ---------------------------------------------------------------------
main() {
  check_inputs

  if [ -n "$REPOS_FILE" ]; then
    local failures=0 line path ws
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
      read -r path ws <<< "$line"
      if [ -z "${ws:-}" ]; then
        log_error "Line missing workspace (expected '<path> <workspace>'): ${line}"
        failures=$((failures + 1))
        continue
      fi
      process_repo "$path" "$ws" || failures=$((failures + 1))
    done < "$REPOS_FILE"
    if [ "$failures" -gt 0 ]; then
      log_error "${failures} repository(ies) failed."
      exit "$EX_ERROR"
    fi
  else
    process_repo "$REPO_DIR" "$WORKSPACE"
  fi

  log_success "Driver completed."
}

main
