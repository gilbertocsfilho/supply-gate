# Supply Gate

Supply Gate is a local hardening layer for developer workstations and automation environments. It helps enforce safer dependency installation and AI CLI usage with a policy-driven workflow.

Use it when you want to reduce common supply chain bypass paths such as:

- direct package manager usage outside policy
- inconsistent local configuration across machines
- missing audit trail for installs and updates
- AI CLI execution without a configured sandbox or jail

## What It Does

- Applies local policy in `soft` or `hard` mode
- Wraps supported package managers and AI CLIs
- Records local audit evidence and execution logs
- Supports optional local tooling such as `scfw` and `bumblebee` without making them mandatory

Supported commands today:

- `npm`
- `pnpm`
- `yarn`
- `bun`
- `pip`
- `pip3`
- `uv`
- `poetry`
- `cargo`
- `go`
- `claude`
- `gemini`
- `codex`
- `agy` (Antigravity Code)

## Operating Modes

### `soft`

Use `soft` mode when you want local enforcement without requiring corporate registries or proxies.

### `hard`

Use `hard` mode when you want local enforcement plus mandatory corporate registries or proxies. This mode is intended for environments that already have those services available.

## Quick Start

Apply the default local policy:

```sh
./install.sh apply --mode soft
```

Reload your shell, then verify:

```sh
source ~/.zshrc
./install.sh audit
```

If you want `hard` mode, first customize the policy values and then apply:

```sh
./install.sh apply --mode hard
```

## Common Commands

Apply:

```sh
./install.sh apply --mode soft
```

Check integrity:

```sh
./install.sh status
```

Audit:

```sh
./install.sh audit
```

Repair:

```sh
./install.sh repair
```

Uninstall:

```sh
./uninstall.sh
```

## Checking Integrity

`status` is a read-only report: it never changes configuration. Run it whenever you
want to know whether this machine is still enforcing policy.

```sh
./install.sh status            # one line per section
./install.sh status --full     # every individual check
```

Exit codes tell you what to do next:

| Exit | Meaning | Next step |
|---|---|---|
| `0` | healthy | nothing |
| `1` | degraded | `./install.sh repair` (the report lists what it will fix) |
| `2` | manual action required, or not installed | the report names each item |

The split matters: `repair` re-runs `apply`, so it fixes drifted files, missing
blocks and stale shims. It cannot fix a placeholder registry URL in `hard` mode, a
missing AI jail launcher, or a `PATH` that a later edit in your own shell rc
shadows — those are reported as manual, with the specific action.

`status` checks things `audit` does not, notably:

- whether the installed runtime still **matches** what shipped (`audit` only checks
  that the files exist, so an edited `common.sh` passes it)
- whether the shim directory actually wins in `PATH`, resolved by file content
- whether the log directory is writable — when it is not, logging silently falls
  back to `/dev/null` and the machine produces no audit evidence at all

Scope is inferred: with no `--scope`, a user-scope install is preferred, falling back
to the machine-wide layer. Pass `--scope machine` to be explicit.

## Tests

Safe on any machine:

```sh
sh tests/run.sh                        # unit tests, temp dirs only
powershell.exe -File tests/windows/run.ps1   # the same, on Windows
```

Destructive — they install Supply Gate for real, so they refuse to start unless
told the host is disposable (a CI runner, a VM):

```sh
sh tests/docker/run.sh     # end-to-end in throwaway containers (needs docker)
sh tests/hard/run.sh       # hard mode against the real proxy stack (needs docker + root)
sudo env HOME=/var/root SCP_TEST_ALLOW_DESTRUCTIVE=1 sh tests/macos/scenario.sh
powershell.exe -File tests/windows/e2e.ps1   # set SCP_TEST_ALLOW_DESTRUCTIVE=1
```

The container lanes install for real as root, across `ubuntu:24.04`, `debian:12`, and
a `macos-layout` lane that forces the `sysconfdir=/etc` file layout macOS uses. They
assert `PATH` interception from real login and interactive shells, in both `bash` and
`zsh`. The repo is mounted read-only, and `tests/docker/scenario.sh` refuses to run
outside a container.

Containers cannot run macOS — a Linux kernel cannot execute Darwin binaries — so
`tests/macos/scenario.sh` runs the same shape of scenario on a real Mac instead, and
covers what the `macos-layout` lane structurally cannot: `dscl` user enumeration
(macOS keeps login accounts out of `/etc/passwd`), `/var/root` instead of `/root`,
BSD userland, and a `zsh` that really reads `/etc/zlogin`.

`tests/hard/run.sh` is the only lane that tests hard mode end to end. Soft mode needs
no upstream services, so every other lane passes with the registries unreachable —
hard mode is precisely the mode that cannot. It brings [compose.yaml](compose.yaml)
up (verdaccio, devpi, athens and kellnr behind nginx), maps the four corporate
hostnames at `127.0.0.1`, applies `--mode hard`, then makes `npm`, `pip` and `go`
actually fetch a package and reads the requests back out of nginx's per-vhost access
log. It also asserts hard mode's fail-closed behaviour: AI CLIs blocked until a jail
launcher is configured, and the wrapper refusing to run at all once a placeholder
registry reappears in policy.

### Continuous integration

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs all of it on free
GitHub-hosted runners — one real machine per platform:

