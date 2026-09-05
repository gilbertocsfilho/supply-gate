#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

load_runtime_state
tool=${1:-}
shift || true

if [ -z "$tool" ]; then
  echo "Usage: manager-wrapper.sh <tool> [args...]" >&2
  exit 2
fi

log_init "exec-$tool"
command_text="$tool${*:+ }$*"
log_info "Intercepted command: $command_text"
log_json_event "INFO" "command.intercepted" "$tool" "$command_text" "started" "wrapper invoked"

# Resolved live via PATH on every invocation (not a value cached at apply
# time) so a tool installed after the last `install.sh apply` is picked up
# immediately, with no reapply needed. resolve_real_binary/find_real_binary
# (lib/common.sh) already skip over our own shims by content, so this can't
# resolve back to itself even with multiple shim dirs on PATH.
if ! real_bin=$(resolve_real_binary "$tool" 2>/dev/null); then
  log_error "Real binary not found on PATH for $tool"
  log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "no real binary found on PATH"
  exit 1
fi

case "$tool" in
  pip|pip3)
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "$VIRTUAL_ENV/bin/$tool" ]; then
      real_bin="$VIRTUAL_ENV/bin/$tool"
    fi
    ;;
esac

mode=$(current_mode)
ENFORCEMENT_MODE=$mode

case "$mode" in
  soft|hard) ;;
  *)
    log_error "Unsupported enforcement mode: $mode"
    log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "invalid mode"
    exit 1
    ;;
esac

if [ "$mode" = "hard" ]; then
  require_hard_value NPM_REGISTRY_URL "$NPM_REGISTRY_URL" || exit 1
  require_hard_value PYTHON_INDEX_URL "$PYTHON_INDEX_URL" || exit 1
  require_hard_value CARGO_REGISTRY_URL "$CARGO_REGISTRY_URL" || exit 1
  require_hard_value GO_PROXY_URL "$GO_PROXY_URL" || exit 1
fi

run_ai_tool() {
  # Emergency kill switch. Sets aside every other AI-jail decision below: an
  # operator facing a broken/misconfigured jail (blocking legitimate AI tool
  # use fleet-wide) can force an unjailed run without editing policy or
  # reapplying. Always honored, in both soft and hard mode, and logged as its
  # own event so the bypass shows up in the audit trail. See GUIDE.md "AI Jail"
  # section for how to set this for a single shell vs machine-wide.
  if [ "${SCP_AI_JAIL_BYPASS:-0}" = "1" ]; then
    log_warn "AI jail bypass forced via SCP_AI_JAIL_BYPASS=1; running $tool unjailed"
    log_json_event "WARN" "command.allowed" "$tool" "$command_text" "started" "ai jail bypass forced"
    "$real_bin" "$@"
    return
  fi

  # Re-entrancy guard. If we are already running inside an AI jail, do NOT jail
  # again -- run the real binary directly. This fires in two cases:
  #   1. Our own launcher below re-invokes the shim (it exports SCP_IN_AIJAIL=1),
  #      so `claude` -> shim -> launcher -> jailed `claude` -> shim would
  #      otherwise recurse forever.
  #   2. A user who launches the jail themselves (e.g. `ai-jail claude`) exports
  #      SCP_IN_AIJAIL=1 to tell the inner shim it is already contained.
  # Mirrors the SCP_IN_SCFW guard in run_package_manager. Without it, the shim
  # intercepted inside ai-jail tried to jail a second time and failed with
  # "AI jail launcher missing".
  if [ "${SCP_IN_AIJAIL:-0}" = "1" ]; then
    log_info "Already inside AI jail; delegating to real binary: $real_bin"
    log_json_event "INFO" "command.allowed" "$tool" "$command_text" "started" "already jailed"
    "$real_bin" "$@"
    return
  fi

  # Backend/launcher are per-OS, not shared between macOS and Linux: sandbox
  # tooling (bwrap vs sandbox-exec vs WSL) and install paths differ enough
  # that one machine's config should never silently apply to another OS.
  case "$PLATFORM" in
    windows)
      backend=${AI_JAIL_BACKEND_WINDOWS:-}
      launcher=${AI_JAIL_LAUNCHER_WINDOWS:-}
      ;;
    macos)
      backend=${AI_JAIL_BACKEND_MACOS:-}
      launcher=${AI_JAIL_LAUNCHER_MACOS:-}
      ;;
    *)
      backend=${AI_JAIL_BACKEND_LINUX:-}
      launcher=${AI_JAIL_LAUNCHER_LINUX:-}
      ;;
  esac

  if [ -z "$launcher" ] || [ ! -x "$launcher" ]; then
    # Fail-closed in hard mode (matches require_hard_value elsewhere: hard
    # mode must not silently run unjailed). Fail-open in soft mode: soft is
    # advisory everywhere else in this wrapper, so an unconfigured/broken jail
    # here warns and lets the command through instead of hard-blocking every
    # AI tool invocation on the host.
    if [ "$mode" = "hard" ]; then
      log_error "AI jail launcher missing for $tool on $PLATFORM (hard mode blocks)"
      log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "missing ai jail launcher"
      exit 1
    fi
    log_warn "AI jail launcher missing for $tool on $PLATFORM; running unjailed (soft mode)"
    log_json_event "WARN" "command.allowed" "$tool" "$command_text" "started" "ai jail unavailable, unjailed in soft mode"
    "$real_bin" "$@"
    return
  fi

  log_info "Launching $tool through jail backend: $backend"
  log_json_event "INFO" "command.jailed" "$tool" "$command_text" "started" "$backend"
  # Mark the child so the shim it re-invokes (jailed `claude` -> our shim again)
  # takes the guard branch above instead of recursing into another jail.
  SCP_IN_AIJAIL=1 "$launcher" "$real_bin" "$@"
}

