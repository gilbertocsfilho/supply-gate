#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

SUBCOMMAND=${1:-}
shift || true

MODE=""
SCOPE=""

usage() {
  cat <<EOF
Usage:
  ./install.sh apply [--mode soft|hard] [--scope user|machine]
  ./install.sh audit [--scope user|machine]
  ./install.sh repair
  ./install.sh status
  ./install.sh install-optional-tools [--scfw] [--bumblebee] [--all]
  ./install.sh uninstall [--scope user|machine]

  --scope user    (default) apply only to the current user
  --scope machine apply to all local users and system-wide profile layer
                  requires root; used for KACE or similar deployment tools
EOF
}

parse_mode_flag() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        MODE=${2:-}
        shift 2
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done
}

parse_scope_flag() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)
        SCOPE=${2:-}
        shift 2
        case "$SCOPE" in
          user|machine) ;;
          *)
            echo "Unknown scope: $SCOPE (use 'user' or 'machine')" >&2
            exit 2
            ;;
        esac
        ;;
      --mode)
        MODE=${2:-}
        shift 2
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done
}

require_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "ERROR: --scope machine requires root privileges (use sudo)" >&2
    exit 1
  fi
}

# Override STATE_ROOT and all derived paths to system-wide locations.
# Must be called before ensure_dirs and any function that uses these paths.
setup_system_paths() {
  system_root=${INSTALL_ROOT_OVERRIDE:-/opt/supply-gate}
  STATE_ROOT="$system_root"
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
}

optional_tools_requested() {
  [ "$INSTALL_SCFW" = "1" ] || [ "$INSTALL_BUMBLEBEE" = "1" ]
}

parse_optional_tools_flags() {
  INSTALL_SCFW=0
  INSTALL_BUMBLEBEE=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --scfw)
        INSTALL_SCFW=1
        shift
        ;;
      --bumblebee)
        INSTALL_BUMBLEBEE=1
        shift
        ;;
      --all)
        INSTALL_SCFW=1
        INSTALL_BUMBLEBEE=1
        shift
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done

  if ! optional_tools_requested; then
    INSTALL_SCFW=1
    INSTALL_BUMBLEBEE=1
  fi
}

require_command() {
  tool=$1
  install_hint=$2
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  log_error "Missing required command: $tool"
  log_error "$install_hint"
  return 1
}

go_version_at_least() {
  required_major=$1
  required_minor=$2

  if ! go_bin=$(resolve_real_binary go 2>/dev/null); then
    return 1
  fi

  if ! go_version_output=$("$go_bin" version 2>/dev/null); then
    return 1
  fi

  go_version_token=$(printf '%s\n' "$go_version_output" | awk '{print $3}')
  go_version_token=${go_version_token#go}
  go_major=$(printf '%s' "$go_version_token" | cut -d. -f1)
  go_minor=$(printf '%s' "$go_version_token" | cut -d. -f2)

  case "$go_major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$go_minor" in
    ''|*[!0-9]*) return 1 ;;
  esac

  if [ "$go_major" -gt "$required_major" ]; then
    return 0
  fi
  if [ "$go_major" -lt "$required_major" ]; then
    return 1
  fi
  [ "$go_minor" -ge "$required_minor" ]
}

install_scfw_tool() {
  case "$PLATFORM" in
    windows)
      log_warn "Skipping scfw install: upstream support is not available for Windows"
      log_json_event "WARN" "optional.install.skipped" "scfw" "install-optional-tools" "skipped" "unsupported platform windows"
      return 0
      ;;
    macos|linux) ;;
    *)
      log_warn "Skipping scfw install: unsupported platform $PLATFORM"
      log_json_event "WARN" "optional.install.skipped" "scfw" "install-optional-tools" "skipped" "unsupported platform"
      return 0
      ;;
  esac

  require_command pipx "Install pipx first, then rerun this command." || return 1

  if command -v scfw >/dev/null 2>&1; then
    log_info "scfw is already installed; refreshing via pipx"
    if pipx upgrade scfw >/dev/null 2>&1; then
      log_info "scfw upgraded successfully"
      log_json_event "INFO" "optional.install.completed" "scfw" "install-optional-tools" "success" "pipx upgrade"
      return 0
    fi
    log_warn "pipx upgrade scfw failed; trying reinstall"
    if pipx reinstall scfw >/dev/null 2>&1; then
      log_info "scfw reinstalled successfully"
      log_json_event "INFO" "optional.install.completed" "scfw" "install-optional-tools" "success" "pipx reinstall"
      return 0
    fi
    log_error "Failed to upgrade or reinstall scfw"
    log_json_event "ERROR" "optional.install.failed" "scfw" "install-optional-tools" "failure" "pipx upgrade/reinstall failed"
    return 1
  fi

  if pipx install scfw >/dev/null 2>&1; then
    log_info "scfw installed successfully"
    log_json_event "INFO" "optional.install.completed" "scfw" "install-optional-tools" "success" "pipx install"
    return 0
  fi

  log_error "Failed to install scfw via pipx"
  log_json_event "ERROR" "optional.install.failed" "scfw" "install-optional-tools" "failure" "pipx install failed"
  return 1
}

