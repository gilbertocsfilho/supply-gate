# SDD: `status` — Integrity Checks and Repair Guidance

Status: **implemented** 2026-08-05. Written 2026-08-04 as a proposal; this revision
records what actually shipped, including where the design changed under review. See
"Deltas from the proposal" at the end.

This SDD covers two deliverables that were requested together:

- **Part A** — read-only integrity checks with a verdict that tells the operator
  whether `./install.sh repair` will fix what was found. Shipped inside the existing
  `status` subcommand (`lib/checks.sh`), not as a separate command.
- **Part B** — a container-based test harness that exercises `apply` / `status` /
  `repair` / `uninstall` across distributions and shells (`bash`, `zsh`, `dash`,
  `ash`), including the limits of what a Linux container can say about macOS.

## Problem

### Part A

Today there are two commands that inspect state, and neither answers "is this tool
actually working on this machine?":

| Command | What it does | Gap |
|---|---|---|
| `audit` | compliance evidence: counts missing markers/shims, writes `status.env`, exits `1` on any failure | binary verdict, no per-check detail, mutates attestation state, cannot be run casually |
| `status` | lists which profiles/users carry a managed block | says nothing about the runtime, shims, PATH precedence or mode coherence |

Concretely, the following real failure modes are invisible to both:

1. `$SHIM_ROOT` is in `PATH` but *not first* — the user's own `~/.zshrc` does
   `export PATH="$HOME/.local/bin:$PATH"` after our block, so `npm` resolves to the
   real binary and interception silently stops. `audit` still passes: the shim files
   exist and the managed blocks are present.
2. A stale parallel install (user-scope `~/.local/share/supply-chain-protect/shims`
   left over in front of a machine-scope `/opt/supply-gate/shims`) puts shims from a
   *different* `STATE_ROOT` earlier in `PATH`, pointing at a `WRAPPER_BIN` that may no
   longer exist.
3. The installed runtime has drifted from the shipped source — `<STATE_ROOT>/runtime/common.sh`
   is from an older version than `lib/common.sh` in the package. Everything "exists",
   so `audit` passes, while the wrapper runs old logic.
   **Confirmed empirically** on 2026-08-05 in an `ubuntu:24.04` container: after
   `apply --scope machine`, appending a line to `/opt/supply-gate/runtime/common.sh`
   left `audit --scope machine` exiting `0`. Deleting the same file *was* caught.
   So `audit` verifies presence, never content.
4. `hard` mode is recorded in `state.conf`, but the effective `npm registry` /
   `pip index-url` / `GOPROXY` no longer match policy (someone edited a dotfile
   outside the managed block, or a `go env -w` was overwritten).
5. The `ai-jail` launcher is absent, so `claude`/`gemini`/`codex` are either blocked
   (`hard`) or unjailed (`soft`). `verify_ai_jail_status` warns about this at
   `apply` time only — that warning scrolls away and is never re-surfaced.
6. `LOG_ROOT` is not writable by the invoking user, so `log_init` silently falls back
   to `/dev/null` and the machine produces **no audit evidence at all** while every
   command still appears to succeed.

Cases 1, 2, 3 and 6 are exactly the ones where the tool looks installed and is not
enforcing anything.

### Part B

There is a single test file, `tests/test_machine_scope.sh`. It is POSIX `sh`, runs on
the developer's own box against a fake tree under `$TMPDIR`, and — by design — stubs
`configure_*` and reimplements `list_local_users` instead of running the real thing.
There is no `tests/run.sh`, no `.github/workflows/`, no container lane, and no test
that ever runs `install.sh` end to end.

Nothing currently validates:

- a real `apply --scope machine` as real root, with real `/etc/*` files;
- PATH precedence *as observed by an interactive/login shell* — the single most
  important property of the whole tool;
- `zsh` at all, on any platform, despite `apply_system_profiles` carrying
  distribution-specific `zsh` logic (`/etc/zshrc` vs `/etc/zsh/zshrc`, plus the
  `zlogin` prepend that exists specifically because zsh sources system rc files
  *before* `~/.zshrc`);
- non-Debian layouts (`/etc/zsh` absent) or busybox userland (`awk`, `stat`, `grep`
  differences on Alpine);
- the macOS-only branches: `detect_platform` → `macos`, `list_local_users_macos`
  (`dscl`), `/var/root`, `AI_JAIL_*_MACOS`, and the BSD `stat -f` arm of `path_owner`.

## Goals

1. `./install.sh status` prints a per-check integrity report and exits with a verdict
   that distinguishes "repair fixes this" from "a human must act".
2. `status` is **read-only by default**: it never writes to a dotfile, a config, a
   shim, `state.conf`, or `status.env`.
3. `status --full` lists every individual check; the default output is one line per section.
4. `status` works in both scopes (`--scope user|machine`) and when nothing is
   installed at all.
5. A container harness runs the real `install.sh` across the distro/shell matrix,
   asserting PATH precedence from a login `zsh` and a login `bash`.
6. **No existing function in `install.sh` or `lib/common.sh` is modified.** See
   "Frozen Surface" — this is a hard constraint, not a preference.

## Non-Goals

- Changing, "improving", or refactoring `audit`, `status`, `repair`, `apply`, or any
  `configure_*` function. Not even signature-compatible cleanups.
- Making `status` fix anything. Remediation stays with `repair`, which stays exactly
  as it is (`load_runtime_state` then `apply --mode <saved>`).
- Adding a `status` step inside `apply`, `audit`, or `repair`.
- Making `scfw` / `bumblebee` / `ai-jail` mandatory. `status` reports them as
  informational only and their absence never produces a `FAIL`.
- Running real macOS in a container. Impossible — see "macOS: what containers can
  and cannot prove".
- Windows coverage in the harness. `scripts/windows-apply.ps1` keeps its current
  manual-verification status.
