#!/bin/sh

set -eu

CALLER_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${SCP_POLICY_FILE:-}" ]; then
  POLICY_FILE=$SCP_POLICY_FILE
elif [ -f "$CALLER_DIR/policy.conf" ]; then
  POLICY_FILE="$CALLER_DIR/policy.conf"
else
  POLICY_FILE="$CALLER_DIR/policy/default-policy.conf"
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "Missing policy file: $POLICY_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$POLICY_FILE"

LOCAL_POLICY_FILE=""
if [ -z "${SCP_POLICY_FILE:-}" ] && [ "$POLICY_FILE" = "$CALLER_DIR/policy/default-policy.conf" ]; then
  if [ -f "$CALLER_DIR/policy/local-policy.conf" ]; then
    LOCAL_POLICY_FILE="$CALLER_DIR/policy/local-policy.conf"
  elif [ -f "$CALLER_DIR/policy.conf" ]; then
    LOCAL_POLICY_FILE="$CALLER_DIR/policy.conf"
  fi
fi

if [ -n "$LOCAL_POLICY_FILE" ]; then
  # shellcheck disable=SC1090
  . "$LOCAL_POLICY_FILE"
fi

detect_platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

PLATFORM=$(detect_platform)

default_state_root() {
  case "$PLATFORM" in
    windows)
      if [ -n "${LOCALAPPDATA:-}" ]; then
        printf '%s/SupplyChainProtect' "$LOCALAPPDATA"
      else
        printf '%s/AppData/Local/SupplyChainProtect' "$HOME"
      fi
      ;;
    *)
      printf '%s/.local/share/%s' "$HOME" "${STATE_DIR_NAME:-supply-chain-protect}"
      ;;
  esac
}

default_config_root() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config' "$HOME"
  fi
}

STATE_ROOT=${INSTALL_ROOT_OVERRIDE:-"$(default_state_root)"}
CONFIG_ROOT=${CONFIG_ROOT_OVERRIDE:-"$(default_config_root)"}
LOG_ROOT="$STATE_ROOT/logs"
SHIM_ROOT="$STATE_ROOT/shims"
RUNTIME_ROOT="$STATE_ROOT/runtime"
ATT_ROOT="$STATE_ROOT/attestation"
RUNSTATE_FILE="$STATE_ROOT/runtime/state.conf"
BINMAP_FILE="$STATE_ROOT/runtime/binmap.conf"
PROFILE_SNIPPET="$STATE_ROOT/runtime/profile.sh"
WRAPPER_BIN="$STATE_ROOT/runtime/manager-wrapper.sh"
COMMON_RUNTIME="$STATE_ROOT/runtime/common.sh"
AGGREGATE_LOG="$LOG_ROOT/events.jsonl"
STATUS_FILE="$ATT_ROOT/status.env"

MARKER_BEGIN="# >>> supply-chain-protect >>>"
MARKER_END="# <<< supply-chain-protect <<<"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

timestamp_slug() {
  date -u +"%Y%m%dT%H%M%SZ"
}

hostname_safe() {
  hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown-host
}

sha256_file() {
  target=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    cksum "$target" | awk '{print $1 "-" $2}'
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s///g; s/	/\\t/g'
}

ensure_dirs() {
  mkdir -p "$STATE_ROOT" "$LOG_ROOT" "$SHIM_ROOT" "$RUNTIME_ROOT" "$ATT_ROOT"
}

log_init() {
  ensure_dirs
  LOG_CONTEXT=${1:-tool}
  LOG_RUN_ID="$(timestamp_slug)-$$"
  RUN_LOG_TXT="$LOG_ROOT/$LOG_RUN_ID-$LOG_CONTEXT.log"
  : >"$RUN_LOG_TXT"
  touch "$AGGREGATE_LOG"
}

log_line() {
  level=$1
  shift
  msg=$*
  ts=$(timestamp_utc)
  if [ -n "${RUN_LOG_TXT:-}" ]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$RUN_LOG_TXT"
  else
    printf '%s [%s] %s\n' "$ts" "$level" "$msg"
  fi
}

log_json_event() {
  level=$1
  event=$2
  tool=${3:-}
  command_text=${4:-}
  status=${5:-}
  detail=${6:-}
  ts=$(timestamp_utc)
  user_name=${USER:-${USERNAME:-unknown}}
  host_name=$(hostname_safe)
  printf '{"timestamp":"%s","level":"%s","event":"%s","tool":"%s","command":"%s","status":"%s","policy_mode":"%s","policy_version":"%s","user":"%s","host":"%s","platform":"%s","detail":"%s"}\n' \
    "$(json_escape "$ts")" \
    "$(json_escape "$level")" \
    "$(json_escape "$event")" \
    "$(json_escape "$tool")" \
    "$(json_escape "$command_text")" \
    "$(json_escape "$status")" \
    "$(json_escape "${ENFORCEMENT_MODE:-unset}")" \
    "$(json_escape "$POLICY_VERSION")" \
    "$(json_escape "$user_name")" \
    "$(json_escape "$host_name")" \
    "$(json_escape "$PLATFORM")" \
    "$(json_escape "$detail")" >>"$AGGREGATE_LOG"
}

