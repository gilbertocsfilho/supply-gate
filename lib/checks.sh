#!/bin/sh
# Integrity checks behind `install.sh status`.
#
# Read-only: never writes a dotfile, config, shim, state.conf or status.env.
# The only writes are the events.jsonl append every subcommand makes and a
# probe file under LOG_ROOT that is unlinked immediately.
#
# Exit codes: 0 healthy, 1 degraded (repair fixes it), 2 manual action needed.

CHECK_SEP=$(printf '\034')
CHECK_RESULTS=""
CHECK_OK=0
CHECK_WARN=0
CHECK_FAIL=0
CHECK_UNKNOWN=0
CHECK_SCOPE="user"
CHECK_SCOPE_EXPLICIT=0
CHECK_FULL=0

# check_record <id> <ok|warn|fail|unknown> <detail> [repair|manual|none]
check_record() {
  _c_id=$1
  _c_sev=$2
  _c_detail=$(printf '%s' "$3" | tr -d '\n\034' | tr '\t' ' ')
  _c_fix=${4:-none}
  CHECK_RESULTS="$CHECK_RESULTS$(printf '%s%s%s%s%s%s%s' \
    "$_c_id" "$CHECK_SEP" "$_c_sev" "$CHECK_SEP" "$_c_detail" "$CHECK_SEP" "$_c_fix")
"
  case "$_c_sev" in
    ok)      CHECK_OK=$((CHECK_OK + 1)) ;;
    warn)    CHECK_WARN=$((CHECK_WARN + 1)) ;;
    fail)    CHECK_FAIL=$((CHECK_FAIL + 1)) ;;
    unknown) CHECK_UNKNOWN=$((CHECK_UNKNOWN + 1)) ;;
  esac
  return 0
}

check_has_marker() {
  [ -f "$1" ] && grep -qF "$MARKER_BEGIN" "$1" 2>/dev/null
}

# Same patterns as require_hard_value, without its log/JSON side effects.
check_is_placeholder() {
  case "${1:-}" in
    ""|*example.corp*|*invalid*) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 1 when nothing is installed, so the caller skips the rest.
check_install() {
  if [ ! -d "$STATE_ROOT" ]; then
    check_record "install.state_root" "fail" \
      "$STATE_ROOT does not exist; not installed in this scope" "manual"
    return 1
  fi
  check_record "install.state_root" "ok" "$STATE_ROOT" "none"
  if [ -f "$RUNSTATE_FILE" ] && [ -n "${ENFORCEMENT_MODE:-}" ]; then
    check_record "install.mode" "ok" "$ENFORCEMENT_MODE (applied ${UPDATED_AT:-unknown})" "none"
  else
    check_record "install.mode" "fail" "state.conf missing or has no ENFORCEMENT_MODE" "repair"
  fi
  return 0
}

check_hash() {
  _h_id=$1
  _h_installed=$2
  _h_source=$3
  [ -f "$_h_installed" ] || return 0
  if [ ! -r "$_h_source" ]; then
    check_record "$_h_id" "unknown" "shipped source not readable: $_h_source" "none"
    return 0
  fi
  if [ "$(sha256_file "$_h_installed" 2>/dev/null || echo a)" = \
       "$(sha256_file "$_h_source" 2>/dev/null || echo b)" ]; then
    check_record "$_h_id" "ok" "matches shipped source" "none"
  else
    check_record "$_h_id" "fail" "installed copy differs from $_h_source" "repair"
  fi
  return 0
}

