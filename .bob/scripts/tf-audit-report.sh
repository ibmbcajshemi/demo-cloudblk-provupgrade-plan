#!/usr/bin/env bash
# ==============================================================================
# tf-audit-report.sh
#
# Generates a Migration Audit Trail for one or more Terraform repositories.
# Reports only what it can verify from evidence on disk; anything it cannot
# verify is shown as PENDING or UNKNOWN. It never claims a zero-diff result
# without a recorded plan exit code of 0.
#
# Evidence it reads (written by tf-cutover-verify.sh in <repo>/.state-backups/):
#   cutover-evidence.txt   backup_sha256=..., plan_exit_code=...
# ==============================================================================

set -euo pipefail

readonly EX_USAGE=64

usage() {
  cat <<'EOF'
Usage: tf-audit-report.sh [--root <dir>] [--repo <dir>]... [--output <file>] [--evidence-dir <name>]

  --root <dir>          Scan each immediate subdirectory of <dir> as a repository
  --repo <dir>          A repository to include (repeatable)
  --output <file>       Report path (default: migration-audit-report.md)
  --evidence-dir <name> Evidence folder inside each repo (default: .state-backups)
  -h, --help            Show this help

At least one of --root or --repo is required; nothing is scanned by default.
EOF
}

ROOT=""
REPOS=()
OUTPUT="migration-audit-report.md"
EVIDENCE_NAME=".state-backups"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)         ROOT="${2:-}"; shift 2 ;;
    --repo)         REPOS+=("${2:-}"); shift 2 ;;
    --output)       OUTPUT="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_NAME="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit "$EX_USAGE" ;;
  esac
done

if [ -n "$ROOT" ]; then
  [ -d "$ROOT" ] || { echo "Root not found: ${ROOT}" >&2; exit "$EX_USAGE"; }
  for d in "$ROOT"/*/; do
    [ -d "$d" ] && REPOS+=("${d%/}")
  done
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "No repositories given. Use --root or --repo." >&2
  usage >&2
  exit "$EX_USAGE"
fi

# Strip comment lines from every .tf file in a directory (top level).
tf_text() {
  local f
  for f in "$1"/*.tf; do
    [ -f "$f" ] && { grep -vE '^[[:space:]]*(#|//)' "$f" || true; }
  done
}

# Value of key=... from an evidence file (last occurrence wins).
evidence_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true
}

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROWS=""
ALL_EVIDENCED=true

for repo in "${REPOS[@]}"; do
  [ -d "$repo" ] || { echo "Skipping missing directory: ${repo}" >&2; continue; }

  name="$(basename "$(cd "$repo" && pwd)")"
  text="$(tf_text "$repo")"
  evidence="${repo}/${EVIDENCE_NAME}/cutover-evidence.txt"

  backend="none (local)"
  if printf '%s\n' "$text" | grep -Eq '^[[:space:]]*cloud[[:space:]]*\{'; then
    backend="cloud (TFE)"
  elif printf '%s\n' "$text" | grep -Eq 'backend[[:space:]]+"[a-z0-9_]+"'; then
    backend="$(printf '%s\n' "$text" | grep -Eo 'backend[[:space:]]+"[a-z0-9_]+"' | head -n1 | awk -F'"' '{print $2}')"
  fi

  core="$(printf '%s\n' "$text" | grep -E 'required_version' | head -n1 | awk -F'"' '{print $2}')"
  [ -n "$core" ] || core="unspecified"

  workspace="$(printf '%s\n' "$text" | awk '/workspaces[[:space:]]*\{/{f=1} f&&/name[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,""); print; exit}')"
  [ -n "$workspace" ] || workspace="NOT SPECIFIED"

  sha="$(evidence_value "$evidence" backup_sha256)"
  plan_exit="$(evidence_value "$evidence" plan_exit_code)"

  [ -n "$sha" ] && backup="${sha:0:12}..." || backup="NONE"
  case "$plan_exit" in
    0) zero_diff="YES (exit 0)" ;;
    2) zero_diff="NO - DRIFT (exit 2)" ;;
    "") zero_diff="PENDING" ;;
    *) zero_diff="ERROR (exit ${plan_exit})" ;;
  esac

  if [ "$backend" = "cloud (TFE)" ] && [ "$plan_exit" = "0" ] && [ -n "$sha" ]; then
    status="MIGRATED - VERIFIED"
  elif [ "$backend" = "cloud (TFE)" ]; then
    status="CODE CHANGED - NOT VERIFIED"
    ALL_EVIDENCED=false
  elif [ "$plan_exit" = "2" ]; then
    status="HALTED - ROLLBACK REQUIRED"
    ALL_EVIDENCED=false
  else
    status="NOT MIGRATED"
    ALL_EVIDENCED=false
  fi

  ROWS+="| \`${name}\` | \`${backend}\` | \`${core}\` | \`${workspace}\` | **${status}** | \`${backup}\` | ${zero_diff} |"$'\n'
done

{
  cat <<EOF
# Terraform Enterprise Migration - Audit Manifest

- **Generated**: \`${TIMESTAMP}\`
- **Repositories evaluated**: ${#REPOS[@]}
- **Evidence source**: \`<repo>/${EVIDENCE_NAME}/cutover-evidence.txt\`

---

## Repository Status

| Repository | Backend | Core Version | Target Workspace | Status | Backup Hash (SHA-256) | Zero-Diff |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
EOF
  printf '%s' "$ROWS"
  cat <<EOF

---

## Reading this report
- **Zero-Diff** is \`YES\` only when a recorded \`terraform plan -detailed-exitcode\` returned 0. No evidence means \`PENDING\`.
- **Backup Hash** is \`NONE\` until \`tf-cutover-verify.sh --phase backup\` has recorded one.
- This report does not assert that secrets were kept out of code; verify that separately (for example in the \`/tf-inventory\` report and in code review).
EOF
  if [ "$ALL_EVIDENCED" = "true" ]; then
    echo "- All listed repositories have a recorded backup and a zero-diff plan."
  else
    echo "- One or more repositories lack complete cutover evidence. Do not retire their legacy backends."
  fi
} > "$OUTPUT"

echo "Audit report written to ${OUTPUT}"