- CI wiring (`.github/workflows/`). The harness is a script an operator or a future
  CI job invokes; adding CI is a separate decision.

## Frozen Surface

The complete set of allowed edits. Anything outside this list is out of scope for
this SDD and must be proposed separately.

| Change | File | Nature |
|---|---|---|
| Add `status` lines to the help text | `install.sh` → `usage()` | additive text only, no logic |
| Add the `status` dispatch wiring | `install.sh` → dispatch `case` | one new branch; existing branches untouched |
| Add `. "$SCRIPT_DIR/lib/checks.sh"` | `install.sh`, immediately after the existing `lib/common.sh` source | one new line |
| New file: all `status` logic | `lib/checks.sh` | new file |
| New files: harness + tests | `tests/**`, `tests/docker/**` | new files |
| Document the command | `README.md`, `GUIDE.md` | additive prose |

Explicitly **not touched**: `apply_cmd`, `apply_user_cmd`, `apply_machine_cmd`,
`audit_cmd`, `audit_user_cmd`, `audit_machine_cmd`, `repair_cmd`, `uninstall_*`,
`status_cmd`, `configure_npm|bun|pip|cargo|go`, `create_shims`, `install_runtime`,
`write_profile_snippet`, `apply_posix_profiles`, `verify_mode_prereqs`,
`verify_ai_jail_status`, `parse_mode_flag`, `parse_scope_flag`, `require_root`,
`setup_system_paths`, and every function in `lib/common.sh`.

Two consequences worth stating, because they are why this split is cheap:

- `lib/checks.sh` **reads** helpers from `lib/common.sh` (`is_managed_shim`,
  `find_real_binary`, `resolve_real_binary`, `sha256_file`, `path_owner`,
  `list_local_users`, `contains_marker` — note the last lives in `install.sh`, so
  `status` defines its own `check_has_marker` rather than depending on load order).
  It calls none of the mutating ones.
- No build script change is needed: `build/deb/build-deb.sh` and
  `build/macos/build-macos-pkg.sh` both package `lib` as a whole directory
  (`PAYLOAD_ITEMS="install.sh lib shims scripts policy README.md GUIDE.md VERSION"`),
  so `lib/checks.sh` ships automatically.

## Part A — Design: `status`

### CLI

```
./install.sh status [--scope user|machine] [--json] [--save]
```

| Flag | Meaning |
|---|---|
| `--scope user` | default; inspects `$HOME`-derived paths, like `audit_user_cmd` |
| `--scope machine` | inspects `/opt/supply-gate` + `/etc/*` + all local users. Requires root **only** because some system paths are unreadable otherwise; it calls `setup_system_paths` but not `require_root` — a non-root run degrades to reporting `unknown` for unreadable checks rather than exiting `1` |
| `--json` | emit a single JSON object instead of the text report |
| `--full` | list every check instead of a per-section summary |

`--scope all` is rejected with exit `2`, matching `apply_cmd`/`audit_cmd`.

Flag parsing lives in a new `parse_status_flags` inside `lib/checks.sh`. It does not
reuse `parse_scope_flag`, because that function rejects unknown arguments and would
have to be edited to accept `--json`/`--save` — which the Frozen Surface forbids.

### Relationship to `audit` and `repair`

| | `audit` | `status` |
|---|---|---|
| Purpose | compliance evidence for a fleet | diagnosis for a human or a repair decision |
| Mutates `status.env` | yes (`save_status`) | **no** |
| Mutates dotfiles/shims | no | no |
| Writes `events.jsonl` | yes | yes (`status.started` / `status.completed`) |
| Output | log lines + pass/fail | per-check report + verdict + next command |
| Exit codes | `0` / `1` | `0` / `1` / `2` |

`status` deliberately does **not** call `save_status`. `status.env` is audit's
attestation; a `status` run overwriting `STATUS="compliant"` would corrupt the
evidence trail that section 16 of `GUIDE.md` requires. It does append to
`events.jsonl` for the same reason everything else does — a diagnosis that leaves no
trace is not useful during an incident.

### Check catalogue

Each check yields: `id`, `severity` (`ok` | `warn` | `fail` | `unknown`), a one-line
`detail`, and `fix` (`repair` | `manual` | `none`). The `fix` field is what makes the
verdict actionable: a `fail` whose `fix` is `repair` means `./install.sh repair`
resolves it; `manual` means it will not.

#### `install.*` — is anything installed

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `install.state_root` | `$STATE_ROOT` exists and is a directory | `repair` |
| `install.mode` | `state.conf` exists and defines `ENFORCEMENT_MODE` | `repair` |

If `install.state_root` fails, the run **short-circuits**: it prints "not installed"
with `fix=manual` (`./install.sh apply`, not `repair`, is the right command) and
exits `2`. Running the remaining ~40 checks against a nonexistent tree produces
noise, not information.

#### `runtime.*` — installed runtime integrity

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `runtime.common_present` | `<STATE_ROOT>/runtime/common.sh` exists | `repair` |
| `runtime.common_current` | its sha256 equals `sha256("$SCRIPT_DIR/lib/common.sh")` | `repair` |
| `runtime.wrapper_present` | `runtime/manager-wrapper.sh` exists and is `-x` | `repair` |
| `runtime.wrapper_current` | its sha256 equals `sha256("$SCRIPT_DIR/shims/manager-wrapper.sh")` | `repair` |
| `runtime.policy_present` | `runtime/policy.conf` exists | `repair` |
| `runtime.policy_version` | `POLICY_VERSION_APPLIED` in `state.conf` equals the current `POLICY_VERSION` | `repair` |
| `runtime.profile_snippet` | `runtime/profile.sh` exists and contains `export PATH="$SHIM_ROOT:` | `repair` |
| `runtime.stale_binmap` | `runtime/binmap.conf` is **absent** (a leftover from pre-live-resolution installs) | `repair` |