check_runtime() {
  if [ -f "$COMMON_RUNTIME" ]; then
    check_record "runtime.common_present" "ok" "$COMMON_RUNTIME" "none"
  else
    check_record "runtime.common_present" "fail" "missing: $COMMON_RUNTIME" "repair"
  fi
  check_hash "runtime.common_current" "$COMMON_RUNTIME" "$SCRIPT_DIR/lib/common.sh"

  if [ -x "$WRAPPER_BIN" ]; then
    check_record "runtime.wrapper_present" "ok" "executable" "none"
  elif [ -f "$WRAPPER_BIN" ]; then
    check_record "runtime.wrapper_present" "fail" "present but not executable" "repair"
  else
    check_record "runtime.wrapper_present" "fail" "missing: $WRAPPER_BIN" "repair"
  fi
  check_hash "runtime.wrapper_current" "$WRAPPER_BIN" "$SCRIPT_DIR/shims/manager-wrapper.sh"

  if [ -f "$RUNTIME_ROOT/policy.conf" ]; then
    check_record "runtime.policy_present" "ok" "$RUNTIME_ROOT/policy.conf" "none"
  else
    check_record "runtime.policy_present" "fail" "missing: $RUNTIME_ROOT/policy.conf" "repair"
  fi

  if [ -z "${POLICY_VERSION_APPLIED:-}" ]; then
    check_record "runtime.policy_version" "unknown" "not recorded in state.conf" "none"
  elif [ "$POLICY_VERSION_APPLIED" = "$POLICY_VERSION" ]; then
    check_record "runtime.policy_version" "ok" "$POLICY_VERSION" "none"
  else
    check_record "runtime.policy_version" "fail" \
      "applied $POLICY_VERSION_APPLIED, shipped $POLICY_VERSION" "repair"
  fi

  if [ ! -f "$PROFILE_SNIPPET" ]; then
    check_record "runtime.profile_snippet" "fail" "missing: $PROFILE_SNIPPET" "repair"
  elif grep -qF "export PATH=\"$SHIM_ROOT:" "$PROFILE_SNIPPET" 2>/dev/null; then
    check_record "runtime.profile_snippet" "ok" "prepends $SHIM_ROOT" "none"
  else
    check_record "runtime.profile_snippet" "fail" \
      "does not prepend $SHIM_ROOT" "repair"
  fi

  # install_runtime deletes this; its presence means a stale tree was restored.
  if [ -f "$RUNTIME_ROOT/binmap.conf" ]; then
    check_record "runtime.stale_binmap" "fail" "stale binmap.conf present" "repair"
  else
    check_record "runtime.stale_binmap" "ok" "absent" "none"
  fi
  return 0
}

check_shims() {
  _s_total=0
  _s_ok=0
  _s_missing=""
  _s_bad=""
  for _s_tool in $MANAGED_COMMANDS; do
    _s_total=$((_s_total + 1))
    _s_path="$SHIM_ROOT/$_s_tool"
    if [ ! -f "$_s_path" ] || [ ! -x "$_s_path" ]; then
      _s_missing="$_s_missing $_s_tool"
    elif grep -qF "exec \"$WRAPPER_BIN\"" "$_s_path" 2>/dev/null; then
      _s_ok=$((_s_ok + 1))
    else
      _s_bad="$_s_bad $_s_tool"
    fi
  done
  if [ -n "$_s_missing" ]; then
    check_record "shim.present" "fail" "missing or not executable:$_s_missing" "repair"
  else
    check_record "shim.present" "ok" "$_s_total/$_s_total present and executable" "none"
  fi
  if [ -n "$_s_bad" ]; then
    check_record "shim.target" "fail" "point at a different wrapper:$_s_bad" "repair"
  else
    check_record "shim.target" "ok" "$_s_ok/$_s_total point at the current wrapper" "none"
  fi
  return 0
}

