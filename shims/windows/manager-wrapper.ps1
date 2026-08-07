# Installed to <StateRoot>\runtime\manager-wrapper.ps1 and invoked by every
# <tool>.cmd shim as: powershell.exe -NoProfile -ExecutionPolicy Bypass
#   -File manager-wrapper.ps1 <tool> <args...>
#
# PowerShell port of shims/manager-wrapper.sh. Deliberately has NO param()
# block: even without [CmdletBinding()], a declared param() still binds
# positional arguments strictly in both Windows PowerShell 5.1 and
# PowerShell 7 -- extra args past the declared ones are a binding error
# ("positional parameter cannot be found"), not swept into $args as a naive
# reading of "simple functions collect extras into $args" would suggest.
# That only holds with zero declared parameters. So $Tool is read as
# $args[0] and the rest is sliced off by hand below -- the equivalent of
# "$@" after `shift` in the shell version.

$ErrorActionPreference = 'Stop'
if ($args.Count -lt 1) {
    Write-Error 'Usage: manager-wrapper.ps1 <tool> [args...]'
    exit 2
}
$Tool = $args[0]
$ToolArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir 'SupplyGate.Common.psm1') -Force

# The installed runtime's own location IS the state root (parent of
# runtime\) -- mirrors lib/common.sh deriving STATE_ROOT from CALLER_DIR when
# basename(CALLER_DIR) is "runtime", so a machine-scope wrapper resolves
# ProgramData\supply-gate correctly regardless of the invoking user's HOME.
$StateRoot = Split-Path -Parent $ScriptDir
Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ScriptDir 'policy.conf') -StateRootOverride $StateRoot
Import-SupplyGateRuntimeState | Out-Null
Initialize-SupplyGateLog -Context "exec-$Tool"

$commandText = ("$Tool " + ($ToolArgs -join ' ')).TrimEnd()
Write-SupplyGateInfo "Intercepted command: $commandText"
Write-SupplyGateJsonEvent -Level INFO -Event 'command.intercepted' -Tool $Tool -Command $commandText -Status started -Detail 'wrapper invoked'

# Resolved live on every invocation (not cached at apply time), same as
# resolve_real_binary: a tool installed after the last apply is picked up
# immediately, and is_managed_shim-style content checks keep this from ever
# resolving back to our own shim even with multiple shim dirs on PATH.
$realBin = Find-SupplyGateRealBinary -Tool $Tool
if (-not $realBin) {
    Write-SupplyGateErr "Real binary not found on PATH for $Tool"
    Write-SupplyGateJsonEvent -Level ERROR -Event 'command.blocked' -Tool $Tool -Command $commandText -Status blocked -Detail 'no real binary found on PATH'
    exit 1
}

if (($Tool -eq 'pip' -or $Tool -eq 'pip3') -and $env:VIRTUAL_ENV) {
    $venvCandidate = Join-Path $env:VIRTUAL_ENV "Scripts\$Tool.exe"
    if (Test-Path -LiteralPath $venvCandidate) { $realBin = $venvCandidate }
}

$mode = Get-SupplyGateMode
if ($mode -ne 'soft' -and $mode -ne 'hard') {
    Write-SupplyGateErr "Unsupported enforcement mode: $mode"
    Write-SupplyGateJsonEvent -Level ERROR -Event 'command.blocked' -Tool $Tool -Command $commandText -Status blocked -Detail 'invalid mode'
    exit 1
}

if ($mode -eq 'hard') {
    $policy = Get-SupplyGatePolicy
    $prereqOk = $true
    $prereqOk = (Assert-SupplyGateHardValue -Name 'NPM_REGISTRY_URL' -Value $policy['NPM_REGISTRY_URL']) -and $prereqOk
    $prereqOk = (Assert-SupplyGateHardValue -Name 'PYTHON_INDEX_URL' -Value $policy['PYTHON_INDEX_URL']) -and $prereqOk
    $prereqOk = (Assert-SupplyGateHardValue -Name 'CARGO_REGISTRY_URL' -Value $policy['CARGO_REGISTRY_URL']) -and $prereqOk
    $prereqOk = (Assert-SupplyGateHardValue -Name 'GO_PROXY_URL' -Value $policy['GO_PROXY_URL']) -and $prereqOk
    if (-not $prereqOk) { exit 1 }
}