install_bumblebee_tool() {
  case "$PLATFORM" in
    windows)
      log_warn "Skipping bumblebee install: upstream supports macOS and Linux only as of May 23, 2026"
      log_json_event "WARN" "optional.install.skipped" "bumblebee" "install-optional-tools" "skipped" "unsupported platform windows"
      return 0
      ;;
    macos|linux) ;;
    *)
      log_warn "Skipping bumblebee install: unsupported platform $PLATFORM"
      log_json_event "WARN" "optional.install.skipped" "bumblebee" "install-optional-tools" "skipped" "unsupported platform"
      return 0
      ;;
  esac

  require_command go "Install Go 1.25+ first, then rerun this command." || return 1
  if ! go_bin=$(resolve_real_binary go 2>/dev/null); then
    log_error "Failed to resolve the real Go binary"
    log_json_event "ERROR" "optional.install.failed" "bumblebee" "install-optional-tools" "failure" "cannot resolve real go binary"
    return 1
  fi
  if ! go_version_at_least 1 25; then
    log_error "bumblebee install requires Go 1.25+"
    log_error "Current version: $("$go_bin" version 2>/dev/null || echo unknown)"
    log_json_event "ERROR" "optional.install.failed" "bumblebee" "install-optional-tools" "failure" "requires Go 1.25+"
    return 1
  fi

  if "$go_bin" install github.com/perplexityai/bumblebee/cmd/bumblebee@v0.1.1 >/dev/null 2>&1; then
    log_info "bumblebee installed successfully"
    log_json_event "INFO" "optional.install.completed" "bumblebee" "install-optional-tools" "success" "go install v0.1.1"
    return 0
  fi

  log_error "Failed to install bumblebee via go install"
  log_json_event "ERROR" "optional.install.failed" "bumblebee" "install-optional-tools" "failure" "go install failed"
  return 1
}

install_optional_tools_cmd() {
  parse_optional_tools_flags "$@"
  log_init "install-optional-tools"
  ENFORCEMENT_MODE=${DEFAULT_MODE:-soft}
  failures=0

  log_info "Installing optional tools"
  log_json_event "INFO" "optional.install.started" "install.sh" "install-optional-tools" "started" "optional tools install"

  if [ "$INSTALL_SCFW" = "1" ]; then
    install_scfw_tool || failures=$((failures + 1))
  fi

  if [ "$INSTALL_BUMBLEBEE" = "1" ]; then
    install_bumblebee_tool || failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    log_error "Optional tool installation finished with $failures failure(s)"
    log_json_event "ERROR" "optional.install.completed" "install.sh" "install-optional-tools" "failure" "$failures failures"
    exit 1
  fi

  log_info "Optional tool installation completed"
  log_json_event "INFO" "optional.install.completed" "install.sh" "install-optional-tools" "success" "all requested tools handled"
}

write_profile_snippet() {
  cat >"$PROFILE_SNIPPET" <<EOF
export PATH="$SHIM_ROOT:\$PATH"
EOF
}

apply_posix_profiles() {
  write_profile_snippet
  block=". \"$PROFILE_SNIPPET\""
  append_managed_block "$HOME/.profile" "$block"
  append_managed_block "$HOME/.bashrc" "$block"
  append_managed_block "$HOME/.zshrc" "$block"
}

call_windows_helper() {
  action=$1
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/scripts/windows-apply.ps1" \
      -ShimRoot "$SHIM_ROOT" \
      -ProfileSnippet "$PROFILE_SNIPPET" \
      -MarkerBegin "$MARKER_BEGIN" \
      -MarkerEnd "$MARKER_END" \
      -Action "$action"
  else
    log_warn "powershell.exe not found; Windows PATH/profile enforcement was not updated"
  fi
}