check_path() {
  _p_pos=0
  _p_i=0
  _p_old_ifs=$IFS
  IFS=:
  for _p_dir in $PATH; do
    _p_i=$((_p_i + 1))
    [ "$_p_dir" = "$SHIM_ROOT" ] && [ "$_p_pos" = "0" ] && _p_pos=$_p_i
  done
  IFS=$_p_old_ifs

  # Is the PATH plumbing in place on disk, regardless of this shell?
  _p_cfg=0
  if grep -qF "export PATH=\"$SHIM_ROOT:" "$PROFILE_SNIPPET" 2>/dev/null; then
    if [ "$CHECK_SCOPE" = "machine" ]; then
      [ -f /etc/profile.d/supply-gate.sh ] && _p_cfg=1
    elif check_has_marker "$HOME/.profile" || check_has_marker "$HOME/.bashrc" ||
         check_has_marker "$HOME/.zshrc"; then
      _p_cfg=1
    fi
  fi

  if [ "$_p_pos" != "0" ]; then
    check_record "path.shim_dir" "ok" "position $_p_pos of $_p_i" "none"
  elif [ "$_p_cfg" = "1" ]; then
    # Config is on disk; this shell simply predates it. Very common: a
    # provisioning run (KACE, .deb postinst, CI) checks status in the same
    # non-login shell that just ran apply. warn, not fail -- the host is fine.
    check_record "path.shim_dir" "warn" \
      "not in THIS shell's PATH, but the config is in place; start a new login shell" "none"
  else
    check_record "path.shim_dir" "fail" \
      "$SHIM_ROOT is not in PATH and nothing on disk prepends it" "repair"
  fi

  # Resolve by content (is_managed_shim), not by directory string: correct with
  # symlinks, asdf shims and parallel installs.
  _p_leaked=""
  _p_hit=0
  _p_installed=0
  for _p_tool in $MANAGED_COMMANDS; do
    _p_found=$(command -v "$_p_tool" 2>/dev/null || true)
    [ -n "$_p_found" ] && [ -f "$_p_found" ] || continue
    _p_installed=$((_p_installed + 1))
    if is_managed_shim "$_p_found"; then
      _p_hit=$((_p_hit + 1))
    else
      _p_leaked="$_p_leaked $_p_tool"
    fi
  done

  if [ "$_p_installed" = "0" ]; then
    check_record "path.effective" "ok" "no managed tools installed yet" "none"
  elif [ -z "$_p_leaked" ]; then
    check_record "path.effective" "ok" "$_p_hit/$_p_installed resolve to shims" "none"
  elif [ "$_p_pos" = "0" ]; then
    # Already reported by path.shim_dir; nothing can be concluded about
    # interception from a shell that never sourced the profile.
    check_record "path.effective" "warn" \
      "cannot judge from this shell (shim dir not in its PATH)" "none"
  else
    # The shim dir IS in PATH but something earlier wins: a later
    # `export PATH=` in the user's own rc. repair fixes it, because
    # append_managed_block re-appends the block at end of file.
    check_record "path.effective" "fail" \
      "$SHIM_ROOT is in PATH but shadowed for:$_p_leaked" "repair"
  fi

  # Shims from another install delegate to a wrapper that may not exist.
  _p_foreign=""
  _p_old_ifs=$IFS
  IFS=:
  for _p_dir in $PATH; do
    [ -n "$_p_dir" ] && [ -d "$_p_dir" ] || continue
    [ "$_p_dir" = "$SHIM_ROOT" ] && continue
    for _p_probe in $MANAGED_COMMANDS; do
      if [ -f "$_p_dir/$_p_probe" ] && is_managed_shim "$_p_dir/$_p_probe"; then
        case " $_p_foreign " in
          *" $_p_dir "*) ;;
          *) _p_foreign="$_p_foreign $_p_dir" ;;
        esac
        break
      fi
    done
  done
  IFS=$_p_old_ifs

  if [ -n "$_p_foreign" ]; then
    check_record "path.foreign_shims" "warn" "shims from another install:$_p_foreign" "manual"
  else
    check_record "path.foreign_shims" "ok" "none" "none"
  fi
  return 0
}

check_config_file() {
  if check_has_marker "$2"; then
    check_record "$1" "ok" "$2" "none"
  elif [ -f "$2" ]; then
    check_record "$1" "fail" "no managed block in $2" "repair"
  else
    check_record "$1" "fail" "missing: $2" "repair"
  fi
  return 0
}

