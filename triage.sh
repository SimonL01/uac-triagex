#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
  RED="\e[31m"
  GREEN="\e[32m"
  YELLOW="\e[33m"
  BLUE="\e[34m"
  CYAN="\e[36m"
  RESET="\e[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  RESET=""
fi

ok()   { printf "%b[OK]%b    %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "%b[WARN]%b  %s\n" "$YELLOW" "$RESET" "$1"; }
info() { printf "%b[INFO]%b  %s\n" "$BLUE" "$RESET" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }

die() {
  err "$1"
  exit 1
}

on_error() {
  local exit_code=$?
  err "Execution failed at line ${BASH_LINENO[0]} with exit code ${exit_code}."
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'EOF'
Usage:
  ./triage.sh [options]

Required:
  --case-number VALUE        Case identifier, e.g. CASE-2026-001
  --evidence-number VALUE    Evidence identifier, e.g. EV-001
  --examiner VALUE           Examiner / operator name

Common options:
  --evidence-root PATH       Destination root for evidence output (default: /mnt/evidence)
  --mount-point PATH         Source mount point for UAC collection (default: /)
  --description VALUE        Collection description
  --notes VALUE              Operator notes for the acquisition log
  --format VALUE             Archive format: zip, tar, tar.gz (default: zip)
  --zip-password VALUE       Password for zip output only
  --profile VALUE            UAC profile name or profile path (default: ir_triage)
  --uac-dir PATH             Path to extracted UAC directory (default: ./uac next to script)
  --temp-dir PATH            Override temp directory (default: <evidence-root>/uac-temp)
  --output-dir PATH          Override final output directory (default: <evidence-root>/uac-output)
  --output-name VALUE        UAC output basename (default: uac-%hostname%-linux-live-triage-%timestamp%)
  --hash-all                 Hash all collected files with UAC (-H) (default)
  --no-hash-all              Disable UAC full collected-file hashing
  --yes                      Skip the interactive pre-run confirmation prompt
  --non-interactive          Fail instead of prompting for missing required values
  --help                     Show this help

Examples:
  ./triage.sh \
    --evidence-root /mnt/usb1 \
    --case-number CASE-2026-001 \
    --evidence-number EV-001 \
    --examiner "Firstname Lastname"

  ./triage.sh \
    --evidence-root /cases/host123 \
    --case-number CASE-2026-044 \
    --evidence-number EV-003 \
    --examiner "IR Team" \
    --format zip \
    --zip-password "ChangeMe123!"
EOF
}

EVIDENCE_ROOT="${EVIDENCE_ROOT:-/mnt/evidence}"
MOUNT_POINT="${MOUNT_POINT:-/}"
CASE_NUMBER="${CASE_NUMBER:-}"
EVIDENCE_NUMBER="${EVIDENCE_NUMBER:-}"
EXAMINER="${EXAMINER:-}"
DESCRIPTION="${DESCRIPTION:-Linux live forensic triage}"
NOTES="${NOTES:-Initial live triage before containment}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-zip}"
ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-}"
PROFILE="${PROFILE:-ir_triage}"
UAC_DIR="${UAC_DIR:-$SCRIPT_DIR/uac}"
TEMP_DIR="${TEMP_DIR:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
OUTPUT_NAME="${OUTPUT_NAME:-uac-%hostname%-linux-live-triage-%timestamp%}"
HASH_ALL=true
ASSUME_YES=false
NON_INTERACTIVE=false
ORIGINAL_ARGS=("$@")