function Invoke-SupplyGateAiTool {
    if ($env:SCP_AI_JAIL_BYPASS -eq '1') {
        Write-SupplyGateWarn "AI jail bypass forced via SCP_AI_JAIL_BYPASS=1; running $Tool unjailed"
        Write-SupplyGateJsonEvent -Level WARN -Event 'command.allowed' -Tool $Tool -Command $commandText -Status started -Detail 'ai jail bypass forced'
        & $realBin @ToolArgs
        return
    }
    # Re-entrancy guard: our own launcher re-invokes the shim with
    # SCP_IN_AIJAIL=1, and a user-run jail (`ai-jail claude`) sets it too.
    # Without this, claude -> shim -> launcher -> jailed claude -> shim
    # recurses forever. Mirrors the guard in shims/manager-wrapper.sh.
    if ($env:SCP_IN_AIJAIL -eq '1') {
        Write-SupplyGateInfo "Already inside AI jail; delegating to real binary: $realBin"
        Write-SupplyGateJsonEvent -Level INFO -Event 'command.allowed' -Tool $Tool -Command $commandText -Status started -Detail 'already jailed'
        & $realBin @ToolArgs
        return
    }

    $policy = Get-SupplyGatePolicy
    $launcher = $policy['AI_JAIL_LAUNCHER_WINDOWS']
    $backend = $policy['AI_JAIL_BACKEND_WINDOWS']

    if (-not $launcher -or -not (Test-Path -LiteralPath $launcher)) {
        # Fail-closed in hard mode, fail-open (warn) in soft mode -- same
        # split as run_ai_tool in the POSIX wrapper.
        if ($mode -eq 'hard') {
            Write-SupplyGateErr "AI jail launcher missing for $Tool on windows (hard mode blocks)"
            Write-SupplyGateJsonEvent -Level ERROR -Event 'command.blocked' -Tool $Tool -Command $commandText -Status blocked -Detail 'missing ai jail launcher'
            exit 1
        }
        Write-SupplyGateWarn "AI jail launcher missing for $Tool on windows; running unjailed (soft mode)"
        Write-SupplyGateJsonEvent -Level WARN -Event 'command.allowed' -Tool $Tool -Command $commandText -Status started -Detail 'ai jail unavailable, unjailed in soft mode'
        & $realBin @ToolArgs
        return
    }

    Write-SupplyGateInfo "Launching $Tool through jail backend: $backend"
    Write-SupplyGateJsonEvent -Level INFO -Event 'command.jailed' -Tool $Tool -Command $commandText -Status started -Detail $backend
    $env:SCP_IN_AIJAIL = '1'
    try {
        & $launcher $realBin @ToolArgs
        return
    }
    finally {
        Remove-Item Env:\SCP_IN_AIJAIL -ErrorAction SilentlyContinue
    }
}

function Invoke-SupplyGatePackageManagerTool {
    $policy = Get-SupplyGatePolicy
    switch ($Tool) {
        'go' {
            if ($mode -eq 'hard') {
                $env:GOPROXY = $policy['GO_PROXY_URL']
                $env:GOSUMDB = $(if ($policy['GO_SUMDB']) { $policy['GO_SUMDB'] } else { 'sum.golang.org' })
                $env:GOPRIVATE = $policy['GO_PRIVATE_PATTERNS']
                $env:GONOSUMDB = $policy['GO_NO_SUMDB_PATTERNS']
                $env:GOVCS = $policy['GO_VCS_RULES']
            }
        }
        { $_ -in 'pip', 'pip3', 'uv', 'poetry' } {
            if ($policy['PYTHON_INDEX_URL'] -and $mode -eq 'hard') { $env:PIP_INDEX_URL = $policy['PYTHON_INDEX_URL'] }
        }
        { $_ -in 'npm', 'pnpm', 'yarn', 'bun' } {
            if ($mode -eq 'hard') {
                $env:NPM_CONFIG_REGISTRY = $policy['NPM_REGISTRY_URL']
                $env:npm_config_registry = $policy['NPM_REGISTRY_URL']
            }
        }
    }

    Write-SupplyGateInfo "Delegating to real binary: $realBin"
    Write-SupplyGateJsonEvent -Level INFO -Event 'command.allowed' -Tool $Tool -Command $commandText -Status started -Detail 'delegating to real binary'
    & $realBin @ToolArgs
    return
}

$rc = 1
try {
    # Not "$rc = Invoke-...": a PowerShell function's return value is its
    # entire success-stream output, which also carries whatever the wrapped
    # native command printed to stdout. Capturing that into $rc mangled it
    # into a mixed string/int array (caught by tests/windows/test_wrapper.ps1
    # -- the real fix is here: call bare, forward the native output straight
    # to the console as intended, then read $LASTEXITCODE separately, since
    # PowerShell function calls never reset it.
    if (Test-SupplyGateIsAiTool -Tool $Tool) {
        Invoke-SupplyGateAiTool
        $rc = $LASTEXITCODE
    }
    elseif (Test-SupplyGateIsPackageManager -Tool $Tool) {
        Invoke-SupplyGatePackageManagerTool
        $rc = $LASTEXITCODE
    }
    else {
        Write-SupplyGateErr "Tool not managed by wrapper: $Tool"
        Write-SupplyGateJsonEvent -Level ERROR -Event 'command.blocked' -Tool $Tool -Command $commandText -Status blocked -Detail 'unknown tool'
        exit 1
    }
}
catch {
    Write-SupplyGateErr "Command failed: $commandText ($($_.Exception.Message))"
    Write-SupplyGateJsonEvent -Level ERROR -Event 'command.completed' -Tool $Tool -Command $commandText -Status failure -Detail $_.Exception.Message
    exit 1
}

if ($rc -eq 0) {
    Write-SupplyGateInfo "Command succeeded: $commandText"
    Write-SupplyGateJsonEvent -Level INFO -Event 'command.completed' -Tool $Tool -Command $commandText -Status success -Detail 'ok'
}
else {
    Write-SupplyGateErr "Command failed: $commandText (exit $rc)"
    Write-SupplyGateJsonEvent -Level ERROR -Event 'command.completed' -Tool $Tool -Command $commandText -Status failure -Detail "exit $rc"
}
exit $rc
