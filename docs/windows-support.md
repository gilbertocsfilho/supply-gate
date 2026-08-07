# Windows Support: Native PowerShell Installer

## Problem

Supply Gate's enforcement (PATH interception, package-manager hardening, AI
jail, audit trail) previously had no native Windows path. `install.sh` only
touched Windows indirectly: `scripts/windows-apply.ps1` is shelled out to via
`powershell.exe` from a POSIX shell (WSL, Git Bash, Cygwin) purely to prepend
the shim dir to the user's PATH and PowerShell profile — there was no MSI, no
`.cmd`/PowerShell-native equivalent of `install.sh apply|status|audit|repair|
uninstall`, and no interception for `cmd.exe`.

This doc covers the native port added to close that gap: `install.ps1` /
`uninstall.ps1` at the repo root, `lib/windows/`, `shims/windows/`, and
`tests/windows/`. `scripts/windows-apply.ps1` is unchanged and still serves
its original WSL/Git-Bash bridging role — it is a different entry path, not
superseded by this work.

## Goals

1. `install.ps1 apply|audit|repair|status|uninstall` with the same
   `-Scope user|machine`, `-Mode soft|hard` contract as `install.sh`, runnable
   from plain `cmd.exe` or PowerShell with nothing extra to install.
2. PATH interception that works from both `cmd.exe` and PowerShell.
3. Feature parity on package-manager hardening (npm/bun/pip/cargo/go) and the
   AI jail wrapper logic (bypass, re-entrancy guard, fail-open/fail-closed by
   mode) — same policy file, same event log format.