The two `*_current` hash checks are the answer to failure mode 3 and are the reason
`status` must run from a repo/package checkout: they compare *installed* against
*shipped*. When `$SCRIPT_DIR/lib/common.sh` is unreadable (someone copied only
`install.sh` somewhere), severity is `unknown`, not `fail`.

#### `shim.*` — shim integrity

For every `$tool` in `MANAGED_COMMANDS`:

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `shim.present.<tool>` | `$SHIM_ROOT/$tool` exists, is a file, mode has `+x` | `repair` |
| `shim.target.<tool>` | the `exec "<path>"` inside it equals the current `$WRAPPER_BIN` | `repair` |

Rolled up into a single reported line per severity class (`14 ok`, or the explicit
list of offenders) so the report stays readable.

One deliberate non-check: a missing *real binary* for a managed tool is **`ok`, not
`warn`**. `create_shims` writes shims unconditionally by design so a tool installed
later is intercepted without a reapply; flagging `agy` on a machine that has no
Antigravity would make every clean install look degraded.

#### `path.*` — is interception actually in effect

This is the section that justifies the command.

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `path.shim_dir_present` | `$SHIM_ROOT` appears in the invoking `$PATH` | `manual` — needs a new login shell, or the block is missing (then `config.profile.*` also fails and repair does fix it) |
| `path.shim_dir_first` | no directory containing a real managed binary precedes `$SHIM_ROOT` in `$PATH` | `manual` |
| `path.effective.<tool>` | for each managed tool that **is** installed, `command -v <tool>` resolves to a path satisfying `is_managed_shim` | `manual` |
| `path.foreign_shims` | no *other* directory in `$PATH` contains files matching `is_managed_shim` but outside `$SHIM_ROOT` (stale parallel install) | `manual` |

`path.effective.*` is the ground truth: it uses `is_managed_shim` (content-based,
the same detection the wrapper uses to avoid self-recursion) rather than comparing
directory strings, so it is correct in the presence of symlinks, `asdf` shims and
multiple installs.

All four are `fix=manual` on purpose. `repair` re-runs `apply`, which rewrites the
managed block — but a block that is already present and simply *outdated by the
user's own later `export PATH=`* is not something `apply` can fix. The report says
so instead of sending the operator in a circle. The hint distinguishes the two
sub-cases: "managed block missing → run `repair`" vs. "block present but shadowed by
a later PATH edit in `~/.zshrc:NN` → move your edit above the managed block".

Caveat recorded in the report footer: `status` observes the `PATH` of the shell that
launched it. Running it right after `apply` in the same shell will report
`path.shim_dir_present` as `fail` even though the install is fine. The footer says
"start a new login shell and re-run" whenever `path.*` fails while `config.profile.*`
passes.

#### `config.*` — managed blocks

Read-only marker checks, mirroring what `audit_user_cmd` looks at, but reported per
file instead of counted:

| id | File (user scope) |
|---|---|
| `config.npmrc` | `$HOME/.npmrc` |
| `config.bunfig` | `$HOME/.bunfig.toml` |
| `config.pip` | `$CONFIG_ROOT/pip/pip.conf` |
| `config.cargo` | `$HOME/.cargo/config.toml` |
| `config.profile.<file>` | `$HOME/.profile`, `.bashrc`, `.zshrc` |

In machine scope, additionally:

| id | Asserts |
|---|---|
| `config.system.profile_d` | `/etc/profile.d/supply-gate.sh` exists and sources `$PROFILE_SNIPPET` |
| `config.system.rc` | managed block present in each existing `/etc/bash.bashrc`, `/etc/zshrc`, `/etc/zsh/zshrc` |
| `config.system.zlogin` | managed block present in `/etc/zlogin` and, when `/etc/zsh` exists, `/etc/zsh/zlogin` — only checked when `zsh` is on `PATH`, matching `apply_system_profiles` |
| `config.users` | per user from `list_local_users` (plus platform root home): count of managed files, `warn` when a user has zero while the system layer is present |