require_value() {
  local option_name="$1"
  [[ $# -ge 2 ]] || die "Option ${option_name} requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence-root)
      require_value "$1" "$@"
      EVIDENCE_ROOT="$2"
      shift 2
      ;;
    --mount-point)
      require_value "$1" "$@"
      MOUNT_POINT="$2"
      shift 2
      ;;
    --case-number)
      require_value "$1" "$@"
      CASE_NUMBER="$2"
      shift 2
      ;;
    --evidence-number)
      require_value "$1" "$@"
      EVIDENCE_NUMBER="$2"
      shift 2
      ;;
    --examiner)
      require_value "$1" "$@"
      EXAMINER="$2"
      shift 2
      ;;
    --description)
      require_value "$1" "$@"
      DESCRIPTION="$2"
      shift 2
      ;;
    --notes)
      require_value "$1" "$@"
      NOTES="$2"
      shift 2
      ;;
    --format)
      require_value "$1" "$@"
      ARCHIVE_FORMAT="$2"
      shift 2
      ;;
    --zip-password)
      require_value "$1" "$@"
      ARCHIVE_PASSWORD="$2"
      shift 2
      ;;
    --profile)
      require_value "$1" "$@"
      PROFILE="$2"
      shift 2
      ;;
    --uac-dir)
      require_value "$1" "$@"
      UAC_DIR="$2"
      shift 2
      ;;
    --temp-dir)
      require_value "$1" "$@"
      TEMP_DIR="$2"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output-name)
      require_value "$1" "$@"
      OUTPUT_NAME="$2"
      shift 2
      ;;
    --hash-all)
      HASH_ALL=true
      shift
      ;;
    --no-hash-all)
      HASH_ALL=false
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
done

prompt_if_missing() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return
  fi

  if [[ "$NON_INTERACTIVE" == true || ! -t 0 ]]; then
    die "Missing required option: ${prompt_text}"
  fi

  read -r -p "${prompt_text}: " current_value
  [[ -n "$current_value" ]] || die "A value is required for ${prompt_text}."
  printf -v "$var_name" '%s' "$current_value"
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_uac() {
  (
    cd "$UAC_DIR"
    ./uac "$@"
  )
}

capture_command() {
  local output_file="$1"
  shift

  {
    printf "# Command:"
    printf " %q" "$@"
    printf "\n"
    "$@"
  } >"$output_file" 2>&1 || {
    local rc=$?
    printf "\n[triage.sh] Command exited with status %d\n" "$rc" >>"$output_file"
    warn "Optional command failed (${rc}): $*"
    return 0
  }
}

mask_value() {
  local value="$1"
  if [[ -n "$value" ]]; then
    printf '********'
  fi
}