4. A test suite that runs on any Windows box with nothing extra installed
   (mirrors `tests/run.sh`'s "any box already has what this needs" property),
   validated for real against Windows PowerShell 5.1 via WSL interop during
   development.

## Non-Goals (this pass)

- `scfw` auto-wrap delegation in the wrapper (upstream has no Windows build;
  `install.sh` already treats `scfw`/`bumblebee` as unsupported on Windows).
- Domain-joined / roaming-profile edge cases in local-user enumeration.

Two items that used to be listed here — MSI packaging and full end-to-end
install testing against a real machine — are done; see "Real end-to-end
testing" and "Windows installer (`build/windows/`)" below.

## Architecture

Same shape as the POSIX side, one file per POSIX counterpart:

| POSIX | Windows | Role |
|---|---|---|
| `install.sh` | `install.ps1` | CLI entry point, subcommand dispatch |
| `uninstall.sh` | `uninstall.ps1` | thin delegator to `install.ps1 uninstall` |
| `lib/common.sh` | `lib/windows/SupplyGate.Common.psm1` | paths, markers, logging, policy, package-manager config |
| `lib/checks.sh` | `lib/windows/SupplyGate.Checks.psm1` | `status` integrity checks, verdict/exit-code logic |
| `shims/manager-wrapper.sh` | `shims/windows/manager-wrapper.ps1` | the PATH-intercepted wrapper every managed tool actually runs through |
| `tests/*.sh` + `tests/docker/` | `tests/windows/*.ps1` | unit tests (temp dirs only; no e2e lane yet) |

The installed runtime copy under `<StateRoot>\runtime\` is what shims
actually call (`Copy-Item` at apply time, same as `install_runtime` in
`install.sh`) — not the repo checkout — so an installed host keeps working
even if the repo directory moves or is deleted.

### Path/registry mapping

| Concept | POSIX | Windows |
|---|---|---|
| User state root | `~/.local/share/supply-chain-protect` | `%LOCALAPPDATA%\SupplyChainProtect` |
| Machine state root | `/opt/supply-gate` | `%ProgramData%\supply-gate` |
| PATH mechanism | prepend in `.profile`/`.bashrc`/`.zshrc` + `/etc/profile.d` | `[Environment]::SetEnvironmentVariable('Path', ..., 'User'|'Machine')` |
| Shell startup hook | dotfiles sourced by bash/zsh | PowerShell `$PROFILE.CurrentUserAllHosts` / AllUsersAllHosts `profile.ps1` (PATH itself needs no hook — see below) |
| npm config | `~/.npmrc` | `%USERPROFILE%\.npmrc` |
| pip config | `~/.config/pip/pip.conf` (XDG) | `%APPDATA%\pip\pip.ini` (pip's actual native default — not an XDG-style path) |
| cargo config | `~/.cargo/config.toml` | `%USERPROFILE%\.cargo\config.toml` |
| Local user enumeration | `/etc/passwd` (Linux) / `dscl` (macOS) | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` |
| Runtime/status state | `state.conf` / `status.env` (shell-sourced) | `state.json` / `status.json` |
| Shim | executable shell script, `exec`'d | `<tool>.cmd` batch stub calling `manager-wrapper.ps1` |

**`cmd.exe` needs no rc-file/profile mechanism at all** — unlike bash/zsh,
command resolution is PATH-only, so once the shim dir is in the persisted
`Path` env var, a new `cmd.exe` window picks it up with nothing else to
write. The PowerShell profile snippet (`<StateRoot>\runtime\profile.ps1`,
dot-sourced from `$PROFILE`) exists only to (a) refresh `$env:Path` inside
sessions that were already open, and (b) host the `<tool>-nojail`
convenience functions — the equivalent of `write_profile_snippet`'s
`$tool-nojail()` in `install.sh`.

### The `param()` binding trap (read this before touching the wrapper)

`shims/windows/manager-wrapper.ps1` deliberately declares **no** `param()`
block. A first version did `param([Parameter(Position=0)][string]$Tool)`,
reasoning that a *non-advanced* script (no `[CmdletBinding()]`) sweeps extra
positional arguments into the automatic `$args` variable the way shell
functions do with `"$@"` after `shift`. That reasoning is wrong on both
Windows PowerShell 5.1 and PowerShell 7: **any** declared `param()` block
enables strict positional binding, and extra args past it are a hard error
("A positional parameter cannot be found that accepts argument '...'").
`$args` is only populated when a script has **zero** declared parameters.
`tests/windows/test_wrapper.ps1` caught this by actually invoking the shim
chain (`cmd.exe` → `manager-wrapper.ps1` → fake real binary) instead of only
reasoning about it — the wrapper reads `$Tool = $args[0]` and slices the rest
into `$ToolArgs` by hand.

The second bug that same test caught: `$rc = Invoke-SomeFunction` where the
function's last statement is `& $realBin @ToolArgs` — a PowerShell function's
"return value" is its entire success-stream output, which includes whatever
the wrapped native command printed to stdout. Capturing that into `$rc`
silently produces a mixed string/int array (`if ($rc -eq 0)` then does an
element-wise comparison instead of the intended scalar check). Fix: call the
function bare (so its output, including the wrapped command's real stdout,
flows straight to the console as intended) and read `$LASTEXITCODE`
separately afterward — PowerShell function calls never reset it, so it still
reflects the last native process that ran, several call frames deep.

Both are exactly the kind of bug that only shows up by actually running the
chain, not by reading the script — the reason `test_wrapper.ps1` exists as
its own test file instead of folding into `test_common.ps1`.

## Testing model

Three temp-dir-only PowerShell test files, run with
`powershell.exe -File tests/windows/run.ps1` (also works under `pwsh`, though
that wasn't available on the dev machine used to validate this — no PS7-only
syntax is used, so it should just work; treat it as unverified until
confirmed):

- `test_common.ps1` — policy parsing, managed-block add/remove/idempotency,
  state-path resolution, hard-value placeholder detection, real-binary
  resolution (skips our own shim by content), package-manager config
  generation in both modes, runtime-state/status round-trips, JSON event
  shape.
- `test_checks.ps1` — verdict/exit-code logic (`healthy`/`degraded`/
  `action_required` → 0/1/2), hash-drift detection, missing-shim detection,
  hard-mode placeholder-registry fail-closed behavior.
- `test_wrapper.ps1` — the actual shim chain end to end: a `.cmd` shim
  invokes `manager-wrapper.ps1`, which resolves and calls a **fake** real
  binary (no network, no real npm needed — same trick
  `tests/docker/scenario.sh` uses on the POSIX side) with a *temporary*
  `$env:Path` override scoped to that one child process. Verifies args pass
  through intact, the JSONL event is written and attributed to the real
  user, and exit codes propagate correctly.

**What none of these touch:** the real registry `Path` (User or Machine),
the real `$PROFILE`, or `C:\ProgramData`. `Test-SupplyGateShimPath` and
`Test-SupplyGateConfig` in the checks module read real per-user state by
design (mirrors `lib/checks.sh`'s `check_path`/`check_config` reading the
real `$HOME`) and so are only exercised in isolation with controlled
fixtures, never via a full `Invoke-SupplyGateStatusRun` asserted "healthy" —
see "Real end-to-end testing" below for that.

## Real end-to-end testing

Done for real against a live Windows Server 2019 (build 17763, PowerShell
5.1) box over SSH — not a container, not WSL interop, an actual separate
machine with `apply`/`status`/`audit`/`repair`/`uninstall` run for real at
both `-Scope user` and `-Scope machine`, plus the installer (below) run as a
genuine silent install/uninstall. This is what `tests/docker/run.sh` gives
the POSIX side and what this doc used to list as unavailable ("no Windows
container runtime in this repo's dev environment"); a real Windows host,
even a temporary one reached over SSH, closes the same gap without needing
a container.

Covered: `apply` in soft and hard mode at both scopes; `status`/`audit`
verdict and exit codes (`healthy`/`degraded`/`action_required` → 0/1/2)
under a clean install, injected drift (tampering the installed runtime
copy), and unmet hard-mode prereqs; `repair` clearing drift back to
healthy; a real shim (`npm.cmd`) resolved off the live `PATH`, intercepting
a fake real `npm.cmd` placed alongside it, with the JSONL event log
verified end to end; `uninstall` at both scopes leaving no state root, no
managed-block markers (while preserving the user's own surrounding content
in `.npmrc`/etc.), and no shim directory on `PATH`.

**Two real bugs found this way** (both invisible from reading the code —
each only shows up by actually running the chain, the same lesson
"The `param()` binding trap" above draws from `test_wrapper.ps1`):

1. **`install.ps1 status` always exited 0 and printed nothing**, regardless
   of actual health. `Invoke-StatusSubcommand` did
   `$exitCode = Invoke-SupplyGateStatusRun ...; exit $exitCode` — but
   `Show-SupplyGateStatusReport` (called deeper, uncaptured) wrote the
   human-readable report via `Write-Output`, so *all of that report text*
   plus the trailing exit code flowed into `Invoke-SupplyGateStatusRun`'s
   own return value, making `$exitCode` an `Object[]` instead of an `Int32`.
   `exit` given an array silently coerces to `0` in Windows PowerShell —
   no error, no warning, just the wrong exit code and a swallowed report.
   Same root cause the wrapper section above already documents for a
   different function ("a PowerShell function's return value is its entire
   success-stream output"), just not yet fixed here when this doc was
   written. Fixed by switching `Show-SupplyGateStatusReport`'s `Write-Output`
   calls to `Write-Host` (bypasses the success/pipeline stream entirely, so
   it can't be captured into a variable by accident) in
   `lib/windows/SupplyGate.Checks.psm1`.
2. **The MSI/EXE installer test surfaced a WOW64 PowerShell bitness trap.**
   Both the WiX/MSI prototype and the first NSIS draft invoked PowerShell
   from a 32-bit installer process. Windows silently redirects a 32-bit
   process's view of `System32` to `SysWOW64`, so `powershell.exe` launched
   that way is the *32-bit* PowerShell — which then resolves its own
   `$PSHOME`/AllUsersAllHosts profile path under `SysWOW64\WindowsPowerShell`
   instead of the real `System32\WindowsPowerShell`. `apply -Scope machine`
   completed with no error, but silently wrote the machine-wide profile
   snippet to a PowerShell home nothing actually uses, leaving `status`
   `degraded` immediately after a "successful" apply. MSI's
   `[SystemFolder]` token has the exact same 32-bit-view behavior; the fix
   there was `[System64Folder]`. NSIS has no equivalent token, so
   `build/windows/supply-gate.nsi` resolves the `Sysnative` alias instead
   (see the comment in that file) — the standard WOW64 escape hatch for a
   32-bit process to reach the real 64-bit `System32`.

Not yet run for real: a genuine multi-user machine (`Get-SupplyGateLocalUsers`
looping real distinct local profiles) and a domain-joined host. Still true,
as noted above: `install-optional-tools`'s no-op stub, and any behavior
gated on `pwsh`/PowerShell 7 (not installed on the test box either).

## Windows installer (`build/windows/`)

`build/windows/build-installer.sh` + `build/windows/supply-gate.nsi` build
`build/windows/dist/SupplyGate-<VERSION>-setup.exe`, a single self-contained
installer via [NSIS](https://nsis.sourceforge.io/) (`makensis`) — no
MSI/WiX/dotnet toolchain, and the compiler itself runs identically on Linux
or Windows (`sudo apt-get install nsis`), so building doesn't require a
Windows host at all. Same payload and hook contract as `build/deb` and
`build/macos`: `install.ps1`, `uninstall.ps1`, `lib/windows/`,
`shims/windows/`, `policy/default-policy.conf`, `README.md`, `GUIDE.md`,
`VERSION`; installing runs `install.ps1 apply -Scope machine` and aborts
loudly if it fails (same "don't swallow the error" reasoning as
`debian/postinst`); uninstalling runs `install.ps1 uninstall -Scope machine`
before removing files (best-effort, matching `debian/prerm`).

```sh
./build/windows/build-installer.sh    # -> build/windows/dist/SupplyGate-0.1.1-setup.exe
```

```powershell
# On the target machine, elevated:
.\SupplyGate-0.1.1-setup.exe /S              # silent install, soft mode
.\SupplyGate-0.1.1-setup.exe /S /MODE=hard   # silent install, hard mode
"C:\Program Files\Supply Gate\Uninstall-SupplyGate.exe" /S   # silent uninstall
```

No wizard pages are authored on purpose — even a non-silent double-click
installer/uninstaller here shows only the built-in progress window, no
clicking through. Registers a normal Add/Remove Programs entry
(`HKLM\...\Uninstall\SupplyGate`, written via `SetRegView 64` so it lands in
the real 64-bit registry view, not `WOW6432Node`).

A subtlety worth knowing if this script is ever touched: a MessageBox shown
on an apply failure uses `/SD IDOK` specifically so a silent (`/S`) install
that hits a real failure (e.g. hard mode without registry URLs configured)
fails fast instead of hanging forever waiting for a click nobody can give it
— confirmed by actually triggering that failure path under `/S` during
testing; without `/SD IDOK` the installer process hangs indefinitely.

**MSI was tried first and abandoned.** A WiX v5 `.wxs` (the toolchain this
doc previously recommended) got as far as compiling and installing
correctly, but WiX's own CLI only reliably runs on Windows — building it
from this repo's Linux dev environment hit real cross-platform bugs (even a
minimal single-`Directory` source file failed) — and once building was
moved to a Windows host, the underlying WOW64 PowerShell bitness trap above
still had to be found and fixed either way. Given the choice, NSIS was kept
for the simpler, dependency-free, cross-platform build.

## What's not done yet

- Machine-scope per-user package config currently loops every local profile
  found in the `ProfileList` registry key with no root/non-root-style split
  (Windows has no real analog of that distinction) — fine for a single
  workstation, untested against a domain controller's idea of "local user."
- `install-optional-tools` is a no-op stub (matches `install.sh`, which
  already treats `scfw`/`bumblebee` as Windows-unsupported).
- The installer has no major-upgrade/version-detection logic (reinstalling
  over an existing install just overwrites files and reruns `apply`, which
  is idempotent — confirmed by testing — but there's no "newer version
  already installed" guard some MSIs provide).

## Maintenance: keeping the two sides in sync

There is no shared source of truth between `install.sh`+`lib/*.sh` and
`install.ps1`+`lib/windows/*.psm1` — this is a **parallel port**, not a
codegen target. When policy semantics change on one side (a new managed
command, a new check, a new AI-jail behavior), the other side needs the
change applied by hand. Concretely, when editing:

- **`policy/default-policy.conf`**: no action needed — both sides read the
  same file. New keys just need `Read-SupplyGatePolicyFile` in
  `SupplyGate.Common.psm1` to see them (it parses generically), but any
  *new list-typed key* (like `MANAGED_COMMANDS`) needs adding to the
  `foreach ($listKey in ...)` loop in `Initialize-SupplyGatePolicy` to get a
  `_LIST` array form.
- **`lib/common.sh`**: check whether the same primitive needs a
  `SupplyGate.Common.psm1` counterpart. Not everything does — POSIX-specific
  concepts (setgid bits, `/etc/passwd` parsing, zsh's `/etc/zlogin` quirk)
  have no Windows equivalent and shouldn't get one.
- **`lib/checks.sh`**: add the matching `Test-SupplyGate*` function to
  `SupplyGate.Checks.psm1` and wire it into `Invoke-SupplyGateStatusRun`.
- **`shims/manager-wrapper.sh`**: add the matching branch to
  `manager-wrapper.ps1`, and re-read "The `param()` binding trap" above
  before touching argument handling.
- **Tests**: `tests/*.sh` additions get a `tests/windows/test_*.ps1`
  counterpart; run `tests/windows/run.ps1` for real (Windows PowerShell 5.1
  is on every Windows box, so there's no excuse to skip this the way there'd
  be no excuse to skip `sh tests/run.sh` before a POSIX-side change).