install_runtime() {
  cp "$SCRIPT_DIR/lib/common.sh" "$COMMON_RUNTIME"
  cp "$SCRIPT_DIR/shims/manager-wrapper.sh" "$WRAPPER_BIN"
  cat "$POLICY_FILE" >"$RUNTIME_ROOT/policy.conf"
  if [ -n "${LOCAL_POLICY_FILE:-}" ] && [ -f "$LOCAL_POLICY_FILE" ]; then
    {
      printf '\n'
      printf '# Local overrides applied at install time\n'
      cat "$LOCAL_POLICY_FILE"
    } >>"$RUNTIME_ROOT/policy.conf"
  fi
  chmod 755 "$COMMON_RUNTIME" "$WRAPPER_BIN"
}

configure_npm() {
  block=$(cat <<EOF
save-exact=true
min-release-age=7
minimum-release-age=${NODE_COOLDOWN_MINUTES}
$( if [ "$ENFORCEMENT_MODE" = "hard" ]; then printf 'registry=%s\n' "$NPM_REGISTRY_URL"; fi )
EOF
)
  append_managed_block "$HOME/.npmrc" "$block"
}

configure_bun() {
  block=$(cat <<EOF
[install]
minimumReleaseAge = ${BUN_COOLDOWN_SECONDS}
EOF
)
  append_managed_block "$HOME/.bunfig.toml" "$block"
}

configure_pip() {
  pip_conf="$CONFIG_ROOT/pip/pip.conf"
  block=$(cat <<EOF
[global]
disable-pip-version-check = true
$( if [ "$ENFORCEMENT_MODE" = "hard" ]; then printf 'index-url = %s\n' "$PYTHON_INDEX_URL"; fi )
EOF
)
  append_managed_block "$pip_conf" "$block"
}

configure_cargo() {
  cargo_conf="$HOME/.cargo/config.toml"
  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    block=$(cat <<EOF
[registries.crates-io]
protocol = "sparse"
[source.crates-io]
replace-with = "corporate"
[source.corporate]
registry = "${CARGO_REGISTRY_URL}"
EOF
)
  else
    block=$(cat <<EOF
[registries.crates-io]
protocol = "sparse"
[net]
git-fetch-with-cli = true
EOF
)
  fi
  append_managed_block "$cargo_conf" "$block"
}

configure_go() {
  if ! go_cmd=$(find_real_binary go 2>/dev/null); then
    return 0
  fi
  if ! "$go_cmd" version >/dev/null 2>&1; then
    if [ "$ENFORCEMENT_MODE" = "hard" ]; then
      log_error "Detected go binary is not operable: $go_cmd"
      return 1
    fi
    log_warn "Detected go binary is not operable in current environment; skipping go env hardening"
    return 0
  fi

  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    require_hard_value GO_PROXY_URL "$GO_PROXY_URL"
    "$go_cmd" env -w "GOPROXY=$GO_PROXY_URL"
  else
    "$go_cmd" env -w "GOPROXY=https://proxy.golang.org,direct"
  fi
  "$go_cmd" env -w "GOSUMDB=${GO_SUMDB:-sum.golang.org}"
  "$go_cmd" env -w "GOPRIVATE=${GO_PRIVATE_PATTERNS:-}"
  "$go_cmd" env -w "GONOSUMDB=${GO_NO_SUMDB_PATTERNS:-}"
  "$go_cmd" env -w "GOVCS=${GO_VCS_RULES:-public:off,private:git|ssh}"
}

record_detected_binaries() {
  : >"$BINMAP_FILE"
  for tool in $MANAGED_COMMANDS; do
    if real_bin=$(resolve_real_binary "$tool" 2>/dev/null); then
      upper=$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')
      printf 'REAL_BIN_%s="%s"\n' "$upper" "$real_bin" >>"$BINMAP_FILE"
    fi
  done
}

create_shims() {
  for tool in $MANAGED_COMMANDS; do
    if grep -q "REAL_BIN_$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')=" "$BINMAP_FILE"; then
      cat >"$SHIM_ROOT/$tool" <<EOF
#!/bin/sh
exec "$WRAPPER_BIN" "$tool" "\$@"
EOF
      chmod 755 "$SHIM_ROOT/$tool"
    else
      rm -f "$SHIM_ROOT/$tool"
    fi
  done
}

