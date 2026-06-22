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
./install.sh uninstall
```

## Local Policy Overrides

Keep shared defaults in [policy/default-policy.conf](policy/default-policy.conf).

For machine-specific settings, create a local override file that is ignored by git:

```sh
cp policy/local-policy.example.conf policy/local-policy.conf
```

Typical local overrides include:

- `AI_JAIL_LAUNCHER_MACLINUX`
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
