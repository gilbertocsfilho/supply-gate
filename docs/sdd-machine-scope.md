# SDD: Machine-Scope Apply

## Problem

When `./install.sh apply` runs as root (e.g. via KACE), `$HOME` resolves to `/root`. All
profile blocks and package-manager configs are written only to root's dotfiles. Other users on
the machine never receive the shim PATH or enforcement configs, so the wrapper is effectively
absent for those users.

Affected paths under current behavior:

| File | Root path written |
|---|---|
| Shell profile snippet | `/root/.profile`, `/root/.bashrc`, `/root/.zshrc` |
| npm config | `/root/.npmrc` |
| bun config | `/root/.bunfig.toml` |
| pip config | `/root/.config/pip/pip.conf` |
| cargo config | `/root/.cargo/config.toml` |
| shim directory | `/root/.local/share/supply-chain-protect/shims/` |

## Goals

1. `apply --scope machine` applies to all local user accounts and the system-wide profile layer.
2. `uninstall --scope machine` removes managed blocks from all locations.
3. `status` (new subcommand) reports which profiles and users are currently configured.
4. Existing `--scope user` (default) behaviour is unchanged.

## Non-Goals

- Windows multi-user: keep current per-user PowerShell behaviour.
- Remote or LDAP/AD users whose home directories live on network mounts.
- Applying per-user Go toolchain env (`go env -w`) for non-root users (see note below).

## Design

### Scope flag

```
./install.sh apply [--mode soft|hard] [--scope user|machine]
./install.sh audit [--scope user|machine]
./install.sh repair [--scope user|machine]
./install.sh uninstall [--scope user|machine]
./install.sh status
```

`--scope user` is the default. An explicit `--scope machine` is required for the new
behaviour. This avoids surprises in existing scripts that already run as root for single-user
environments.

### System paths (machine scope)

| Variable | Default |
|---|---|
| `STATE_ROOT` | `/opt/supply-gate` |
| `SHIM_ROOT` | `/opt/supply-gate/shims` |
| `RUNTIME_ROOT` | `/opt/supply-gate/runtime` |
| `LOG_ROOT` | `/opt/supply-gate/logs` |

These can be overridden via `INSTALL_ROOT_OVERRIDE` as before.

### System-wide PATH injection

`/etc/profile.d/supply-gate.sh` is written with a single line:

```sh
. "/opt/supply-gate/runtime/profile.sh"
```

This file is sourced automatically by `/etc/profile` for all login shells on most Linux
distributions. For non-login interactive shells, the same block is also appended (using the
existing managed-block mechanism) to:

- `/etc/bash.bashrc` (Debian/Ubuntu path for bash non-login shells)
- `/etc/zshrc` (zsh system-wide rc, if present)
- `/etc/zsh/zshrc` (alternate path on some distributions)

### User enumeration

```sh
list_local_users()
```

Reads `/etc/passwd` and emits `username:home_dir` pairs for accounts that satisfy all of:

- UID in range `[1000, 60000)` (configurable via `LOCAL_USER_UID_MIN` / `LOCAL_USER_UID_MAX`)
- Login shell is not `/sbin/nologin`, `/usr/sbin/nologin`, `/bin/false`, `/bin/sync`,
  `/bin/halt`, or `/bin/shutdown`
- Home directory exists on disk

Root (UID 0) is always included so its dotfiles also receive the managed blocks.

### Per-user package-manager configs

For each enumerated user (including root), the following are applied with their `HOME` and
`CONFIG_ROOT` temporarily substituted:

- `configure_npm` → `$HOME/.npmrc`
- `configure_bun` → `$HOME/.bunfig.toml`
- `configure_pip` → `$HOME/.config/pip/pip.conf`
- `configure_cargo` → `$HOME/.cargo/config.toml`

Per-user shell dotfiles (`.profile`, `.bashrc`, `.zshrc`) are **not** written in machine
scope; the system-wide files replace them for PATH purposes.

### Go environment (machine scope)

`go env -w` modifies `$GOENV` (defaults to `~/.config/go/env`). Running it as root for
another user's env file is unreliable without `su`. In machine scope, `configure_go` is
skipped for non-root users. The wrapper still intercepts `go` via the shim; only the
`GOPROXY`/`GOSUMDB` env defaults are not written.

Operators who need per-user Go env can run:

```sh
./install.sh apply --scope user
```

as each individual user, or provision `/etc/environment` with the relevant vars separately.