check_config() {
  if [ "$CHECK_SCOPE" != "machine" ]; then
    check_config_file "config.npmrc"  "$HOME/.npmrc"
    check_config_file "config.bunfig" "$HOME/.bunfig.toml"
    check_config_file "config.pip"    "$CONFIG_ROOT/pip/pip.conf"
    check_config_file "config.cargo"  "$HOME/.cargo/config.toml"
    _cf_n=0
    for _cf_p in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
      check_has_marker "$_cf_p" && _cf_n=$((_cf_n + 1))
    done
    if [ "$_cf_n" = "0" ]; then
      check_record "config.profile" "fail" \
        "no managed block in .profile/.bashrc/.zshrc" "repair"
    elif [ "$_cf_n" -lt 3 ]; then
      check_record "config.profile" "warn" "$_cf_n of 3 shell rc files" "repair"
    else
      check_record "config.profile" "ok" ".profile, .bashrc, .zshrc" "none"
    fi
    return 0
  fi

  if [ ! -f /etc/profile.d/supply-gate.sh ]; then
    check_record "config.system.profile_d" "fail" "missing: /etc/profile.d/supply-gate.sh" "repair"
  elif grep -qF "$PROFILE_SNIPPET" /etc/profile.d/supply-gate.sh 2>/dev/null; then
    check_record "config.system.profile_d" "ok" "sources $PROFILE_SNIPPET" "none"
  else
    check_record "config.system.profile_d" "fail" \
      "does not source $PROFILE_SNIPPET" "repair"
  fi

  # Only files that exist are candidates; the set differs per distro and OS
  # (/etc/bash.bashrc on Debian vs /etc/bashrc on RHEL/macOS, and likewise
  # /etc/zsh/zshrc vs /etc/zshrc).
  _cf_missing=""
  _cf_ok=""
  for _cf_rc in /etc/bash.bashrc /etc/bashrc /etc/zshrc /etc/zsh/zshrc; do
    [ -f "$_cf_rc" ] || continue
    if check_has_marker "$_cf_rc"; then
      _cf_ok="$_cf_ok $_cf_rc"
    else
      _cf_missing="$_cf_missing $_cf_rc"
    fi
  done
  if [ -n "$_cf_missing" ]; then
    check_record "config.system.rc" "fail" "no managed block in:$_cf_missing" "repair"
  else
    check_record "config.system.rc" "ok" "${_cf_ok:- no system rc files on this host}" "none"
  fi

  # zlogin is the only system-wide file zsh reads after the user's own ~/.zshrc.
  if command -v zsh >/dev/null 2>&1; then
    _cf_missing=""
    for _cf_zl in /etc/zlogin /etc/zsh/zlogin; do
      [ "$_cf_zl" = "/etc/zsh/zlogin" ] && [ ! -d /etc/zsh ] && continue
      check_has_marker "$_cf_zl" || _cf_missing="$_cf_missing $_cf_zl"
    done
    if [ -n "$_cf_missing" ]; then
      check_record "config.system.zlogin" "fail" \
        "zsh installed but no block in:$_cf_missing" "repair"
    else
      check_record "config.system.zlogin" "ok" "present for zsh login shells" "none"
    fi
  else
    check_record "config.system.zlogin" "ok" "zsh not installed" "none"
  fi

  case "$PLATFORM" in
    macos) _cf_root="/var/root" ;;
    *)     _cf_root="/root" ;;
  esac
  _cf_bad=""
  _cf_n=0
  for _cf_e in "root:$_cf_root" $(list_local_users 2>/dev/null || true); do
    _cf_home=${_cf_e#*:}
    [ -d "$_cf_home" ] || continue
    if check_has_marker "$_cf_home/.npmrc" &&
       check_has_marker "$_cf_home/.config/pip/pip.conf"; then
      _cf_n=$((_cf_n + 1))
    else
      _cf_bad="$_cf_bad ${_cf_e%%:*}"
    fi
  done
  # warn, not fail: audit_machine_cmd also treats non-root users as warnings,
  # and an account created after the last apply legitimately has no configs yet.
  if [ -n "$_cf_bad" ]; then
    check_record "config.users" "warn" "$_cf_n configured; incomplete:$_cf_bad" "repair"
  else
    check_record "config.users" "ok" "$_cf_n user(s) configured" "none"
  fi
  return 0
}

