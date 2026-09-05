#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/checks.sh"

SUBCOMMAND=${1:-}
shift || true

MODE=""
SCOPE=""

usage() {
  cat <<EOF
Usage:
  ./install.sh apply [--mode soft|hard] [--scope user|machine]
  ./install.sh audit [--scope user|machine]
  ./install.sh repair [--scope user|machine]
  ./install.sh status [--scope user|machine] [--full]
  ./install.sh install-optional-tools [--scfw] [--bumblebee] [--all]
  ./install.sh uninstall [--scope user|machine|all]

  status          read-only integrity report. Exit 0 = healthy, 1 = degraded
                  (run 'repair'), 2 = manual action required. --full lists
                  every individual check instead of a per-section summary.

  --scope user    (default) apply only to the current user
  --scope machine apply to all local users and system-wide profile layer
                  requires root; used for KACE or similar deployment tools
  --scope all     uninstall only: alias for machine scope. Removes the
                  system-wide layer plus every local user's config (root's
                  and all others), on Linux and macOS alike. Requires root.
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
          user|machine|all) ;;
          *)
            echo "Unknown scope: $SCOPE (use 'user', 'machine', or 'all')" >&2
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
    echo "ERROR: this scope requires root privileges (use sudo)" >&2
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
  # <tool>-nojail: a memorable everyday way to run a single AI tool invocation
  # unjailed, without having to remember/type SCP_AI_JAIL_BYPASS=1 by hand
  # each time. Sets the bypass only for that one command -- not the whole
  # shell -- and still goes through the shim (via `command`, in case the user
  # has their own alias for the tool), so it's still logged like every other
  # invocation. Real bypass mechanism lives in run_ai_tool
  # (shims/manager-wrapper.sh); this is just a convenience wrapper around it.
  for tool in $AI_COMMANDS; do
    cat >>"$PROFILE_SNIPPET" <<EOF
$tool-nojail() { SCP_AI_JAIL_BYPASS=1 command $tool "\$@"; }
EOF
  done
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
  # Stale artifact from older installs: the wrapper resolves real binaries live
  # now (see create_shims/manager-wrapper.sh) instead of from this cached map.
  rm -f "$RUNTIME_ROOT/binmap.conf"
  # Optional ai-jail launcher adapter. Installed to a stable path so a local
  # policy can point AI_JAIL_LAUNCHER_LINUX/AI_JAIL_LAUNCHER_MACOS at it;
  # harmless if ai-jail is not used.
  if [ -f "$SCRIPT_DIR/scripts/ai-jail-launcher.sh" ]; then
    cp "$SCRIPT_DIR/scripts/ai-jail-launcher.sh" "$RUNTIME_ROOT/ai-jail-launcher.sh"
    chmod 755 "$RUNTIME_ROOT/ai-jail-launcher.sh"
  fi
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

# Shims are created unconditionally for every managed command, whether or not
# the real binary is currently found on PATH: the wrapper resolves the real
# binary live on each invocation (see manager-wrapper.sh), so a tool installed
# after this apply is intercepted immediately without a reapply.
create_shims() {
  for tool in $MANAGED_COMMANDS; do
    cat >"$SHIM_ROOT/$tool" <<EOF
#!/bin/sh
exec "$WRAPPER_BIN" "$tool" "\$@"
EOF
    chmod 755 "$SHIM_ROOT/$tool"
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

# Preflight, informational only: never fails apply in either mode (unlike
# verify_mode_prereqs) so an install without ai-jail keeps working exactly as
# before. Its only job is to surface -- at apply time, not at the first
# confusing runtime error -- what will actually happen when someone runs
# claude/gemini/codex: jailed, blocked (hard mode, no launcher), or unjailed
# with a warning (soft mode, no launcher). Mirrors the fail-open/fail-closed
# split in run_ai_tool (shims/manager-wrapper.sh).
verify_ai_jail_status() {
  [ -n "$AI_COMMANDS" ] || return 0

  case "$PLATFORM" in
    windows) launcher=${AI_JAIL_LAUNCHER_WINDOWS:-} ;;
    macos)   launcher=${AI_JAIL_LAUNCHER_MACOS:-} ;;
    *)       launcher=${AI_JAIL_LAUNCHER_LINUX:-} ;;
  esac

  if [ -n "$launcher" ] && [ -x "$launcher" ]; then
    log_info "AI jail configured for $PLATFORM: $launcher (covers: $AI_COMMANDS)"
    return 0
  fi

  if command -v ai-jail >/dev/null 2>&1; then
    log_warn "ai-jail is installed but no launcher is configured for $PLATFORM (AI_JAIL_LAUNCHER_$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]') is empty in policy)"
  else
    log_warn "ai-jail is not installed/on PATH for $PLATFORM"
  fi

  if [ "$ENFORCEMENT_MODE" = "hard" ]; then
    log_warn "Hard mode: $AI_COMMANDS will be BLOCKED at runtime until a launcher is configured (see policy/local-policy.example.conf)"
  else
    log_warn "Soft mode: $AI_COMMANDS will run UNJAILED until a launcher is configured (see policy/local-policy.example.conf)"
  fi
  return 0
}