### `status` subcommand

Prints a human-readable report to stdout:

```
System-wide:
  /etc/profile.d/supply-gate.sh: present
  /etc/bash.bashrc: managed block present
  /etc/zshrc: absent

Users:
  root  (/root):   4 files managed  [.npmrc .bunfig.toml pip.conf .cargo/config.toml]
  alice (/home/alice): 3 files managed  [.npmrc pip.conf .cargo/config.toml]
  bob   (/home/bob):   not configured
```

Exit code is `0` if at least one location is configured, `1` if nothing is configured.

### Permissions and safety

- Machine-scope commands require UID 0; the script exits early with an error if run as a
  non-root user.
- `/etc/profile.d/supply-gate.sh` is written with mode `644` and owned by `root:root`.
- The system `STATE_ROOT` is mode `755`; the `logs/` subdirectory is `750`.
- The wrapper binary (`manager-wrapper.sh`) and shims remain `755`.

### Changes to existing functions

| Function | Change |
|---|---|
| `apply_cmd` | parse `--scope`; dispatch to `apply_user_cmd` or `apply_machine_cmd` |
| `uninstall_cmd` | parse `--scope`; dispatch to `uninstall_user_cmd` or `uninstall_machine_cmd` |
| `audit_cmd` | parse `--scope`; check system files in machine scope |
| `repair_cmd` | preserve scope from saved state; pass through |
| `apply_posix_profiles` | unchanged (user scope only) |

### New functions in `lib/common.sh`

| Function | Purpose |
|---|---|
| `list_local_users` | emit `user:home` for each eligible local account |
| `apply_user_configs_for_home home config_root` | run configure_* for a given home |
| `remove_user_configs_for_home home config_root` | run remove_managed_block for a given home |
| `apply_system_profiles` | write `/etc/profile.d/` and system rc files |
| `remove_system_profiles` | remove `/etc/profile.d/supply-gate.sh` and system rc blocks |
| `status_system` | report system-wide files |
| `status_user username home config_root` | report per-user managed files |

### New functions in `install.sh`

| Function | Purpose |
|---|---|
| `apply_machine_cmd` | full machine-scope apply |
| `uninstall_machine_cmd` | full machine-scope uninstall |
| `status_cmd` | print status report |
| `require_root` | exit 1 with error if `$(id -u) != 0` |
| `setup_system_paths` | override STATE_ROOT and derived vars to system locations |
| `parse_scope_flag` | parse `--scope user|machine` from arg list |

## Test Plan

### Unit tests (`tests/test_machine_scope.sh`)

Tests use a fake root tree under `$TMPDIR` and a synthetic `/etc/passwd` fragment. No
real system files are modified.

| Test | What is asserted |
|---|---|
| `test_list_local_users_basic` | Normal user (UID 1001) with valid shell is included |
| `test_list_local_users_excludes_nologin` | Account with `/sbin/nologin` is excluded |
| `test_list_local_users_excludes_system` | Account with UID 500 is excluded |
| `test_list_local_users_excludes_missing_home` | Account whose home does not exist is excluded |
| `test_apply_system_profile_creates_file` | `/etc/profile.d/supply-gate.sh` is created |
| `test_apply_system_profile_idempotent` | Running twice does not duplicate content |
| `test_apply_user_configs_writes_npmrc` | `.npmrc` for a given home gets the managed block |
| `test_apply_user_configs_writes_pip` | `pip.conf` for a given home gets the managed block |
| `test_apply_all_users_configs_reaches_all` | Both root and local user receive configs |
| `test_remove_system_profiles_deletes_file` | `supply-gate.sh` is removed |
| `test_remove_system_profiles_removes_bash_block` | bash.bashrc block is stripped |
| `test_remove_user_configs_strips_npmrc` | `.npmrc` block is removed; rest of file is intact |
| `test_status_system_reports_present` | status output contains "present" when file exists |
| `test_status_system_reports_absent` | status output contains "absent" when file is missing |
| `test_status_user_reports_count` | status counts managed files for a user |
| `test_status_user_reports_not_configured` | status shows "not configured" for unconfigured user |
| `test_apply_machine_requires_root` | Non-root invocation exits with error |

### Integration check

After `apply --scope machine` on a test VM:

```sh
./install.sh status
# → system-wide files present, all local users configured

./install.sh audit --scope machine
# → exits 0

./install.sh uninstall --scope machine
./install.sh status
# → exits 1 (nothing configured)
```