check_mode() {
  if [ "${ENFORCEMENT_MODE:-soft}" != "hard" ]; then
    check_record "mode.registries" "ok" "not applicable in soft mode" "none"
    return 0
  fi

  _m_bad=""
  for _m_pair in "NPM_REGISTRY_URL:${NPM_REGISTRY_URL:-}" \
                 "PYTHON_INDEX_URL:${PYTHON_INDEX_URL:-}" \
                 "CARGO_REGISTRY_URL:${CARGO_REGISTRY_URL:-}" \
                 "GO_PROXY_URL:${GO_PROXY_URL:-}"; do
    check_is_placeholder "${_m_pair#*:}" && _m_bad="$_m_bad ${_m_pair%%:*}"
  done
  # manual: repair re-runs apply, which fails verify_mode_prereqs the same way.
  if [ -n "$_m_bad" ]; then
    check_record "mode.registries" "fail" \
      "unset/placeholder in hard mode:$_m_bad -- edit policy/local-policy.conf" "manual"
  else
    check_record "mode.registries" "ok" "all four hard-mode URLs are real" "none"
  fi

  _m_npm=$(find_real_binary npm 2>/dev/null || true)
  if [ -z "$_m_npm" ]; then
    check_record "mode.npm_registry" "ok" "npm not installed" "none"
  else
    _m_eff=$("$_m_npm" config get registry 2>/dev/null | tr -d '\r' || true)
    case "$_m_eff" in
      "$NPM_REGISTRY_URL"|"$NPM_REGISTRY_URL/") check_record "mode.npm_registry" "ok" "$_m_eff" "none" ;;
      "") check_record "mode.npm_registry" "unknown" "npm reported no registry" "none" ;;
      *)  check_record "mode.npm_registry" "fail" \
            "registry $_m_eff, expected $NPM_REGISTRY_URL" "repair" ;;
    esac
  fi

  # Read the managed block instead of invoking pip: pip may be absent and the
  # block is what apply controls.
  _m_pipconf="$CONFIG_ROOT/pip/pip.conf"
  [ "$CHECK_SCOPE" = "machine" ] && _m_pipconf="/root/.config/pip/pip.conf"
  if [ ! -f "$_m_pipconf" ]; then
    check_record "mode.pip_index" "fail" "missing: $_m_pipconf" "repair"
  elif grep -qF "index-url = $PYTHON_INDEX_URL" "$_m_pipconf" 2>/dev/null; then
    check_record "mode.pip_index" "ok" "$PYTHON_INDEX_URL" "none"
  else
    check_record "mode.pip_index" "fail" \
      "$_m_pipconf does not set index-url to $PYTHON_INDEX_URL" "repair"
  fi

  _m_go=$(find_real_binary go 2>/dev/null || true)
  if [ -n "$_m_go" ] && "$_m_go" version >/dev/null 2>&1; then
    _m_eff=$("$_m_go" env GOPROXY 2>/dev/null | tr -d '\r' || true)
    if [ "$_m_eff" = "$GO_PROXY_URL" ]; then
      check_record "mode.goproxy" "ok" "$_m_eff" "none"
    else
      check_record "mode.goproxy" "fail" "GOPROXY=$_m_eff, expected $GO_PROXY_URL" "repair"
    fi
  else
    check_record "mode.goproxy" "ok" "go not installed or not operable" "none"
  fi
  return 0
}

check_jail() {
  [ -n "${AI_COMMANDS:-}" ] || return 0
  case "$PLATFORM" in
    windows) _j_var="AI_JAIL_LAUNCHER_WINDOWS"; _j_l=${AI_JAIL_LAUNCHER_WINDOWS:-}; _j_b=${AI_JAIL_BACKEND_WINDOWS:-} ;;
    macos)   _j_var="AI_JAIL_LAUNCHER_MACOS";   _j_l=${AI_JAIL_LAUNCHER_MACOS:-};   _j_b=${AI_JAIL_BACKEND_MACOS:-} ;;
    *)       _j_var="AI_JAIL_LAUNCHER_LINUX";   _j_l=${AI_JAIL_LAUNCHER_LINUX:-};   _j_b=${AI_JAIL_BACKEND_LINUX:-} ;;
  esac

  if [ -n "$_j_l" ] && [ -x "$_j_l" ]; then
    check_record "jail.launcher" "ok" "$_j_l (backend: ${_j_b:-unset})" "none"
    check_record "jail.runtime_effect" "ok" "$AI_COMMANDS run JAILED" "none"
  elif [ "${ENFORCEMENT_MODE:-soft}" = "hard" ]; then
    # Mirrors run_ai_tool: fail-closed in hard mode, fail-open in soft.
    check_record "jail.launcher" "fail" "$_j_var unset or not executable" "manual"
    check_record "jail.runtime_effect" "fail" "$AI_COMMANDS will be BLOCKED" "manual"
  else
    check_record "jail.launcher" "warn" "$_j_var unset or not executable" "manual"
    check_record "jail.runtime_effect" "warn" "$AI_COMMANDS run UNJAILED" "manual"
  fi

  if [ "${SCP_AI_JAIL_BYPASS:-0}" = "1" ]; then
    check_record "jail.bypass_env" "warn" "SCP_AI_JAIL_BYPASS=1 is set" "manual"
  else
    check_record "jail.bypass_env" "ok" "no bypass set" "none"
  fi
  return 0
}