format_command() {
  local args=("$@")
  local rendered=()
  local i

  for ((i = 0; i < ${#args[@]}; i++)); do
    rendered+=("$(printf '%q' "${args[i]}")")
  done

  local old_ifs="$IFS"
  IFS=' '
  printf '%s' "${rendered[*]}"
  IFS="$old_ifs"
}

profile_validation_target() {
  local candidate

  if [[ -f "$PROFILE" ]]; then
    printf '%s\n' "$PROFILE"
    return 0
  fi

  if [[ -f "$UAC_DIR/profiles/${PROFILE}.yaml" ]]; then
    printf '%s\n' "$UAC_DIR/profiles/${PROFILE}.yaml"
    return 0
  fi

  if [[ -f "$UAC_DIR/profiles/${PROFILE}" ]]; then
    printf '%s\n' "$UAC_DIR/profiles/${PROFILE}"
    return 0
  fi

  while IFS= read -r candidate; do
    if grep -q -E "^name:[[:space:]]+${PROFILE}[[:space:]]*$" "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$UAC_DIR/profiles" -maxdepth 1 -type f -name '*.yaml' | sort)

  return 1
}

phase() {
  printf "\n[%b%s%b] %s\n" "$CYAN" "$1" "$RESET" "$2"
}

path_starts_with() {
  local path="$1"
  local prefix="$2"

  [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

show_configuration() {
  printf "\nConfiguration Summary\n"
  printf "  Source Mount    : %s\n" "$MOUNT_POINT"
  printf "  Destination Root: %s\n" "$EVIDENCE_ROOT"
  printf "  Output Directory: %s\n" "$OUTPUT_DIR"
  printf "  Temp Directory  : %s\n" "$TEMP_DIR"
  printf "  UAC Directory   : %s\n" "$UAC_DIR"
  printf "  Profile         : %s\n" "$PROFILE"
  printf "  Archive Format  : %s\n" "$ARCHIVE_FORMAT"
  printf "  Zip Password    : %s\n" "$([[ -n "$ARCHIVE_PASSWORD" ]] && echo "set" || echo "not set")"
  printf "  Hash All Files  : %s\n" "$HASH_ALL"
  printf "  Case Number     : %s\n" "$CASE_NUMBER"
  printf "  Evidence Number : %s\n" "$EVIDENCE_NUMBER"
  printf "  Examiner        : %s\n" "$EXAMINER"
  printf "  Description     : %s\n" "$DESCRIPTION"
  printf "  Notes           : %s\n" "$NOTES"
}

confirm_configuration() {
  local reply

  if [[ "$NON_INTERACTIVE" == true || "$ASSUME_YES" == true || ! -t 0 ]]; then
    return
  fi

  read -r -p "Proceed with this configuration? [y/N]: " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      die "Execution cancelled by operator."
      ;;
  esac
}

prompt_if_missing CASE_NUMBER "--case-number"
prompt_if_missing EVIDENCE_NUMBER "--evidence-number"
prompt_if_missing EXAMINER "--examiner"

case "$ARCHIVE_FORMAT" in
  zip|tar|tar.gz)
    ;;
  *)
    die "Unsupported archive format: ${ARCHIVE_FORMAT}. Use zip, tar, or tar.gz."
    ;;
esac

if [[ "$ARCHIVE_FORMAT" != "zip" && -n "$ARCHIVE_PASSWORD" ]]; then
  die "--zip-password can only be used when --format zip is selected."
fi

need_command hostname
need_command date
need_command mkdir
need_command find
need_command sort
need_command xargs
need_command sha256sum
need_command df
need_command mount
need_command ps
need_command ip
need_command uptime
need_command ls
need_command tee

[[ -d "$UAC_DIR" ]] || die "UAC directory not found: $UAC_DIR"
UAC_BIN="$UAC_DIR/uac"
[[ -x "$UAC_BIN" ]] || die "UAC binary is not executable: $UAC_BIN"
[[ -d "$MOUNT_POINT" ]] || die "Mount point does not exist: $MOUNT_POINT"

PROFILE_VALIDATE_PATH="$(profile_validation_target)" || die "Unable to resolve profile for validation: $PROFILE"

OUTPUT_DIR="${OUTPUT_DIR:-$EVIDENCE_ROOT/uac-output}"
TEMP_DIR="${TEMP_DIR:-$EVIDENCE_ROOT/uac-temp}"
CASE_NOTES_DIR="$EVIDENCE_ROOT/case-notes"
TRANSCRIPTS_DIR="$EVIDENCE_ROOT/transcripts"

mkdir -p "$OUTPUT_DIR" "$TEMP_DIR" "$CASE_NOTES_DIR" "$TRANSCRIPTS_DIR"

RUN_LOG="$CASE_NOTES_DIR/triage_execution.log"
exec > >(tee -a "$RUN_LOG") 2>&1

HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown-host)"
UTC_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
INITIAL_NOTES_FILE="$CASE_NOTES_DIR/initial_notes.txt"
SYSTEM_INFO_FILE="$CASE_NOTES_DIR/system_info.txt"
COMMAND_LOG_FILE="$CASE_NOTES_DIR/uac_command.txt"
SCRIPT_INVOCATION_FILE="$CASE_NOTES_DIR/triage_invocation.txt"

if [[ "$ARCHIVE_FORMAT" == "zip" && -z "$ARCHIVE_PASSWORD" ]]; then
  warn "Zip output selected without --zip-password. The archive will not be password-protected."
fi

if [[ $EUID -ne 0 ]]; then
  warn "The script is not running as root. Live-response artifacts may be incomplete."
fi

if command -v mountpoint >/dev/null 2>&1; then
  if mountpoint -q "$EVIDENCE_ROOT"; then
    ok "Destination root is a mounted filesystem: $EVIDENCE_ROOT"
  else
    warn "Destination root is not a separate mount point: $EVIDENCE_ROOT"
  fi
else
  warn "mountpoint command not available; skipping mount-point validation."
fi

if [[ "$MOUNT_POINT" == "/" ]]; then
  info "Live collection mode selected: UAC will collect from /."
else
  info "Mounted/offline collection root selected: $MOUNT_POINT"
fi

if path_starts_with "$EVIDENCE_ROOT" "$MOUNT_POINT"; then
  warn "Destination root is inside the collection mount point. Output may be written to the source filesystem."
fi

show_configuration
confirm_configuration

REDACTED_SCRIPT_ARGS=()
skip_next=false

for arg in "${ORIGINAL_ARGS[@]}"; do
  if [[ "$skip_next" == true ]]; then
    REDACTED_SCRIPT_ARGS+=("********")
    skip_next=false
    continue
  fi

  if [[ "$arg" == "--zip-password" ]]; then
    REDACTED_SCRIPT_ARGS+=("$arg")
    skip_next=true
    continue
  fi

  REDACTED_SCRIPT_ARGS+=("$arg")
done

{
  printf "Script: %s\n" "$0"
  printf "Invocation: %s %s\n" "$0" "$(format_command "${REDACTED_SCRIPT_ARGS[@]}")"
  printf "UTC Start: %s\n" "$UTC_START"
  printf "Source Mount: %s\n" "$MOUNT_POINT"
  printf "Destination Root: %s\n" "$EVIDENCE_ROOT"
  printf "Case Number: %s\n" "$CASE_NUMBER"
  printf "Evidence Number: %s\n" "$EVIDENCE_NUMBER"
  printf "Examiner: %s\n" "$EXAMINER"
  printf "Profile: %s\n" "$PROFILE"
  printf "Archive Format: %s\n" "$ARCHIVE_FORMAT"
  printf "Zip Password Set: %s\n" "$([[ -n "$ARCHIVE_PASSWORD" ]] && echo yes || echo no)"
  printf "Hash All Files: %s\n" "$HASH_ALL"
  printf "UAC Directory: %s\n" "$UAC_DIR"
  printf "Output Directory: %s\n" "$OUTPUT_DIR"
  printf "Temp Directory: %s\n" "$TEMP_DIR"
} >"$SCRIPT_INVOCATION_FILE"

phase "Phase 1" "Prepare trusted working area"

{
  printf "Case: %s\n" "$CASE_NUMBER"
  printf "Evidence: %s\n" "$EVIDENCE_NUMBER"
  printf "Host: %s\n" "$HOSTNAME_VALUE"
  printf "UTC Start: %s\n" "$UTC_START"
  printf "Examiner: %s\n" "$EXAMINER"
  printf "Source Mount: %s\n" "$MOUNT_POINT"
  printf "Destination Root: %s\n" "$EVIDENCE_ROOT"
  printf "Profile: %s\n" "$PROFILE"
  printf "Archive Format: %s\n" "$ARCHIVE_FORMAT"
  printf "Description: %s\n" "$DESCRIPTION"
  printf "Notes: %s\n" "$NOTES"
} >"$INITIAL_NOTES_FILE"

{
  printf "whoami:\n"
  whoami || true
  printf "\n"
  printf "id:\n"
  id || true
  printf "\n"
  printf "hostname:\n"
  hostname || true
  printf "\n"
  printf "date -u:\n"
  date -u || true
  printf "\n"
  printf "uname -a:\n"
  uname -a || true
  printf "\n"
  printf "pwd:\n"
  pwd -P || true
  printf "\n"
  if command -v w >/dev/null 2>&1; then
    printf "w:\n"
    w || true
    printf "\n"
  fi
  if command -v who >/dev/null 2>&1; then
    printf "who:\n"
    who || true
    printf "\n"
  fi
  if command -v last >/dev/null 2>&1; then
    printf "last -n 5:\n"
    last -n 5 || true
    printf "\n"
  fi
  if command -v sudo >/dev/null 2>&1; then
    printf "sudo -n -v:\n"
    sudo -n -v || true
    printf "\n"
    printf "sudo -n whoami:\n"
    sudo -n whoami || true
    printf "\n"
  fi
} >"$SYSTEM_INFO_FILE" 2>&1

capture_command "$OUTPUT_DIR/initial_uac_listing.txt" ls -la "$UAC_DIR"
run_uac --version >"$OUTPUT_DIR/uac_version.txt"
run_uac --profile list >"$OUTPUT_DIR/uac_profiles.txt"
if ! run_uac --validate-profile "$PROFILE_VALIDATE_PATH" >"$OUTPUT_DIR/uac_validation.txt" 2>&1; then
  die "UAC rejected profile '$PROFILE'. Review $OUTPUT_DIR/uac_validation.txt for the validation error."
fi
ok "Evidence folder structure created under $EVIDENCE_ROOT"

phase "Phase 2" "Decide if memory capture is needed"
warn "Memory capture is still a separate decision point. This wrapper does not acquire RAM by itself."

phase "Phase 3" "Collect minimal context before running UAC"

capture_command "$TRANSCRIPTS_DIR/00_df_evidence_root.txt" df -h "$EVIDENCE_ROOT"
capture_command "$TRANSCRIPTS_DIR/01_date_utc.txt" date -u
capture_command "$TRANSCRIPTS_DIR/02_uptime.txt" uptime
capture_command "$TRANSCRIPTS_DIR/03_ip_addr.txt" ip addr
capture_command "$TRANSCRIPTS_DIR/04_ip_route.txt" ip route
capture_command "$TRANSCRIPTS_DIR/05_ss_tupan.txt" ss -tupan
capture_command "$TRANSCRIPTS_DIR/06_ps_auxwf.txt" ps auxwf
capture_command "$TRANSCRIPTS_DIR/07_mount.txt" mount
capture_command "$TRANSCRIPTS_DIR/08_df_h.txt" df -h
ok "Context collected and saved to $TRANSCRIPTS_DIR"

phase "Phase 4" "Run UAC live triage profile"

UAC_ARGS=()

if [[ "$HASH_ALL" == true ]]; then
  UAC_ARGS+=(-H)
fi

UAC_ARGS+=(-p "$PROFILE" -f "$ARCHIVE_FORMAT" --mount-point "$MOUNT_POINT")

if [[ -n "$ARCHIVE_PASSWORD" ]]; then
  UAC_ARGS+=(-P "$ARCHIVE_PASSWORD")
fi

UAC_ARGS+=(
  -o "$OUTPUT_NAME"
  --case-number "$CASE_NUMBER"
  --evidence-number "$EVIDENCE_NUMBER"
  --description "$DESCRIPTION"
  --examiner "$EXAMINER"
  --notes "$NOTES"
  --temp-dir "$TEMP_DIR"
  "$OUTPUT_DIR"
)

{
  printf "Exact UAC command (password redacted):\n"
  if [[ -n "$ARCHIVE_PASSWORD" ]]; then
    REDACTED_UAC_CMD=()
    skip_next=false

    for arg in "${UAC_ARGS[@]}"; do
      if [[ "$skip_next" == true ]]; then
        skip_next=false
        continue
      fi

      if [[ "$arg" == "-P" ]]; then
        REDACTED_UAC_CMD+=("$arg" "$(mask_value "$ARCHIVE_PASSWORD")")
        skip_next=true
        continue
      fi

      REDACTED_UAC_CMD+=("$arg")
    done

    printf "cd %q && ./uac %s\n" "$UAC_DIR" "$(format_command "${REDACTED_UAC_CMD[@]}")"
  else
    printf "cd %q && ./uac %s\n" "$UAC_DIR" "$(format_command "${UAC_ARGS[@]}")"
  fi
} >"$COMMAND_LOG_FILE"

run_uac "${UAC_ARGS[@]}"
ok "UAC run completed and output saved to $OUTPUT_DIR"

phase "Phase 5" "Post-UAC context and next steps"

{
  printf "\nExecution Log: %s\n" "$RUN_LOG"
  printf "Command Log: %s\n" "$COMMAND_LOG_FILE"
  printf "Archives SHA256:\n"
} >>"$INITIAL_NOTES_FILE"

find "$OUTPUT_DIR" -maxdepth 1 -type f \
  \( -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o \
     -iname '*.zip' -o -iname '*.7z' -o -iname '*.rar' -o \
     -iname '*.gz' -o -iname '*.bz2' -o -iname '*.xz' \) \
  -print0 \
  | sort -z \
  | xargs -0 -r sha256sum >>"$INITIAL_NOTES_FILE"

ok "Post-UAC notes updated in $INITIAL_NOTES_FILE"
info "Review $RUN_LOG, $COMMAND_LOG_FILE, and the hash list before exporting the evidence package."