log_info() {
  log_line INFO "$@"
}

log_warn() {
  log_line WARN "$@"
}

log_error() {
  log_line ERROR "$@"
}

load_runtime_state() {
  if [ -f "$RUNSTATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$RUNSTATE_FILE"
  fi
  if [ -f "$BINMAP_FILE" ]; then
    # shellcheck disable=SC1090
    . "$BINMAP_FILE"
  fi
}

save_runtime_state() {
  mode=$1
  cat >"$RUNSTATE_FILE" <<EOF
ENFORCEMENT_MODE="$mode"
POLICY_VERSION_APPLIED="$POLICY_VERSION"
STATE_ROOT="$STATE_ROOT"
SHIM_ROOT="$SHIM_ROOT"
LOG_ROOT="$LOG_ROOT"
PROFILE_SNIPPET="$PROFILE_SNIPPET"
UPDATED_AT="$(timestamp_utc)"
EOF
}

save_status() {
  result=$1
  cat >"$STATUS_FILE" <<EOF
STATUS="$result"
ENFORCEMENT_MODE="${ENFORCEMENT_MODE:-unset}"
POLICY_VERSION="$POLICY_VERSION"
UPDATED_AT="$(timestamp_utc)"
SHIM_HASH="$( [ -f "$WRAPPER_BIN" ] && sha256_file "$WRAPPER_BIN" || echo missing )"
EOF
}

append_managed_block() {
  target=$1
  body=$2
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    tmp="$target.tmp.$$"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      skip != 1 { print }
    ' "$target" >"$tmp"
    mv "$tmp" "$target"
  fi
  {
    [ -s "$target" ] && printf '\n'
    printf '%s\n' "$MARKER_BEGIN"
    printf '%s\n' "$body"
    printf '%s\n' "$MARKER_END"
  } >>"$target"
}

remove_managed_block() {
  target=$1
  [ -f "$target" ] || return 0
  tmp="$target.tmp.$$"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$target" >"$tmp"
  mv "$tmp" "$target"
}

find_real_binary() {
  tool=$1
  old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ "$dir" = "$SHIM_ROOT" ] && continue
    if [ -x "$dir/$tool" ] && [ ! -d "$dir/$tool" ]; then
      printf '%s\n' "$dir/$tool"
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

resolve_real_binary() {
  tool=$1
  if ! candidate=$(find_real_binary "$tool" 2>/dev/null); then
    return 1
  fi

  case "$candidate" in
    */.asdf/shims/*)
      if command -v asdf >/dev/null 2>&1; then
        resolved=$(asdf which "$tool" 2>/dev/null || true)
        if [ -n "$resolved" ] && [ -x "$resolved" ]; then
          printf '%s\n' "$resolved"
          return 0
        fi
      fi
      ;;
  esac

  printf '%s\n' "$candidate"
}

list_detected_tools() {
  for tool in $MANAGED_COMMANDS; do
    if find_real_binary "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
    fi
  done
}

is_ai_tool() {
  tool=$1
  for item in $AI_COMMANDS; do
    [ "$item" = "$tool" ] && return 0
  done
  return 1
}

is_package_manager() {
  tool=$1
  for item in $PACKAGE_MANAGERS; do
    [ "$item" = "$tool" ] && return 0
  done
  return 1
}

require_hard_value() {
  name=$1
  value=$2
  case "$value" in
    ""|*example.corp*|*invalid*)
      log_error "Hard mode requires a real value for $name"
      log_json_event "ERROR" "policy.invalid" "$name" "" "blocked" "placeholder value"
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

rotate_logs() {
  [ -d "$LOG_ROOT" ] || return 0
  find "$LOG_ROOT" -type f -name "*.log" -mtime +"${LOG_RETENTION_DAYS:-30}" -exec rm -f {} \; 2>/dev/null || true
}

current_mode() {
  load_runtime_state
  if [ -n "${ENFORCEMENT_MODE:-}" ]; then
    printf '%s\n' "$ENFORCEMENT_MODE"
  else
    printf '%s\n' "${DEFAULT_MODE:-soft}"
  fi
}

verify_path_snippet() {
  target=$1
  [ -f "$target" ] && grep -F "$MARKER_BEGIN" "$target" >/dev/null 2>&1
}

platform_supports_windows_helper() {
  [ "$PLATFORM" = "windows" ]
}

# Emit "username:home_dir" for each local user eligible for machine-scope apply.
# Reads from /etc/passwd by default; set PASSWD_FILE to override (useful in tests).
list_local_users() {
  if [ "$PLATFORM" = "macos" ] && [ -z "${PASSWD_FILE:-}" ]; then
    list_local_users_macos
  else
    list_local_users_passwd
  fi
}

list_local_users_passwd() {
  uid_min=${LOCAL_USER_UID_MIN:-1000}
  uid_max=${LOCAL_USER_UID_MAX:-60000}
  passwd_src=${PASSWD_FILE:-/etc/passwd}
  awk -F: -v min="$uid_min" -v max="$uid_max" '
    $3 >= min && $3 < max &&
    $7 !~ /(nologin|\/false|\/sync|\/halt|\/shutdown)/ {
      print $1 ":" $6
    }
  ' "$passwd_src"
}

# macOS stores real user accounts in Directory Services, not /etc/passwd
# (which only carries legacy system entries there), so enumerate via dscl.
list_local_users_macos() {
  uid_min=${LOCAL_USER_UID_MIN:-500}
  uid_max=${LOCAL_USER_UID_MAX:-60000}
  dscl . -list /Users UniqueID 2>/dev/null | awk -v min="$uid_min" -v max="$uid_max" \
    '$2 >= min && $2 < max { print $1 }' | while IFS= read -r uname; do
    home=$(dscl . -read "/Users/$uname" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    printf '%s:%s\n' "$uname" "${home:-/Users/$uname}"
  done
}

# Apply package-manager configs for a given user home directory.
# Temporarily substitutes HOME and CONFIG_ROOT, then restores them.
apply_user_configs_for_home() {
  target_home=$1
  target_config=$2
  _saved_home=$HOME
  _saved_config=$CONFIG_ROOT
  HOME=$target_home
  CONFIG_ROOT=$target_config
  configure_npm
  configure_bun
  configure_pip
  configure_cargo
  HOME=$_saved_home
  CONFIG_ROOT=$_saved_config
}

# Remove managed blocks from all package-manager configs under a given home.
remove_user_configs_for_home() {
  target_home=$1
  target_config=$2
  remove_managed_block "$target_home/.profile"
  remove_managed_block "$target_home/.bashrc"
  remove_managed_block "$target_home/.zshrc"
  remove_managed_block "$target_home/.npmrc"
  remove_managed_block "$target_home/.bunfig.toml"
  remove_managed_block "$target_config/pip/pip.conf"
  remove_managed_block "$target_home/.cargo/config.toml"
}

# Write /etc/profile.d/supply-gate.sh and add managed blocks to system rc files.
# Requires root. PROFILE_SNIPPET must already be written (via write_profile_snippet).
apply_system_profiles() {
  profile_d_file="/etc/profile.d/supply-gate.sh"
  mkdir -p "$(dirname "$profile_d_file")"
  printf '. "%s"\n' "$PROFILE_SNIPPET" >"$profile_d_file"
  chmod 644 "$profile_d_file"
  block=". \"$PROFILE_SNIPPET\""
  for sys_rc in /etc/bash.bashrc /etc/zshrc /etc/zsh/zshrc; do
    [ -f "$sys_rc" ] && append_managed_block "$sys_rc" "$block"
  done
}

# Remove /etc/profile.d/supply-gate.sh and managed blocks from system rc files.
remove_system_profiles() {
  rm -f /etc/profile.d/supply-gate.sh
  for sys_rc in /etc/bash.bashrc /etc/zshrc /etc/zsh/zshrc; do
    [ -f "$sys_rc" ] && remove_managed_block "$sys_rc"
  done
}

# Count managed files under a home directory; print "username: N files managed" or
# "username: not configured". A non-empty 4th argument indicates the system-wide
# profile layer is active, in which case a user with no per-user package configs is
# still covered (machine scope intentionally does not write per-user shell dotfiles).
status_user() {
  username=$1
  home_dir=$2
  config_dir=$3
  system_active=${4:-}
  n=0
  managed_list=""
  for f in "$home_dir/.profile" "$home_dir/.bashrc" "$home_dir/.zshrc" \
            "$home_dir/.npmrc" "$home_dir/.bunfig.toml" \
            "$config_dir/pip/pip.conf" "$home_dir/.cargo/config.toml"; do
    [ -f "$f" ] || continue
    grep -qF "$MARKER_BEGIN" "$f" || continue
    n=$((n + 1))
    label=$(basename "$f")
    managed_list="$managed_list $label"
  done
  if [ "$n" -gt 0 ]; then
    printf '  %-12s (%s): %d file(s) managed [%s]\n' \
      "$username" "$home_dir" "$n" "$managed_list"
  elif [ -n "$system_active" ]; then
    printf '  %-12s (%s): covered by system-wide profile (no per-user package configs)\n' \
      "$username" "$home_dir"
  else
    printf '  %-12s (%s): not configured\n' "$username" "$home_dir"
  fi
}

# Print the system-wide install status.
status_system() {
  printf 'System-wide:\n'
  if [ -f /etc/profile.d/supply-gate.sh ]; then
    printf '  /etc/profile.d/supply-gate.sh: present\n'
  else
    printf '  /etc/profile.d/supply-gate.sh: absent\n'
  fi
  for sys_rc in /etc/bash.bashrc /etc/zshrc /etc/zsh/zshrc; do
    [ -f "$sys_rc" ] || continue
    if grep -qF "$MARKER_BEGIN" "$sys_rc"; then
      printf '  %s: managed block present\n' "$sys_rc"
    else
      printf '  %s: no managed block\n' "$sys_rc"
    fi
  done
}