apply_cmd() {
  parse_scope_flag "$@"
  ENFORCEMENT_MODE=${MODE:-${DEFAULT_MODE:-soft}}
  if [ "${SCOPE:-user}" = "all" ]; then
    echo "ERROR: --scope all is only supported by 'uninstall'" >&2
    exit 2
  fi
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
  verify_ai_jail_status
  install_runtime
  save_runtime_state "$ENFORCEMENT_MODE"
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
  # World-writable + sticky, like /tmp: any local user's wrapper invocation
  # (it runs as themselves, not root) can create its own per-run log file and
  # append to the shared aggregate log -- no dedicated OS group needed. This
  # used to be a setgid root:supply-gate group instead; that group's creation
  # (groupadd/dseditgroup) could fail for reasons unrelated to enforcement
  # itself (GID collision, hardened box, AD/LDAP-backed group database), and
  # because that call ran bare under `set -eu` before install_runtime/
  # create_shims ever ran, a failure there silently aborted the ENTIRE apply
  # -- leaving the machine-scope root completely absent while a wrapping
  # installer (e.g. the .deb postinst) still reported success. Sticky bit
  # stops one user from deleting/renaming another's log file; the aggregate
  # JSONL log is append-only in practice so concurrent writers don't collide.
  chmod 1777 "$LOG_ROOT"
  touch "$AGGREGATE_LOG"
  chmod 666 "$AGGREGATE_LOG"
  verify_mode_prereqs
  verify_ai_jail_status
  install_runtime
  save_runtime_state "$ENFORCEMENT_MODE"
  create_shims
  write_profile_snippet
  apply_system_profiles
  # configure_go writes to the current user's GOENV; in machine scope this covers root.
  # Non-fatal: failure is logged but does not abort the rest of the apply.
  configure_go || log_warn "configure_go failed in machine scope; skipping go env hardening"
  # Apply package-manager configs to the root account. root's home differs by
  # platform (/var/root on macOS, /root elsewhere), so resolve it per platform
  # and skip when it doesn't exist -- otherwise macOS, which has no /root, spews
  # "mkdir: /root: Read-only file system" noise on every apply.
  case "$PLATFORM" in
    macos) root_home="/var/root" ;;
    *)     root_home="/root" ;;
  esac
  if [ -d "$root_home" ]; then
    apply_user_configs_for_home "$root_home" "$root_home/.config" || \
      log_warn "Failed to configure root user"
  fi
  # Apply to all local users
  list_local_users | while IFS=: read -r _user user_home; do
    [ -d "$user_home" ] || continue
    log_info "Configuring user: $_user ($user_home)"
    apply_user_configs_for_home "$user_home" "$user_home/.config" || \
      log_warn "Failed to configure user: $_user"
  done
  rotate_logs
  save_status "applied"
  log_info "Machine-scope policy applied. Users must start a new shell/login session to pick up PATH changes."
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

  for file in "$COMMON_RUNTIME" "$WRAPPER_BIN" "$RUNSTATE_FILE" "$PROFILE_SNIPPET"; do
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
    if [ ! -x "$shim" ]; then
      log_error "Missing shim for: $tool"
      failures=$((failures + 1))
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

  for file in "$COMMON_RUNTIME" "$WRAPPER_BIN" "$RUNSTATE_FILE" "$PROFILE_SNIPPET"; do
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
    if [ ! -x "$shim" ]; then
      log_error "Missing shim for: $tool"
      failures=$((failures + 1))
    fi
  done

  if [ ! -f "$AGGREGATE_LOG" ]; then
    log_error "Aggregate JSONL log missing"
    failures=$((failures + 1))
  fi

  audit_user_pkg_configs() {
    username=$1; home_dir=$2; config_dir=$3
    # missing=0 means all managed blocks present. Return 0 (shell success) in
    # that case and 1 when anything is missing -- callers use `|| failures=...`,
    # so the return code must follow shell convention, not a truthy flag.
    missing=0
    contains_marker "$home_dir/.npmrc"        || { log_warn "npmrc missing managed block: $username"; missing=1; }
    contains_marker "$home_dir/.bunfig.toml"  || { log_warn "bunfig missing managed block: $username"; missing=1; }
    contains_marker "$config_dir/pip/pip.conf" || { log_warn "pip.conf missing managed block: $username"; missing=1; }
    contains_marker "$home_dir/.cargo/config.toml" || { log_warn "cargo config missing managed block: $username"; missing=1; }
    return $missing
  }

  # Match apply_machine_cmd: root's home is /var/root on macOS, /root elsewhere.
  case "$PLATFORM" in
    macos) root_home="/var/root" ;;
    *)     root_home="/root" ;;
  esac
  audit_user_pkg_configs "root" "$root_home" "$root_home/.config" || failures=$((failures + 1))
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
  if [ "${SCOPE:-user}" = "all" ]; then
    echo "ERROR: --scope all is only supported by 'uninstall'" >&2
    exit 2
  fi
  if [ "${SCOPE:-user}" = "machine" ]; then
    audit_machine_cmd
  else
    audit_user_cmd
  fi
}