All `config.*` failures are `fix=repair`. Per-user config failures are `warn`, not
`fail` — the same asymmetry `audit_machine_cmd` already encodes (root's configs count
toward failure, other users' are logged as warnings).

#### `mode.*` — mode coherence

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `mode.hard_registries` | in `hard`: `NPM_REGISTRY_URL`, `PYTHON_INDEX_URL`, `CARGO_REGISTRY_URL`, `GO_PROXY_URL` are non-empty and not placeholders | `manual` — the operator must edit `policy/local-policy.conf` |
| `mode.npm_registry` | in `hard`: `npm config get registry` equals `NPM_REGISTRY_URL` | `repair` |
| `mode.pip_index` | in `hard`: effective `index-url` equals `PYTHON_INDEX_URL` | `repair` |
| `mode.goproxy` | in `hard`: `go env GOPROXY` equals `GO_PROXY_URL` | `repair` |

`mode.hard_registries` reimplements the *predicate* of `require_hard_value`
(placeholder detection) locally rather than calling it, because that function emits
`log_error` + a `policy.invalid` JSON event — side effects a diagnosis must not
produce. The duplicated pattern list is small and is called out in a comment in both
places when implemented.

In `soft` mode all four report `ok` with detail `not applicable in soft mode`.

#### `jail.*` — AI CLI sandbox

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `jail.launcher` | the `AI_JAIL_LAUNCHER_<PLATFORM>` for the *current* platform is set and `-x` | `manual` |
| `jail.runtime_effect` | informational: states what `claude`/`gemini`/`codex` will actually do — `jailed`, `BLOCKED` (hard, no launcher), or `UNJAILED` (soft, no launcher) | `manual` |
| `jail.bypass_env` | `warn` when `SCP_AI_JAIL_BYPASS` is set in the invoking environment | `manual` |

Severity for `jail.launcher` follows the same fail-open/fail-closed split as
`run_ai_tool`: `fail` in `hard` mode (AI tools are blocked — the tool is not
functional as configured), `warn` in `soft` mode (they run unjailed, which is the
documented soft-mode behaviour). `jail.bypass_env` exists because a forgotten export
in a shell profile silently disables the sandbox for every future session.

#### `evidence.*` — logging plumbing

| id | Asserts | fail ⇒ fix |
|---|---|---|
| `evidence.log_root_writable` | `$LOG_ROOT` exists and a probe file can be created **and is then removed** | `repair` |
| `evidence.aggregate_appendable` | `$AGGREGATE_LOG` exists and is appendable by the invoking user | `repair` |
| `evidence.machine_perms` | machine scope only: `$LOG_ROOT` is `1777` and `$AGGREGATE_LOG` is world-writable | `repair` |
| `evidence.recent_activity` | informational: timestamp of the last `events.jsonl` line; `warn` if the file is empty | `none` |
| `evidence.log_rotation` | informational: count of run logs older than `LOG_RETENTION_DAYS` | `none` |

`evidence.log_root_writable` is the one check that creates a file. It writes
`$LOG_ROOT/.status-probe.$$` and unlinks it immediately; this is not a state change
and is the only way to distinguish "writable" from "looks writable but isn't"
(ACLs, read-only mount, `nosuid`/`ro` bind, SELinux). It is skipped under `--json`
only if `LOG_ROOT` does not exist.

This section catches failure mode 6, where `log_init` silently redirects to
`/dev/null` and the machine produces no compliance evidence while reporting success.

#### `optional.*` — never a failure

| id | Reports |
|---|---|
| `optional.scfw` | `scfw` on `PATH`; whether `SCFW_AUTO_WRAP=1`; which tools `SCFW_MANAGED_TOOLS` covers |
| `optional.bumblebee` | `bumblebee` on `PATH` and its version |

Both are `ok` when present and `warn` when absent, never `fail`. This encodes the
boundary from `README.md` ("Optional tools are intentionally kept outside `apply`")
and `GUIDE.md` §18 ("Não torne `bumblebee` dependência obrigatória do instalador").

### Verdict and exit codes

| Exit | Verdict | Condition | Printed next step |
|---|---|---|---|
| `0` | `healthy` | no `fail` | none (warnings are listed but do not change the verdict) |
| `1` | `degraded` | ≥1 `fail`, **all** with `fix=repair` | `./install.sh repair [--scope <scope>]` |
| `2` | `action_required` | ≥1 `fail` with `fix=manual`, or nothing is installed | the specific manual step per finding |

When both kinds of `fail` are present the verdict is `2`, and the report orders the
manual items first — running `repair` while a manual blocker stands (a placeholder
`hard`-mode registry, for instance) fails again for the same reason.

`unknown` never changes the verdict; it is surfaced in the report with the reason
(usually "not readable as non-root" or "source checkout not available").

### Text report format

```
Supply Gate status — scope: machine   mode: hard   policy: 1.0.0
host: dev-box-01   platform: linux   state root: /opt/supply-gate

install
  [ ok ] install.state_root           /opt/supply-gate
  [ ok ] install.mode                 hard (applied 2026-08-04T11:02:19Z)
runtime
  [ ok ] runtime.common_present       /opt/supply-gate/runtime/common.sh
  [FAIL] runtime.common_current       installed copy differs from lib/common.sh   -> repair
  [ ok ] runtime.wrapper_present      mode 755
  [ ok ] runtime.stale_binmap         absent
shims
  [ ok ] shim.present                 14/14 present and executable
  [ ok ] shim.target                  14/14 point at the current wrapper
path
  [ ok ] path.shim_dir_present        position 1 of 11
  [FAIL] path.effective               npm, pnpm resolve to real binaries, not shims  -> manual
  [warn] path.foreign_shims           /home/gcsf/.local/share/supply-chain-protect/shims (stale user-scope install)
config
  [ ok ] config.system.profile_d      present
  [ ok ] config.system.zlogin         /etc/zlogin, /etc/zsh/zlogin
  [ ok ] config.users                 root, gcsf, build  (3/3 configured)
mode
  [ ok ] mode.hard_registries         all four set to non-placeholder values
  [FAIL] mode.goproxy                 go env GOPROXY=https://proxy.golang.org,direct, expected https://go.corp.internal  -> repair
jail
  [FAIL] jail.launcher                AI_JAIL_LAUNCHER_LINUX unset; hard mode
         jail.runtime_effect          claude, gemini, codex, agy will be BLOCKED at runtime  -> manual
evidence
  [ ok ] evidence.log_root_writable   1777
  [ ok ] evidence.aggregate_appendable 4812 events, last 2026-08-04T13:44:02Z
optional
  [ ok ] optional.scfw                0.4.1, auto-wrap on for npm pip pip3 poetry
  [warn] optional.bumblebee           not on PATH

verdict: action_required   (3 fail, 2 warn, 41 ok)

Manual action required, in this order:
  1. jail.launcher — set AI_JAIL_LAUNCHER_LINUX in policy/local-policy.conf
  2. path.effective — the managed block is present in /home/gcsf/.zshrc:88 but a
     later 'export PATH=' at line 103 shadows it; move that edit above the block
Then, for the repairable findings (runtime.common_current, mode.goproxy):
  ./install.sh repair --scope machine
```

Nothing is coloured; the report must be readable in a KACE log capture and in
`docker logs`. Alignment uses `printf` field widths only.

### JSON report format

One object, one line per top-level key, stable field names:

```json
{
  "schema": "supply-gate.status/1",
  "timestamp": "2026-08-04T13:44:07Z",
  "host": "dev-box-01",
  "platform": "linux",
  "scope": "machine",
  "mode": "hard",
  "policy_version": "1.0.0",
  "state_root": "/opt/supply-gate",
  "verdict": "action_required",
  "exit_code": 2,
  "counts": { "ok": 41, "warn": 2, "fail": 3, "unknown": 0 },
  "repair_would_fix": ["runtime.common_current", "mode.goproxy"],
  "manual_required": ["jail.launcher", "path.effective"],
  "checks": [
    { "id": "runtime.common_current", "severity": "fail",
      "detail": "installed copy differs from lib/common.sh", "fix": "repair" }
  ]
}
```

`repair_would_fix` and `manual_required` are precomputed so a fleet rule can act on
them without walking `checks`. JSON escaping reuses `json_escape` from
`lib/common.sh`.

### New functions (all in `lib/checks.sh`)

| Function | Purpose |
|---|---|
| `check_cmd` | entry point: parse flags, dispatch, render, exit with verdict |
| `parse_status_flags` | `--scope` / `--json` / `--save`, rejecting `--scope all` |
| `check_record id severity detail fix` | append one result to the in-memory result list |
| `check_has_marker file` | marker test local to status (does not depend on `contains_marker` from `install.sh`) |
| `check_check_install` | `install.*` |
| `check_check_runtime` | `runtime.*` |
| `check_check_shims` | `shim.*` |
| `check_check_path` | `path.*` |
| `check_check_config` | `config.*` for the active scope |
| `check_check_mode` | `mode.*` |
| `check_check_jail` | `jail.*` |
| `check_check_evidence` | `evidence.*` |
| `check_check_optional` | `optional.*` |
| `check_verdict` | fold results into `healthy` / `degraded` / `action_required` |
| `check_render_text` | the text report |
| `check_render_json` | the JSON report |

Results accumulate in a single newline-delimited variable (`id\tseverity\tdetail\tfix`),
not an array — the codebase is POSIX `sh` and has no arrays. Details must therefore
not contain tabs or newlines; `check_record` strips both.

## Part B — Design: container test harness

### Layout

```
tests/
  helpers.sh                  (existing, unchanged)
  test_machine_scope.sh       (existing, unchanged)
  run.sh                      NEW  run every tests/test_*.sh, aggregate exit code
  test_checks.sh              NEW  unit tests for lib/checks.sh predicates
  docker/
    run-matrix.sh             NEW  build + run every lane, aggregate results
    Dockerfile.debian         NEW
    Dockerfile.ubuntu         NEW
    Dockerfile.fedora         NEW
    Dockerfile.alpine         NEW
    Dockerfile.darwin-faked   NEW  debian + macOS command stubs
    scenario.sh               NEW  the end-to-end scenario, runs inside a container
    stubs/                    NEW  uname, dscl, sw_vers, sandbox-exec fakes
```

`tests/run.sh` and `tests/docker/**` are new files only; the existing two test files
are not edited.

### Matrix

| Lane | Image | Shells exercised | What only this lane proves |
|---|---|---|---|
| `debian` | `debian:12` | `bash`, `dash` (as `/bin/sh`), `zsh` | Debian-family layout: `/etc/bash.bashrc`, `/etc/zsh/zshrc`, `/etc/zsh/zlogin` |
| `ubuntu` | `ubuntu:24.04` | `bash`, `zsh` | the actual fleet target; `.deb` install path via `dpkg -i` |
| `fedora` | `fedora:41` | `bash`, `zsh` | non-Debian layout: `/etc/zshrc` and `/etc/zlogin` present, `/etc/zsh` **absent** |
| `alpine` | `alpine:3.20` | `ash`, `zsh` | busybox `awk`/`stat`/`grep`/`find` — `list_local_users_passwd`, `path_owner`, `rotate_logs` portability |
| `macos-layout` | `ubuntu:24.04` + forced layout | `zsh` | the `sysconfdir=/etc` arm macOS takes: `/etc/zshrc` + `/etc/zlogin`, no `/etc/zsh` |
| `darwin-faked` | `debian:12` + stubs | `zsh` | macOS *code paths* only — see the honest limits below |

Validated in a throwaway `ubuntu:24.04` container on 2026-08-05, before this SDD was
finalized: 21 of 25 assertions passed on the first try. The four that did not are
recorded below (two are shell semantics, one was a bug in the probe, one is the
`audit` blind spot above) — none required a code change to `apply`/`uninstall`.

### Shell invocation matters more than the distro

Measured, same container, `alice` carrying `export PATH="$HOME/.local/bin:$PATH"` in
her own `~/.zshrc`:

| Invocation | Sources | `command -v npm` |
|---|---|---|
| `zsh -lc` | `zshenv`, `zprofile`, `zlogin` | **shim** ✅ |
| `zsh -ic` | `zshenv`, `/etc/zsh/zshrc`, `~/.zshrc` | **shim** ✅ |
| `zsh -c` | `zshenv` only | real binary ❌ |
| `bash -lc` | `/etc/profile` → `/etc/profile.d/` | **shim** ✅ |
| `bash -ic` | `/etc/bash.bashrc`, `~/.bashrc` | **shim** ✅ |
| `bash -c` | nothing (only `$BASH_ENV`) | real binary ❌ |

The two `-c` rows are **correct behaviour, not defects**: a non-interactive
non-login shell sources no startup file, by POSIX and by zsh design. They are
recorded here because they are the easiest way to write a test that fails for the
wrong reason, and because they define a real operational limit: a `cron` entry or a
CI step that runs `sh -c 'npm install'` is **not** intercepted. The scenario must use
`-lc` or `-ic` exclusively, and `status`'s `path.*` footer must say which shell it
observed.

`dash` (`/bin/sh` on Ubuntu) does not accept `-l`; probe scripts must use
`bash -lc` or `su - <user> -c` instead.

Every lane runs as real root in the container, which is what makes
`apply --scope machine` testable at all without a VM.

### Scenario (`tests/docker/scenario.sh`)

Run once per lane, per shell. Steps, each asserting an exit code and specific output:

1. **Preconditions** — create two unprivileged users (`alice` UID 1001, `bob` UID
   1002) with real home directories; give `alice` a `~/.zshrc` and `~/.bashrc` that
   already contain `export PATH="$HOME/.local/bin:$PATH"` **and** a pre-existing
   comment line, to test both the shadowing case and content preservation.
2. `status` before install → expect exit `2`, verdict `action_required`, detail
   "not installed".
3. `apply --scope machine --mode soft` → expect exit `0`.
4. `status --scope machine --json` → expect exit `0` and `"verdict":"healthy"`.
5. **PATH precedence from a login shell** — the core assertion. For each shell:
   `su - alice -c '<shell> -lc "command -v npm"'` must print a path under
   `/opt/supply-gate/shims`, *despite* alice's own `export PATH=` running after the
   system rc files. For `zsh` this is what validates the `/etc/zlogin` prepend; for
   `bash` it validates the per-user `.bashrc` block written by
   `apply_user_configs_for_home`.
6. **Interception is real** — `su - alice -c 'zsh -lc "npm --version"'` produces a
   new line in `/opt/supply-gate/logs/events.jsonl` naming `npm`, and the per-user
   run log exists. Proves the wrapper ran and that a non-root user can write the
   `1777` log dir (regression coverage for the `chmod 1777` fix).
7. **Ownership** — `alice`'s `~/.npmrc`, `~/.zshrc`, `~/.config/pip/pip.conf` are
   owned by `alice`, not `root` (regression coverage for `append_managed_block`'s
   in-place rewrite and the `chown` in `apply_user_configs_for_home`).
8. **Content preservation** — alice's pre-existing comment line survived.
9. **Break, diagnose, repair** — for each of these, independently:
   | Sabotage | Expected `status` | After `repair` |
   |---|---|---|
   | `rm /opt/supply-gate/runtime/common.sh` | `1`, `runtime.common_present` fail, `repair_would_fix` contains it | `0` |
   | overwrite `runtime/common.sh` with older content | `1`, `runtime.common_current` fail | `0` |
   | `chmod 000 /opt/supply-gate/shims/npm` | `1`, `shim.present` fail | `0` |
   | strip alice's `.npmrc` managed block | `1`, `config.users` warn + fail path | `0` |
   | `touch /opt/supply-gate/runtime/binmap.conf` | `1`, `runtime.stale_binmap` fail | `0` |
   | `apply --mode hard` with placeholder registries | `2`, `mode.hard_registries` fail, `manual_required` non-empty | still `2` (proves `repair` is correctly *not* offered) |
10. **Uninstall** — `uninstall --scope all` → `status` exits `1`; `/etc/profile.d/supply-gate.sh`,
    `/etc/zlogin` block, `/opt/supply-gate`, and alice's blocks are all gone, while
    alice's pre-existing comment line still stands.

Step 9's last row is the one that validates the `1` vs `2` split — the entire reason
the verdict has three states.

### macOS: what containers can and cannot prove

Stated plainly, because the request asked about simulating macOS in Docker:

**A Linux container cannot run macOS.** Docker containers share the host kernel;
macOS binaries need the Darwin kernel. There is no legal or practical Docker image of
macOS, and Docker Desktop on a Mac runs a *Linux* VM, which does not help either.
Any claim of "macOS coverage" from a container lane is coverage of *our code paths*,
never of Darwin behaviour.

The `darwin-faked` lane makes that limited claim explicit. It places stubs early in
`PATH`:

| Stub | Returns | Exercises |
|---|---|---|
| `uname -s` | `Darwin` | `detect_platform` → `macos`, and therefore every `case "$PLATFORM"` branch |
| `dscl` | canned `-list /Users UniqueID` and `-read … NFSHomeDirectory` output | `list_local_users_macos`, and the `$HOME` fallback in `lib/common.sh` |
| `stat -f` | BSD-format output | the `-f` arm of `path_owner` (GNU `stat -f` prints filesystem info, which `path_owner` must reject — this lane proves the rejection works) |
| `sw_vers`, `sandbox-exec` | stubs | `AI_JAIL_BACKEND_MACOS` selection |
| `/var/root` | created as a directory | the macOS root-home branch in `apply_machine_cmd` / `audit_machine_cmd` |

### `path_helper`: resolved, and testable on Linux after all

The first draft of this SDD called the macOS `path_helper` hazard "the single
highest-value untested assumption in the tool". That was wrong — it **is** testable on
Ubuntu, because the startup-file *order* is compiled-in zsh semantics, identical on
macOS and Debian; only the directory differs (`/etc` vs `/etc/zsh`).

Measured with `zsh -o sourcetrace` in `ubuntu:24.04`, zsh 5.9 (the same version macOS
ships), with a simulated `path_helper` planted in `/etc/zsh/zprofile` that rebuilds
`PATH` from scratch, **and** alice's own prepend in `~/.zshrc`:

```
/etc/zsh/zshenv
/etc/zsh/zprofile     <- PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"  (path_helper sim)
/etc/zsh/zshrc        <- our block
/home/alice/.zshrc    <- alice's export PATH="$HOME/.local/bin:$PATH"
/etc/zsh/zlogin       <- our block, LAST
```

Resulting `PATH`: `/opt/supply-gate/shims:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`
— the shim dir wins. The `zlogin` prepend defeats both a full `PATH` rebuild and a
later user edit, which is exactly what it was written for.

Separately, forcing the macOS layout (`touch /etc/zshrc; rm -rf /etc/zsh`) confirmed
`apply_system_profiles` writes the block to **both** `/etc/zshrc` and `/etc/zlogin` —
the two files a macOS zsh actually reads — and does not recreate `/etc/zsh`. That is
the `macos-layout` lane in the matrix above.

So the mechanism is verified. What remains genuinely Darwin-only is narrower than the
first draft assumed.

What no container lane can prove, and which only a real Mac can:

- The real `/usr/libexec/path_helper` binary and the actual contents of `/etc/paths`
  and `/etc/paths.d` on a managed Mac (an MDM profile can add entries).
- SIP restrictions on `/etc` writes, and Ventura+ behaviour for `/etc/zshrc`.
- Whether macOS ships `/etc/zlogin` at all (it does not by default;
  `append_managed_block` creates it, and an absent-then-created system file is
  exactly the case `apply_system_profiles` handles by *not* gating on `[ -f ]` there
  — worth one real-Mac confirmation).
- Real `dscl` output format across macOS versions, mobile/AD accounts, and the
  `UniqueID` starting at 501.
- `installer -pkg` behaviour, the `.pkg` postinstall, and Gatekeeper/notarization.
- `sandbox-exec` actually confining anything.

Recommended follow-up, out of scope here: one manual run of `scenario.sh` on a real
Mac before any macOS fleet rollout, and eventually a `macos-14` CI runner. Recording
this as a known gap is more useful than a lane that implies coverage it lacks.

## Defect found while validating this SDD — NOT fixed here

The container run surfaced a real gap in existing code. It is recorded, not repaired,
because `apply_system_profiles` is on the frozen list and fixing it was not requested.

**`/etc/bashrc` is never written.** [lib/common.sh:538](../lib/common.sh#L538) iterates
`/etc/bash.bashrc /etc/zshrc /etc/zsh/zshrc`. `/etc/bash.bashrc` is the *Debian* name
for the system-wide bash rc; RHEL/Fedora/CentOS and macOS use **`/etc/bashrc`**.
Verified: with `/etc/bashrc` present, `apply --scope machine` leaves it untouched.

Impact is partial, not total, which is why it went unnoticed:

- login bash is still covered on those distros via `/etc/profile.d/supply-gate.sh`;
- non-login interactive bash is covered *only* by the per-user `~/.bashrc` block from
  `apply_user_configs_for_home`.

So a user is uncovered in non-login interactive bash on a RHEL-family box exactly when
their home was skipped by the per-user loop — no home directory, a UID outside
`[1000, 60000)`, or an account created *after* the last `apply`. That last case is the
realistic one on a shared build host.

`status` will **report** this (`config.system.rc` checks the same list, so it will not
flag a missing `/etc/bashrc` either — the check list must be extended to include it,
which is inside the Frozen Surface because `lib/checks.sh` is a new file). Actually
fixing `apply_system_profiles` needs its own one-line change and its own approval.

### Harness invariants

- No lane touches the developer's machine: everything runs inside a container, and
  `run-matrix.sh` refuses to run the scenario outside one (guard on
  `/.dockerenv` / `container` env, plus a `SCP_TEST_ALLOW_HOST=1` escape hatch).
  `scenario.sh` writes to `/etc` and `/opt` as root; running it on a real host would
  install the tool for real.
- Images install only `zsh` (+ `sudo`, `procps`) — no language runtimes. The scenario
  never needs a real `npm`; interception is proven with a **fake** `npm` placed in
  `/usr/local/bin`. This keeps images small, offline-buildable and fast, and removes
  the network from the assertion path.
- `run-matrix.sh` accepts a lane filter (`./run-matrix.sh debian alpine`) and prints
  a final matrix of lane × shell × result.
- Exit code: `0` only if every lane passed.

## Test Plan for `status` itself

### Unit (`tests/test_checks.sh`, POSIX `sh`, no container)

Sources `install.sh` with `_SCP_SOURCED=1` (the existing guard at `install.sh:868`
makes this safe — no dispatch runs) so real `lib/checks.sh` functions are tested, not
reimplementations. `INSTALL_ROOT_OVERRIDE` points `STATE_ROOT` at a temp tree.

| Test | Asserts |
|---|---|
| `check_verdict_healthy` | all `ok` → `healthy`, exit `0` |
| `check_verdict_degraded` | one `fail`/`repair` → `degraded`, exit `1` |
| `check_verdict_action_required` | one `fail`/`manual` → `action_required`, exit `2` |
| `check_verdict_mixed_prefers_manual` | `repair` + `manual` fails → exit `2` |
| `check_unknown_does_not_change_verdict` | `unknown` alongside all-`ok` → exit `0` |
| `check_not_installed_short_circuits` | absent `STATE_ROOT` → exit `2`, few checks, `fix=manual` |
| `check_record_strips_tabs` | tab/newline in `detail` does not corrupt the record list |
| `check_json_is_single_object` | `--json` output parses (via `python3 -c json.load` when available; otherwise a brace/quote balance check) |
| `check_json_has_required_keys` | `schema`, `verdict`, `exit_code`, `counts`, `checks` present |
| `check_hash_drift_detected` | installed `common.sh` mutated → `runtime.common_current` fail |
| `check_hash_unknown_without_source` | unreadable `$SCRIPT_DIR/lib/common.sh` → `unknown`, not `fail` |
| `check_stale_binmap_detected` | planted `binmap.conf` → fail |
| `check_shim_target_mismatch` | shim pointing at a different wrapper path → fail |
| `check_foreign_shim_detected` | a second dir on `PATH` with a `manager-wrapper.sh`-referencing file → warn |
| `check_path_effective_uses_content` | a shim reached via symlink from outside `SHIM_ROOT` still counts as managed |
| `check_soft_mode_skips_registry_checks` | soft mode → `mode.*` all `ok`/not-applicable |
| `check_hard_placeholder_is_manual` | `hard` + `*example.corp*` → fail with `fix=manual` |
| `check_jail_severity_by_mode` | no launcher → `fail` in hard, `warn` in soft |
| `check_evidence_probe_is_cleaned_up` | after the run, no `.status-probe.*` remains |
| `check_is_read_only` | snapshot every file under a fake `$HOME` + `$STATE_ROOT` (path, size, mtime, sha256) before and after a full `status` run; only `events.jsonl` may differ |
| `check_save_writes_only_with_flag` | `status-last.json` absent without `--save`, present with it |
| `check_rejects_scope_all` | exit `2` |

`check_is_read_only` is the test that enforces Goal 2 and is worth writing first.

### Integration

Covered by the container scenario (Part B, steps 2, 4, 9). No manual steps beyond
the recommended real-Mac run.

## Risks and open questions

| Risk | Mitigation |
|---|---|
| `status` duplicates predicates that `audit` also encodes (marker checks, placeholder detection), so a future policy change must be made in two places | accepted deliberately: the alternative is editing `audit`/`require_hard_value`, which the Frozen Surface forbids. Every duplicated predicate carries a comment naming its twin. A later SDD can extract them once both are stable |
| The report grows to ~45 lines and stops being read | grouped sections, rolled-up shim lines, and a verdict block that names the exact next command. `--json` for machines |
| `path.effective` false-positives right after `apply` (same shell) | explicit footer, and the check is `manual` with a hint that distinguishes "new shell needed" from "block shadowed" |
| Container lanes drift from real fleet images | lanes pin image tags; `ubuntu` lane additionally installs the built `.deb` so the packaged path is what runs |
| `darwin-faked` gives false confidence | documented above as code-path coverage only. The `path_helper` ordering and the `sysconfdir=/etc` layout are now covered by real measurements (`macos-layout` lane); what remains Darwin-only is listed explicitly, and a real-Mac run is still recommended before macOS rollout |
| Ubuntu's `apt` works behind this network's TLS interception but Fedora's `dnf` does not (self-signed cert in chain → `Curl error (60)`), so the `fedora` lane cannot build here | the `macos-layout` lane on `ubuntu:24.04` covers the same `sysconfdir=/etc` arm, so Fedora is not on the critical path. Keep the lane in the matrix but let `run-matrix.sh` report it as `skipped` rather than failed when metadata download fails |

Open questions for the operator:

1. Should `status` be the command KACE runs on a schedule (instead of `audit`)?
   `status --json` is the better ingestion format, but `audit` is what writes the
   compliance attestation. Current SDD assumes **both**: `audit` for attestation,
   `status --json --save` for diagnosis. Confirm before wiring anything into a
   scheduler.
2. Should `repair` gain a `--dry-run` that shows what it would change? Useful, but it
   edits `repair_cmd` — out of scope here, deliberately left as a separate proposal.


## Deltas from the proposal

Recorded because the shipped design differs from the draft above in ways a reader of
the original would not expect.

| Proposed | Shipped | Why |
|---|---|---|
| a separate `status` subcommand | folded into `status`, with `--full` for the per-check listing | two commands reporting on the same state can disagree; one engine (`lib/checks.sh`) cannot. `status` already existed and already meant "how is this host" |
| `--json` and `--save` | dropped | not wanted. `status --full` covers the human case; shell redirection covers the rest |
| `path.*` failures are `fail`/`manual` | `warn` when the config is on disk but this shell never sourced it; `fail`/`repair` only when the shim dir is in PATH and still shadowed, or when nothing on disk prepends it | measured in the container: a provisioning run (KACE, `.deb` postinst, CI) checks status in the same non-login shell that just ran `apply`, where the shim dir can never be in PATH. The draft's severity made every such run report `action_required` on a perfectly healthy host |
| `repair` unchanged (frozen) | `repair_cmd` parses `--scope` and infers machine scope | measured: `repair` after a machine-scope install reported "scope: user", exited 0, left `/opt/supply-gate` broken and created a second install under root's home. `repair --scope machine` ignored the flag entirely, because the dispatch called `repair_cmd` without `"$@"`. An exit 0 that repairs nothing is worse than a failure |
| `/etc/bashrc` gap recorded, not fixed | fixed in `apply_system_profiles` and `remove_system_profiles` | approved after the finding |
| `install.sh uninstall` only | plus a thin `uninstall.sh` that delegates to it | `install.sh uninstall` reads as a contradiction on screen. The subcommand stays because `build/deb/debian/prerm` calls it |

Two bugs in the check engine itself were caught by running it, not by reading it:

- `check_render_next_steps` printed the "Manual action required" header above an
  empty list. `$(...)` strips the trailing newline, so `read` hit EOF without a
  delimiter, returned non-zero, and the loop body never ran. Fixed with `printf '%s\n'`.
- Scope inference was gated on `id -u = 0`, so an unprivileged user on a
  machine-scope host was told "not installed". It now prefers a user-scope install
  when one exists and falls back to the machine layer, with no root requirement —
  `/opt/supply-gate` is `755` and readable.

### Verification

`sh tests/run.sh` — 60 assertions across `tests/test_machine_scope.sh` (27,
pre-existing, unchanged) and `tests/test_checks.sh` (33, new), including a read-only
contract test that sha256-snapshots the whole state tree before and after a full
check run.

`sh tests/docker/run.sh` — 40 end-to-end assertions per lane across three lanes
(`ubuntu:24.04`, `debian:12`, and `macos-layout`, which forces the `sysconfdir=/etc`
layout macOS uses), as real root with real `/etc` files and real login shells. All
120 pass.