verify_mode_prereqs() {
  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    require_hard_value NPM_REGISTRY_URL "$NPM_REGISTRY_URL" || return 1
    require_hard_value PYTHON_INDEX_URL "$PYTHON_INDEX_URL" || return 1
    require_hard_value CARGO_REGISTRY_URL "$CARGO_REGISTRY_URL" || return 1
    require_hard_value GO_PROXY_URL "$GO_PROXY_URL" || return 1
  fi
  return 0
}

apply_cmd() {
  parse_scope_flag "$@"
  ENFORCEMENT_MODE=${MODE:-${DEFAULT_MODE:-soft}}
  if [ "${SCOPE:-user}" = "machine" ]; then
    apply_machine_cmd
  else
    apply_user_cmd
  fi
}

apply_user_cmd() {
  log_init "apply"
  log_info "Applying policy mode: $ENFORCEMENT_MODE (scope: user)"
  log_json_event "INFO" "apply.started" "install.sh" "apply" "started" "$ENFORCEMENT_MODE"
  ensure_dirs
  verify_mode_prereqs
  install_runtime
  save_runtime_state "$ENFORCEMENT_MODE"
  record_detected_binaries
  create_shims
  apply_posix_profiles
  if platform_supports_windows_helper; then
    call_windows_helper Apply || true
  fi
  configure_npm
  configure_bun
  configure_pip
  configure_cargo
  configure_go
  rotate_logs
  save_status "applied"
  log_info "Policy applied. Restart the shell to pick up PATH changes."
  log_json_event "INFO" "apply.completed" "install.sh" "apply" "success" "policy applied"
}

apply_machine_cmd() {
  require_root
  setup_system_paths
  log_init "apply"
  log_info "Applying policy mode: $ENFORCEMENT_MODE (scope: machine)"
  log_json_event "INFO" "apply.started" "install.sh" "apply-machine" "started" "$ENFORCEMENT_MODE"
  ensure_dirs
  chmod 750 "$LOG_ROOT"
  verify_mode_prereqs
  install_runtime
  save_runtime_state "$ENFORCEMENT_MODE"
  record_detected_binaries
  create_shims
  write_profile_snippet
  apply_system_profiles
  # configure_go writes to the current user's GOENV; in machine scope this covers root.
  # Non-fatal: failure is logged but does not abort the rest of the apply.
  configure_go || log_warn "configure_go failed in machine scope; skipping go env hardening"
  # Apply package-manager configs to root
  apply_user_configs_for_home "/root" "/root/.config" || \
    log_warn "Failed to configure root user"
  # Apply to all local users
  list_local_users | while IFS=: read -r _user user_home; do
    [ -d "$user_home" ] || continue
    log_info "Configuring user: $_user ($user_home)"
    apply_user_configs_for_home "$user_home" "$user_home/.config" || \
      log_warn "Failed to configure user: $_user"
  done
  rotate_logs
  save_status "applied"
  log_info "Machine-scope policy applied. Open a new shell (or run 'hash -r') to pick up PATH changes."
  log_json_event "INFO" "apply.completed" "install.sh" "apply-machine" "success" "machine scope"
}

current_go_value() {
  key=$1
  if ! go_cmd=$(find_real_binary go 2>/dev/null); then
    return 1
  fi
  if ! "$go_cmd" version >/dev/null 2>&1; then
    return 1
  fi
  "$go_cmd" env "$key" 2>/dev/null | tr -d '\r'
}

contains_marker() {
  file=$1
  [ -f "$file" ] && grep -F "$MARKER_BEGIN" "$file" >/dev/null 2>&1
}