check_evidence() {
  if [ ! -d "$LOG_ROOT" ]; then
    check_record "evidence.log_writable" "fail" "missing: $LOG_ROOT" "repair"
  else
    # Only a real write distinguishes "writable" from "looks writable" (ro mount,
    # ACL, SELinux). When this fails, log_init silently redirects to /dev/null
    # and the host produces no evidence while every command reports success.
    _e_probe="$LOG_ROOT/.status-probe.$$"
    if (: >"$_e_probe") 2>/dev/null; then
      rm -f "$_e_probe"
      check_record "evidence.log_writable" "ok" "writable by $(id -un)" "none"
    else
      check_record "evidence.log_writable" "fail" \
        "$LOG_ROOT not writable by $(id -un); logging falls back to /dev/null" "repair"
    fi
  fi

  if [ ! -f "$AGGREGATE_LOG" ]; then
    check_record "evidence.events" "fail" "missing: $AGGREGATE_LOG" "repair"
  elif ! (: >>"$AGGREGATE_LOG") 2>/dev/null; then
    check_record "evidence.events" "fail" "not appendable by $(id -un)" "repair"
  else
    _e_n=$(wc -l <"$AGGREGATE_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    if [ "${_e_n:-0}" = "0" ]; then
      check_record "evidence.events" "warn" "no events recorded yet" "none"
    else
      check_record "evidence.events" "ok" "$_e_n event(s)" "none"
    fi
  fi

  # Machine scope: unprivileged users' wrappers must be able to log here.
  if [ "$CHECK_SCOPE" = "machine" ] && [ -d "$LOG_ROOT" ]; then
    _e_mode=$(stat -c '%a' "$LOG_ROOT" 2>/dev/null || stat -f '%Lp' "$LOG_ROOT" 2>/dev/null || echo "")
    case "$_e_mode" in
      1777) check_record "evidence.log_perms" "ok" "mode 1777" "none" ;;
      "")   check_record "evidence.log_perms" "unknown" "cannot stat $LOG_ROOT" "none" ;;
      *)    check_record "evidence.log_perms" "fail" \
              "mode $_e_mode, expected 1777; other users cannot log" "repair" ;;
    esac
  fi
  return 0
}

# Optional tools never fail: apply/audit/repair must not depend on them.
check_optional() {
  if command -v scfw >/dev/null 2>&1; then
    if [ "${SCFW_AUTO_WRAP:-1}" = "1" ]; then
      check_record "optional.scfw" "ok" "auto-wrap on for ${SCFW_MANAGED_TOOLS:-none}" "none"
    else
      check_record "optional.scfw" "ok" "installed; auto-wrap disabled by policy" "none"
    fi
  else
    check_record "optional.scfw" "warn" "not on PATH (optional)" "none"
  fi
  if command -v bumblebee >/dev/null 2>&1; then
    check_record "optional.bumblebee" "ok" "installed" "none"
  else
    check_record "optional.bumblebee" "warn" "not on PATH (optional)" "none"
  fi
  return 0
}

# A manual fail outranks a repairable one: running repair while a manual blocker
# stands fails again for the same reason.
check_verdict() {
  if [ "$CHECK_FAIL" = "0" ]; then
    printf 'healthy\n'
  elif printf '%s' "$CHECK_RESULTS" | grep -q "${CHECK_SEP}fail${CHECK_SEP}[^${CHECK_SEP}]*${CHECK_SEP}manual$"; then
    printf 'action_required\n'
  else
    printf 'degraded\n'
  fi
  return 0
}

check_exit_code() {
  case "$1" in
    healthy) printf '0\n' ;;
    degraded) printf '1\n' ;;
    *) printf '2\n' ;;
  esac
}

check_fails_with_fix() {
  printf '%s' "$CHECK_RESULTS" | while IFS="$CHECK_SEP" read -r _f_id _f_sev _f_detail _f_fix; do
    [ -n "${_f_id:-}" ] && [ "$_f_sev" = "fail" ] && [ "$_f_fix" = "$1" ] || continue
    printf '%s%s%s\n' "$_f_id" "$CHECK_SEP" "$_f_detail"
  done
}