repair_cmd() {
  parse_scope_flag "$@"
  # Scope resolution mirrors uninstall_cmd. Before this, repair_cmd took no
  # arguments at all (the dispatch called it bare, dropping "$@"), so
  # `repair --scope machine` silently did a USER-scope apply: it reported
  # "scope: user", exited 0, left the real machine install at /opt/supply-gate
  # untouched, and created a second user-scope install under root's home. An
  # exit 0 that repairs nothing is worse than a failure, so resolve the scope
  # from the flag first and otherwise infer it from what is actually installed.
  if [ -z "$SCOPE" ] && [ "$(id -u)" = "0" ] && [ -f /etc/profile.d/supply-gate.sh ]; then
    SCOPE=machine
    echo "No --scope given, running as root, and a machine-scope install was detected; repairing machine scope" >&2
  fi
  # setup_system_paths must run BEFORE load_runtime_state: the saved mode lives
  # in <STATE_ROOT>/runtime/state.conf, and without the override STATE_ROOT
  # still points at the invoking user's home, so the machine install's recorded
  # mode is never read and repair silently downgrades hard to the default.
  if [ "${SCOPE:-user}" = "machine" ]; then
    setup_system_paths
  fi
  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  apply_cmd --mode "$ENFORCEMENT_MODE" --scope "${SCOPE:-user}"
}

uninstall_cmd() {
  parse_scope_flag "$@"
  # When no explicit --scope is given and we are root, default uninstall to machine
  # scope so the system-wide layer (/etc/profile.d, system rc files, /opt state) is
  # fully removed. A non-root invocation keeps user scope (machine requires root).
  # Uses plain echo, not log_info: log_init (which defines RUN_LOG_TXT) hasn't run
  # yet at this point, and under set -eu referencing it early aborts the script
  # before anything is removed.
  if [ -z "$SCOPE" ] && [ "$(id -u)" = "0" ]; then
    SCOPE=machine
    echo "No --scope given and running as root; defaulting uninstall to machine scope" >&2
  fi
  case "${SCOPE:-user}" in
    machine|all)
      uninstall_machine_cmd
      ;;
    *)
      uninstall_user_cmd
      ;;
  esac
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
  detach_logging
  log_info "Uninstall complete"
}

uninstall_machine_cmd() {
  require_root
  setup_system_paths
  log_init "uninstall"
  log_info "Removing machine-scope managed blocks and system state"
  log_json_event "INFO" "uninstall.started" "install.sh" "uninstall-machine" "started" "machine scope"
  remove_system_profiles
  # Remove from root. Must resolve root's home the same way apply_machine_cmd
  # does -- macOS puts it at /var/root and has no /root at all, so hardcoding
  # /root here left root's managed blocks behind on every Mac while reporting
  # a clean uninstall.
  case "$PLATFORM" in
    macos) root_home="/var/root" ;;
    *)     root_home="/root" ;;
  esac
  if [ -d "$root_home" ]; then
    remove_user_configs_for_home "$root_home" "$root_home/.config" || \
      log_warn "Failed to fully remove config for root"
  fi
  # Remove from all local users. Each user's removal is guarded with
  # || log_warn: without it, a single failure (e.g. one unwritable file)
  # aborts the whole loop under set -e and silently skips every remaining
  # user, which is what made past runs look like they did nothing.
  list_local_users | while IFS=: read -r _user user_home; do
    [ -d "$user_home" ] || continue
    log_info "Removing from user: $_user ($user_home)"
    remove_user_configs_for_home "$user_home" "$user_home/.config" || \
      log_warn "Failed to fully remove config for user: $_user"
  done
  rm -rf "$STATE_ROOT"
  detach_logging
  log_info "Machine-scope uninstall complete"
  log_json_event "INFO" "uninstall.completed" "install.sh" "uninstall-machine" "success" "machine scope"
}

# Integrity checks live in lib/checks.sh (status_run). Exit codes changed with
# this: 0 used to mean "at least one location is configured" and 1 "nothing
# configured". Now 0 healthy, 1 degraded (repair fixes it), 2 manual action
# required or not installed -- a caller that treated 1 as "not installed" must
# look for 2.
status_cmd() {
  status_run "$@"
}

# Guard: skip dispatch when sourced by tests (_SCP_SOURCED=1).
[ "${_SCP_SOURCED:-}" = "1" ] && return 0

case "$SUBCOMMAND" in
  apply) apply_cmd "$@" ;;
  audit) audit_cmd "$@" ;;
  # "$@" is required: without it `repair --scope machine` silently ran a
  # user-scope apply. See repair_cmd.
  repair) repair_cmd "$@" ;;
  status) status_cmd "$@" ;;
  install-optional-tools) install_optional_tools_cmd "$@" ;;
  uninstall) uninstall_cmd "$@" ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    usage
    exit 2
    ;;
esac