audit_user_cmd() {
  log_init "audit"
  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  failures=0
  log_info "Auditing local hardening state in mode: $ENFORCEMENT_MODE"
  log_json_event "INFO" "audit.started" "install.sh" "audit" "started" "$ENFORCEMENT_MODE"

  for file in "$COMMON_RUNTIME" "$WRAPPER_BIN" "$BINMAP_FILE" "$RUNSTATE_FILE" "$PROFILE_SNIPPET"; do
    if [ ! -f "$file" ]; then
      log_error "Missing required runtime file: $file"
      failures=$((failures + 1))
    fi
  done

  for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    if ! contains_marker "$profile"; then
      log_warn "Managed profile block missing from $profile"
    fi
  done

  if ! contains_marker "$HOME/.npmrc"; then
    log_error "Managed block missing from ~/.npmrc"
    failures=$((failures + 1))
  fi
  if ! contains_marker "$HOME/.bunfig.toml"; then
    log_error "Managed block missing from ~/.bunfig.toml"
    failures=$((failures + 1))
  fi
  if ! contains_marker "$CONFIG_ROOT/pip/pip.conf"; then
    log_error "Managed block missing from pip.conf"
    failures=$((failures + 1))
  fi
  if ! contains_marker "$HOME/.cargo/config.toml"; then
    log_error "Managed block missing from cargo config"
    failures=$((failures + 1))
  fi

  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    verify_mode_prereqs || failures=$((failures + 1))
    if [ "$(current_go_value GOPROXY || true)" != "$GO_PROXY_URL" ]; then
      log_error "GOPROXY drift detected"
      failures=$((failures + 1))
    fi
  fi

  for tool in $MANAGED_COMMANDS; do
    shim="$SHIM_ROOT/$tool"
    if grep -q "REAL_BIN_$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')=" "$BINMAP_FILE" 2>/dev/null; then
      if [ ! -x "$shim" ]; then
        log_error "Missing shim for detected tool: $tool"
        failures=$((failures + 1))
      fi
    fi
  done

  if [ ! -f "$AGGREGATE_LOG" ]; then
    log_error "Aggregate JSONL log missing"
    failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    save_status "non-compliant"
    log_error "Audit failed with $failures issue(s)"
    log_json_event "ERROR" "audit.completed" "install.sh" "audit" "failure" "$failures issues"
    exit 1
  fi

  save_status "compliant"
  log_info "Audit passed"
  log_json_event "INFO" "audit.completed" "install.sh" "audit" "success" "compliant"
}

audit_machine_cmd() {
  require_root
  setup_system_paths
  log_init "audit"
  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  failures=0
  log_info "Auditing machine-scope hardening state in mode: $ENFORCEMENT_MODE"
  log_json_event "INFO" "audit.started" "install.sh" "audit-machine" "started" "$ENFORCEMENT_MODE"

  for file in "$COMMON_RUNTIME" "$WRAPPER_BIN" "$BINMAP_FILE" "$RUNSTATE_FILE" "$PROFILE_SNIPPET"; do
    if [ ! -f "$file" ]; then
      log_error "Missing required runtime file: $file"
      failures=$((failures + 1))
    fi
  done

  if [ ! -f /etc/profile.d/supply-gate.sh ]; then
    log_error "Missing system-wide profile: /etc/profile.d/supply-gate.sh"
    failures=$((failures + 1))
  fi

  for tool in $MANAGED_COMMANDS; do
    shim="$SHIM_ROOT/$tool"
    if grep -q "REAL_BIN_$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')=" "$BINMAP_FILE" 2>/dev/null; then
      if [ ! -x "$shim" ]; then
        log_error "Missing shim for detected tool: $tool"
        failures=$((failures + 1))
      fi
    fi
  done

  if [ ! -f "$AGGREGATE_LOG" ]; then
    log_error "Aggregate JSONL log missing"
    failures=$((failures + 1))
  fi

  audit_user_pkg_configs() {
    username=$1; home_dir=$2; config_dir=$3
    ok=1
    contains_marker "$home_dir/.npmrc"        || { log_warn "npmrc missing managed block: $username"; ok=0; }
    contains_marker "$home_dir/.bunfig.toml"  || { log_warn "bunfig missing managed block: $username"; ok=0; }
    contains_marker "$config_dir/pip/pip.conf" || { log_warn "pip.conf missing managed block: $username"; ok=0; }
    contains_marker "$home_dir/.cargo/config.toml" || { log_warn "cargo config missing managed block: $username"; ok=0; }
    return $ok
  }

  audit_user_pkg_configs "root" "/root" "/root/.config" || failures=$((failures + 1))
  list_local_users | while IFS=: read -r username user_home; do
    [ -d "$user_home" ] || continue
    audit_user_pkg_configs "$username" "$user_home" "$user_home/.config" || true
  done

  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    verify_mode_prereqs || failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    save_status "non-compliant"
    log_error "Audit failed with $failures issue(s)"
    log_json_event "ERROR" "audit.completed" "install.sh" "audit-machine" "failure" "$failures issues"
    exit 1
  fi

  save_status "compliant"
  log_info "Machine-scope audit passed"
  log_json_event "INFO" "audit.completed" "install.sh" "audit-machine" "success" "compliant"
}