check_repair_hint() {
  if [ "$CHECK_SCOPE" = "machine" ]; then
    printf 'sudo ./install.sh repair --scope machine\n'
  else
    printf './install.sh repair\n'
  fi
}

check_render_next_steps() {
  _n_manual=$(check_fails_with_fix manual)
  _n_repair=$(check_fails_with_fix repair)
  # printf '%s\n', not '%s': command substitution strips the trailing newline,
  # and `read` hitting EOF without a delimiter returns non-zero, so the loop
  # body would never run for the last (often only) row.
  if [ -n "$_n_manual" ]; then
    printf '\nManual action required first (repair cannot fix these):\n'
    printf '%s\n' "$_n_manual" | while IFS="$CHECK_SEP" read -r _n_id _n_detail; do
      [ -n "${_n_id:-}" ] || continue
      printf '  - %s: %s\n' "$_n_id" "$_n_detail"
    done
  fi
  if [ -n "$_n_repair" ]; then
    printf '\nRepairable — run:  %s\n' "$(check_repair_hint)"
    printf '%s\n' "$_n_repair" | while IFS="$CHECK_SEP" read -r _n_id _n_detail; do
      [ -n "${_n_id:-}" ] || continue
      printf '  - %s\n' "$_n_id"
    done
  fi
  return 0
}

check_render_header() {
  printf 'Supply Gate — scope: %s   mode: %s   policy: %s\n' \
    "$CHECK_SCOPE" "${ENFORCEMENT_MODE:-unknown}" "$POLICY_VERSION"
  printf 'host: %s   platform: %s   state root: %s\n' \
    "$(hostname_safe)" "$PLATFORM" "$STATE_ROOT"
}

# --full: every check, grouped by section.
check_render_full() {
  check_render_header
  _r_section=""
  printf '%s' "$CHECK_RESULTS" | while IFS="$CHECK_SEP" read -r _r_id _r_sev _r_detail _r_fix; do
    [ -n "${_r_id:-}" ] || continue
    if [ "${_r_id%%.*}" != "$_r_section" ]; then
      _r_section=${_r_id%%.*}
      printf '\n%s\n' "$_r_section"
    fi
    case "$_r_sev" in
      ok) _r_tag=" ok " ;;
      warn) _r_tag="warn" ;;
      fail) _r_tag="FAIL" ;;
      *) _r_tag=" ?? " ;;
    esac
    if [ "$_r_sev" = "fail" ]; then
      printf '  [%s] %-26s %s  -> %s\n' "$_r_tag" "$_r_id" "$_r_detail" "$_r_fix"
    else
      printf '  [%s] %-26s %s\n' "$_r_tag" "$_r_id" "$_r_detail"
    fi
  done
  printf '\nverdict: %s   (%d fail, %d warn, %d ok, %d unknown)\n' \
    "$(check_verdict)" "$CHECK_FAIL" "$CHECK_WARN" "$CHECK_OK" "$CHECK_UNKNOWN"
  check_render_next_steps
  [ "$CHECK_FAIL" = "0" ] && printf '\nNothing to repair.\n'
  return 0
}

