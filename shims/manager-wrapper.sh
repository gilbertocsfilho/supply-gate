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

real_var=$(printf 'REAL_BIN_%s' "$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')")
# shellcheck disable=SC2086
eval "real_bin=\${$real_var:-}"

if [ -z "${real_bin:-}" ] || [ ! -x "$real_bin" ]; then
  log_error "Real binary not mapped for $tool"
  log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "missing real binary"
  exit 1
fi

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
  if [ "$PLATFORM" = "windows" ]; then
    backend=${AI_JAIL_BACKEND_WINDOWS:-}
    launcher=${AI_JAIL_LAUNCHER_WINDOWS:-}
  else
    backend=${AI_JAIL_BACKEND_MACLINUX:-}
    launcher=${AI_JAIL_LAUNCHER_MACLINUX:-}
  fi

  if [ -z "$launcher" ] || [ ! -x "$launcher" ]; then
    log_error "AI jail launcher missing for $tool on $PLATFORM"
    log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "missing ai jail launcher"
    exit 1
  fi

  log_info "Launching $tool through jail backend: $backend"
  log_json_event "INFO" "command.jailed" "$tool" "$command_text" "started" "$backend"
  "$launcher" "$real_bin" "$@"
}

run_package_manager() {
  case "$tool" in
    go)
      if [ "$mode" = "hard" ]; then
        export GOPROXY=${GO_PROXY_URL:-}
      else
        export GOPROXY=${GO_PROXY_URL:-https://proxy.golang.org,direct}
      fi
      export GOSUMDB=${GO_SUMDB:-sum.golang.org}
      export GOPRIVATE=${GO_PRIVATE_PATTERNS:-}
      export GONOSUMDB=${GO_NO_SUMDB_PATTERNS:-}
      export GOVCS=${GO_VCS_RULES:-}
      ;;
    pip|uv|poetry)
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

  log_info "Delegating to real binary: $real_bin"
  log_json_event "INFO" "command.allowed" "$tool" "$command_text" "started" "delegating to real binary"
  "$real_bin" "$@"
}

if is_ai_tool "$tool"; then
  if run_ai_tool "$@"; then
    log_info "Command succeeded: $command_text"
    log_json_event "INFO" "command.completed" "$tool" "$command_text" "success" "jailed"
    exit 0
  fi
  rc=$?
  log_error "Command failed: $command_text (exit $rc)"
  log_json_event "ERROR" "command.completed" "$tool" "$command_text" "failure" "jailed exit $rc"
  exit $rc
fi

if is_package_manager "$tool"; then
  if run_package_manager "$@"; then
    log_info "Command succeeded: $command_text"
    log_json_event "INFO" "command.completed" "$tool" "$command_text" "success" "package manager"
    exit 0
  fi
  rc=$?
  log_error "Command failed: $command_text (exit $rc)"
  log_json_event "ERROR" "command.completed" "$tool" "$command_text" "failure" "package manager exit $rc"
  exit $rc
fi

log_error "Tool not managed by wrapper: $tool"
log_json_event "ERROR" "command.blocked" "$tool" "$command_text" "blocked" "unknown tool"
exit 1