run_package_manager() {
  case "$tool" in
    go)
      if [ "$mode" = "hard" ]; then
        export GOPROXY=${GO_PROXY_URL:-}
        export GOSUMDB=${GO_SUMDB:-sum.golang.org}
        export GOPRIVATE=${GO_PRIVATE_PATTERNS:-}
        export GONOSUMDB=${GO_NO_SUMDB_PATTERNS:-}
        export GOVCS=${GO_VCS_RULES:-}
      fi
      ;;
    pip|pip3|uv|poetry)
      if [ -n "${PYTHON_INDEX_URL:-}" ] && [ "$mode" = "hard" ]; then
        export PIP_INDEX_URL=$PYTHON_INDEX_URL
      fi
      ;;
    npm|pnpm|yarn|bun)
      if [ "$mode" = "hard" ]; then
        export NPM_CONFIG_REGISTRY=$NPM_REGISTRY_URL
        export npm_config_registry=$NPM_REGISTRY_URL
      fi
      ;;
  esac

  should_run_via_scfw() {
    first_arg=${1:-}

    [ "${SCFW_AUTO_WRAP:-1}" = "1" ] || return 1
    [ "${SCP_IN_SCFW:-0}" != "1" ] || return 1
    command -v scfw >/dev/null 2>&1 || return 1

    case " ${SCFW_MANAGED_TOOLS:-} " in
      *" $tool "*) ;;
      *) return 1 ;;
    esac

    case "$tool" in
      npm)
        case "$first_arg" in
          install|i|update|up) return 0 ;;
        esac
        ;;
      pip|pip3)
        case "$first_arg" in
          install) return 0 ;;
        esac
        ;;
      poetry)
        case "$first_arg" in
          add|install|update) return 0 ;;
        esac
        ;;
    esac

    return 1
  }

  run_via_scfw() {
    log_info "Delegating through scfw with real binary: $real_bin"
    log_json_event "INFO" "command.allowed" "$tool" "$command_text" "started" "delegating through scfw"
    SCP_IN_SCFW=1 scfw run --executable "$real_bin" "$tool" "$@"
  }

  if should_run_via_scfw "$@"; then
    # `return 0` here would have thrown away scfw's verdict: a package it
    # refused would still look like a successful install to the caller.
    run_via_scfw "$@"
    return $?
  fi

  log_info "Delegating to real binary: $real_bin"
  log_json_event "INFO" "command.allowed" "$tool" "$command_text" "started" "delegating to real binary"
  "$real_bin" "$@"
}

# `rc=$?` AFTER a closing `fi` reads the status of the `if` statement itself,
# which is 0 whenever the condition was false and there is no else branch --
# not the status of the condition. Written that way, every failing wrapped
# command (a 404 from the registry, a refused install, a jailed tool that
# exited non-zero) was logged as "failure" and then handed back to the caller
# as exit 0, so scripts and CI treated a failed install as a successful one.
# Capture it in the else branch, where $? is still the condition's status.
if is_ai_tool "$tool"; then
  if run_ai_tool "$@"; then
    log_info "Command succeeded: $command_text"
    log_json_event "INFO" "command.completed" "$tool" "$command_text" "success" "jailed"
    exit 0
  else
    rc=$?
    log_error "Command failed: $command_text (exit $rc)"
    log_json_event "ERROR" "command.completed" "$tool" "$command_text" "failure" "jailed exit $rc"
    exit "$rc"
  fi
fi

if is_package_manager "$tool"; then
  if run_package_manager "$@"; then
    log_info "Command succeeded: $command_text"
    log_json_event "INFO" "command.completed" "$tool" "$command_text" "success" "package manager"
    exit 0
  else
    rc=$?
    log_error "Command failed: $command_text (exit $rc)"
    log_json_event "ERROR" "command.completed" "$tool" "$command_text" "failure" "package manager exit $rc"
    exit "$rc"
  fi
fi

log_error "Tool not managed by wrapper: $tool"
log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "unknown tool"
exit 1