| Job | Runner | What it covers |
|---|---|---|
| `unit (ubuntu-latest)` / `unit (macos-latest)` | Linux, macOS | `tests/run.sh` |
| `unit (windows-latest)` | Windows | `tests/windows/run.ps1`, on Windows PowerShell 5.1 |
| `e2e linux (throwaway containers)` | Linux | `tests/docker/run.sh` |
| `e2e macos (runner VM)` | macOS | real root install on Darwin |
| `e2e windows (runner VM)` | Windows | real user-scope install, real persisted `PATH` |
| `hard mode (docker proxy stack)` | Linux | hard mode against live proxies |

## Distributing to a Fleet

For rolling out to many machines (KACE or similar), build a versioned
native package instead of pushing a repo checkout: see
[build/README.md](build/README.md) for `.deb` (Linux) and `.pkg`/`.dmg`
(macOS) build scripts.

## Local Policy Overrides

Keep shared defaults in [policy/default-policy.conf](policy/default-policy.conf).

For machine-specific settings, create a local override file that is ignored by git:

```sh
cp policy/local-policy.example.conf policy/local-policy.conf
```

Typical local overrides include:

- `AI_JAIL_LAUNCHER_LINUX` / `AI_JAIL_LAUNCHER_MACOS` (set only the one matching this machine's OS)
- internal registry URLs for `hard` mode
- machine-specific install or config roots

## Optional Tools

Optional tools are intentionally kept outside `apply`.

Install all supported optional tools:

```sh
./install.sh install-optional-tools --all
```

Or install them individually:

```sh
./install.sh install-optional-tools --scfw
./install.sh install-optional-tools --bumblebee
```

Current behavior:

- `scfw` is installed via `pipx` when supported
- `bumblebee` is installed via `go install github.com/perplexityai/bumblebee/cmd/bumblebee@v0.1.1`
- Windows is handled as `skip` for tools whose upstream support is not available
- missing optional tools do not block `apply`, `audit`, or `repair`

If `bumblebee` installation fails, verify your Go version first. The current upstream install path requires Go 1.25 or newer.

## Working With `scfw` And `bumblebee`

Use the three layers together, but with different roles:

- `Supply Gate`: local enforcement and audit trail
- `scfw`: install-time package screening
- `bumblebee`: endpoint inventory and exposure scan

The expected workflow is layered, not a single combined command.

### Daily Dependency Workflow

1. Keep `Supply Gate` applied on the machine.
2. Run dependency installs through `scfw`.
3. Let `Supply Gate` intercept the underlying package manager.
4. Use `bumblebee` separately for periodic inventory or incident response.

Example:

```sh
scfw run npm install lodash
scfw run pip install requests
```

In this flow:

- `scfw` evaluates the package before or during installation
- `Supply Gate` still governs the package manager call that actually runs
- logs and local enforcement remain with `Supply Gate`

### Transparent `scfw` Layer

If `scfw` is installed, `Supply Gate` can invoke it transparently for supported install flows.

Current default behavior:

- enabled by `SCFW_AUTO_WRAP="1"`
- active for `npm`, `pip`, `pip3`, and `poetry`
- only applied to install-like commands

Examples that are transparently routed through `scfw` when available:

```sh
npm install lodash
pip install requests
poetry add requests
```

Commands outside that scope still run directly through the normal `Supply Gate` wrapper path.

If you want to disable transparent `scfw` wrapping, set this in `policy/local-policy.conf`:

```sh
SCFW_AUTO_WRAP="0"
```

### Practical Usage Pattern

Baseline the machine:

```sh
./install.sh apply --mode soft
./install.sh audit
```

Install dependencies with screening:

```sh
scfw run npm install <package>
scfw run pip install <package>
```

Run local compliance checks:

```sh
./install.sh audit
```

Run periodic endpoint visibility scans:

```sh
bumblebee --help
```

### Recommended Team Workflow

- Day-to-day installs: use `scfw run ...`
- Local enforcement: keep `Supply Gate` active on the workstation
- Drift checks: run `./install.sh audit`
- Incident response or exposure hunting: run `bumblebee` scans outside the install flow

### Important Boundaries

- Do not make `bumblebee` part of `apply`, `audit`, or `repair`
- Do not treat `bumblebee` as an inline enforcement tool
- Do not assume `scfw` replaces local wrapper enforcement
- Do not bypass `Supply Gate` by calling package managers outside the managed `PATH`

## AI CLI Sandboxing

`claude`, `gemini`, and `codex` are treated as sensitive commands.

If no launcher is configured for the active AI jail backend, those commands are blocked by design. For local machine overrides, prefer setting the launcher in `policy/local-policy.conf`.

## Recommended Rollout

1. Start with `soft` mode on a local machine.
2. Validate wrappers, logs, and `./install.sh audit`.
3. Configure local jail settings for AI CLIs.
4. Add internal registries or proxies if you plan to use `hard` mode.
5. Roll out `hard` mode only after those upstream services are operational.

## Project Scope

Supply Gate focuses on local prevention and enforcement.

It does not try to replace:

- corporate dependency proxies
- central telemetry or SIEM
- endpoint inventory tools
- exposure hunting or incident-wide discovery workflows

For broader guidance and deployment patterns, see:

- [GUIDE.md](GUIDE.md)
- [docs/internal-proxies.md](docs/internal-proxies.md)
- [docs/prescriptive-proxy-stack.md](docs/prescriptive-proxy-stack.md)
- [docker/README.md](docker/README.md)
