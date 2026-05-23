#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

SUBCOMMAND=${1:-}
shift || true

MODE=""

usage() {
  cat <<EOF
Usage:
  ./install.sh apply [--mode soft|hard]
  ./install.sh audit
  ./install.sh repair
  ./install.sh install-optional-tools [--scfw] [--bumblebee] [--all]
  ./install.sh uninstall
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
$( [ "$ENFORCEMENT_MODE" = "hard" ] && printf 'registry=%s\n' "$NPM_REGISTRY_URL" )
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
$( [ "$ENFORCEMENT_MODE" = "hard" ] && printf 'index-url = %s\n' "$PYTHON_INDEX_URL" )
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
  parse_mode_flag "$@"
  ENFORCEMENT_MODE=${MODE:-${DEFAULT_MODE:-soft}}
  log_init "apply"
  log_info "Applying policy mode: $ENFORCEMENT_MODE"
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

audit_cmd() {
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

repair_cmd() {
  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  apply_cmd --mode "$ENFORCEMENT_MODE"
}

uninstall_cmd() {
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

case "$SUBCOMMAND" in
  apply) apply_cmd "$@" ;;
  audit) audit_cmd ;;
  repair) repair_cmd ;;
  install-optional-tools) install_optional_tools_cmd "$@" ;;
  uninstall) uninstall_cmd ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    usage
    exit 2
    ;;
esac