# Default: worst severity per section, then where it is configured.
check_render_condensed() {
  check_render_header
  printf '\nChecks:\n'
  for _cd_sec in $(printf '%s' "$CHECK_RESULTS" | cut -d"$CHECK_SEP" -f1 |
                   sed 's/\..*$//' | awk '!seen[$0]++'); do
    _cd_worst="ok"
    _cd_note=""
    _cd_old_ifs=$IFS
    IFS='
'
    for _cd_row in $(printf '%s' "$CHECK_RESULTS" | grep "^$_cd_sec\." || true); do
      _cd_sev=$(printf '%s' "$_cd_row" | cut -d"$CHECK_SEP" -f2)
      case "$_cd_sev" in
        fail) [ "$_cd_worst" = "fail" ] || { _cd_worst="fail"; _cd_note=$(printf '%s' "$_cd_row" | cut -d"$CHECK_SEP" -f1); } ;;
        warn) [ "$_cd_worst" = "ok" ] && { _cd_worst="warn"; _cd_note=$(printf '%s' "$_cd_row" | cut -d"$CHECK_SEP" -f1); } ;;
      esac
    done
    IFS=$_cd_old_ifs
    case "$_cd_worst" in
      ok)   printf '  [ ok ] %s\n' "$_cd_sec" ;;
      *)    printf '  [%s] %-9s (%s)\n' \
              "$( [ "$_cd_worst" = "fail" ] && printf 'FAIL' || printf 'warn' )" \
              "$_cd_sec" "$_cd_note" ;;
    esac
  done

  printf '\n'
  status_system
  printf '\nUsers:\n'
  case "$PLATFORM" in
    macos) _cd_root="/var/root" ;;
    *)     _cd_root="/root" ;;
  esac
  _cd_sys=""
  [ -f /etc/profile.d/supply-gate.sh ] && _cd_sys=1
  [ -d "$_cd_root" ] && status_user "root" "$_cd_root" "$_cd_root/.config" "$_cd_sys"
  list_local_users 2>/dev/null | while IFS=: read -r _cd_u _cd_h; do
    status_user "$_cd_u" "$_cd_h" "$_cd_h/.config" "$_cd_sys"
  done

  printf '\nverdict: %s   (%d fail, %d warn, %d ok)\n' \
    "$(check_verdict)" "$CHECK_FAIL" "$CHECK_WARN" "$CHECK_OK"
  case "$(check_verdict)" in
    healthy) printf 'Nothing to repair.\n' ;;
    degraded) printf 'Run:  %s\n' "$(check_repair_hint)"
              printf 'Details:  ./install.sh status --full%s\n' \
                "$( [ "$CHECK_SCOPE" = "machine" ] && printf ' --scope machine' )" ;;
    *) check_render_next_steps
       printf '\nDetails:  ./install.sh status --full%s\n' \
         "$( [ "$CHECK_SCOPE" = "machine" ] && printf ' --scope machine' )" ;;
  esac
  return 0
}

# Own parser: parse_scope_flag rejects unknown arguments.
parse_status_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)
        CHECK_SCOPE=${2:-}
        CHECK_SCOPE_EXPLICIT=1
        shift 2
        case "$CHECK_SCOPE" in
          user|machine) ;;
          *) echo "Unknown scope: $CHECK_SCOPE (use 'user' or 'machine')" >&2; exit 2 ;;
        esac
        ;;
      --full) CHECK_FULL=1; shift ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  return 0
}

status_run() {
  parse_status_flags "$@"

  # Infer the scope when it was not given: prefer a user-scope install if this
  # user has one, else fall back to the machine layer if the host carries it.
  # Not gated on root -- an unprivileged user on a machine-scope host asking
  # "am I protected?" must not be told "not installed" just because their own
  # home has no user-scope tree. /opt/supply-gate is 755, so this reads fine.
  if [ "$CHECK_SCOPE_EXPLICIT" = "0" ] && [ ! -d "$STATE_ROOT" ] &&
     [ -f /etc/profile.d/supply-gate.sh ]; then
    CHECK_SCOPE="machine"
  fi
  # No require_root: a non-root run still reads /opt (755) and /etc, and
  # reporting what it cannot read is more useful than refusing to run.
  [ "$CHECK_SCOPE" = "machine" ] && setup_system_paths

  # Must decide this before log_init: ensure_dirs would mkdir -p STATE_ROOT and
  # make a not-installed host look installed.
  if [ -d "$STATE_ROOT" ]; then
    log_init "status"
  else
    detach_logging
  fi

  load_runtime_state
  ENFORCEMENT_MODE=${ENFORCEMENT_MODE:-${DEFAULT_MODE:-soft}}
  log_json_event "INFO" "status.started" "install.sh" "status" "started" "$CHECK_SCOPE"

  if check_install; then
    check_runtime
    check_shims
    check_path
    check_config
    check_mode
    check_jail
    check_evidence
    check_optional
  fi

  _sr_verdict=$(check_verdict)
  _sr_exit=$(check_exit_code "$_sr_verdict")

  if [ "$CHECK_FULL" = "1" ]; then
    check_render_full
  else
    check_render_condensed
  fi

  log_json_event "INFO" "status.completed" "install.sh" "status" "$_sr_verdict" \
    "$CHECK_FAIL fail, $CHECK_WARN warn, $CHECK_OK ok"
  exit "$_sr_exit"
}