audit_cmd() {
  parse_scope_flag "$@"
  if [ "${SCOPE:-user}" = "machine" ]; then
    audit_machine_cmd
  else
    audit_user_cmd
  fi
}

repair_cmd() {
  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  apply_cmd --mode "$ENFORCEMENT_MODE"
}

uninstall_cmd() {
  parse_scope_flag "$@"
  # When no explicit --scope is given and we are root, default uninstall to machine
  # scope so the system-wide layer (/etc/profile.d, system rc files, /opt state) is
  # fully removed. A non-root invocation keeps user scope (machine requires root).
  if [ -z "$SCOPE" ] && [ "$(id -u)" = "0" ]; then
    SCOPE=machine
    log_info "No --scope given and running as root; defaulting uninstall to machine scope"
  fi
  if [ "${SCOPE:-user}" = "machine" ]; then
    uninstall_machine_cmd
  else
    uninstall_user_cmd
  fi
}

uninstall_user_cmd() {
  log_init "uninstall"
  log_info "Removing managed shell blocks and local state"
  remove_managed_block "$HOME/.profile"
  remove_managed_block "$HOME/.bashrc"
  remove_managed_block "$HOME/.zshrc"
  remove_managed_block "$HOME/.npmrc"
  remove_managed_block "$HOME/.bunfig.toml"
  remove_managed_block "$CONFIG_ROOT/pip/pip.conf"
  remove_managed_block "$HOME/.cargo/config.toml"
  if platform_supports_windows_helper; then
    call_windows_helper Remove || true
  fi
  rm -rf "$STATE_ROOT"
  log_info "Uninstall complete"
}

uninstall_machine_cmd() {
  require_root
  setup_system_paths
  log_init "uninstall"
  log_info "Removing machine-scope managed blocks and system state"
  log_json_event "INFO" "uninstall.started" "install.sh" "uninstall-machine" "started" "machine scope"
  remove_system_profiles
  # Remove from root
  remove_user_configs_for_home "/root" "/root/.config"
  # Remove from all local users
  list_local_users | while IFS=: read -r _user user_home; do
    [ -d "$user_home" ] || continue
    log_info "Removing from user: $_user ($user_home)"
    remove_user_configs_for_home "$user_home" "$user_home/.config"
  done
  rm -rf "$STATE_ROOT"
  log_info "Machine-scope uninstall complete"
  log_json_event "INFO" "uninstall.completed" "install.sh" "uninstall-machine" "success" "machine scope"
}

status_cmd() {
  configured=0
  status_system
  # The system-wide profile layer covers every user's PATH; when present, users
  # without per-user package configs are still covered rather than unconfigured.
  system_active=""
  [ -f /etc/profile.d/supply-gate.sh ] && system_active=1
  printf '\nUsers:\n'
  # Root
  root_count=0
  for f in /root/.profile /root/.bashrc /root/.zshrc /root/.npmrc /root/.bunfig.toml \
            /root/.config/pip/pip.conf /root/.cargo/config.toml; do
    [ -f "$f" ] && grep -qF "$MARKER_BEGIN" "$f" && root_count=$((root_count + 1))
  done
  if [ "$root_count" -gt 0 ]; then
    configured=$((configured + 1))
  fi
  status_user "root" "/root" "/root/.config" "$system_active"
  # Local users
  list_local_users | while IFS=: read -r username user_home; do
    status_user "$username" "$user_home" "$user_home/.config" "$system_active"
  done
  if [ "$configured" -gt 0 ] || [ -n "$system_active" ]; then
    return 0
  fi
  return 1
}

# Guard: skip dispatch when sourced by tests (_SCP_SOURCED=1).
[ "${_SCP_SOURCED:-}" = "1" ] && return 0

case "$SUBCOMMAND" in
  apply) apply_cmd "$@" ;;
  audit) audit_cmd ;;
  repair) repair_cmd ;;
  status) status_cmd ;;
  install-optional-tools) install_optional_tools_cmd "$@" ;;
  uninstall) uninstall_cmd "$@" ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    usage
    exit 2
    ;;
esac
