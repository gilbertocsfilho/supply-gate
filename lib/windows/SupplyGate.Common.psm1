# Native Windows runtime primitives for Supply Gate: PowerShell port of
# lib/common.sh. Kept as a separate module (not a translation embedded in
# install.ps1) for the same reason lib/common.sh is separate from install.sh:
# the installed runtime copy (under <StateRoot>\runtime\) is dot-imported by
# the shim wrapper on every intercepted command, independent of the repo
# checkout.
#
# State lives in module scope ($Script:...), set once via Initialize-SupplyGate
# and read through the accessor functions below -- callers never touch
# $Script:* directly, matching the module boundary the checks module and
# install.ps1/manager-wrapper.ps1 rely on.

Set-StrictMode -Version Latest

$Script:MarkerBegin = '# >>> supply-chain-protect >>>'
$Script:MarkerEnd = '# <<< supply-chain-protect <<<'
$Script:Policy = $null
$Script:Paths = $null
$Script:Scope = 'User'
$Script:EnforcementMode = $null
$Script:RunLogPath = $null
$Script:AggregateLogPath = $null

function Get-SupplyGateMarkerBegin { $Script:MarkerBegin }
function Get-SupplyGateMarkerEnd { $Script:MarkerEnd }

# ---------------------------------------------------------------------------
# Policy loading. Mirrors lib/common.sh's KEY="value" sourcing: default
# policy, then policy/local-policy.conf as an overlay when present (never
# shipped, gitignored -- same convention as the POSIX side).
# ---------------------------------------------------------------------------
function Read-SupplyGatePolicyFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing policy file: $Path"
    }
    $table = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?(.*?)"?$') {
            $key = $Matches[1]
            $value = $Matches[2]
            # Skip shell parameter-expansion defaults ("${VAR:-...}"): these two
            # keys are handled as explicit overrides elsewhere, not by value.
            if ($value -match '^\$\{[A-Za-z0-9_]+:-.*\}$') { $value = '' }
            $table[$key] = $value
        }
    }
    return $table
}

function Initialize-SupplyGatePolicy {
    param(
        [Parameter(Mandatory)][string]$PolicyFile,
        [string]$LocalPolicyFile
    )
    $table = Read-SupplyGatePolicyFile -Path $PolicyFile
    if ($LocalPolicyFile -and (Test-Path -LiteralPath $LocalPolicyFile)) {
        $overlay = Read-SupplyGatePolicyFile -Path $LocalPolicyFile
        foreach ($k in $overlay.Keys) { $table[$k] = $overlay[$k] }
    }
    foreach ($listKey in 'MANAGED_COMMANDS', 'PACKAGE_MANAGERS', 'AI_COMMANDS') {
        $raw = if ($table.Contains($listKey)) { $table[$listKey] } else { '' }
        $table["${listKey}_LIST"] = @($raw -split '\s+' | Where-Object { $_ -ne '' })
    }
    $Script:Policy = $table
}

function Get-SupplyGatePolicy { $Script:Policy }

function Test-SupplyGateIsAiTool {
    param([Parameter(Mandatory)][string]$Tool)
    return $Script:Policy['AI_COMMANDS_LIST'] -contains $Tool
}

function Test-SupplyGateIsPackageManager {
    param([Parameter(Mandatory)][string]$Tool)
    return $Script:Policy['PACKAGE_MANAGERS_LIST'] -contains $Tool
}

# ---------------------------------------------------------------------------
# State paths. Mirrors lib/common.sh's STATE_ROOT/LOG_ROOT/... plus
# install.sh's setup_system_paths for machine scope.
#   User:    %LOCALAPPDATA%\SupplyChainProtect   (matches the Windows branch
#            lib/common.sh's default_state_root already assumed)
#   Machine: %ProgramData%\supply-gate            (Windows analog of the
#            hardcoded /opt/supply-gate machine root)
# ---------------------------------------------------------------------------
function Get-SupplyGateStatePaths {
    param(
        [ValidateSet('User', 'Machine')][string]$Scope = 'User',
        [string]$StateRootOverride
    )
    if ($StateRootOverride) {
        $stateRoot = $StateRootOverride
    }
    elseif ($Scope -eq 'Machine') {
        $stateRoot = Join-Path $env:ProgramData 'supply-gate'
    }
    else {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
        $stateRoot = Join-Path $base 'SupplyChainProtect'
    }
    $logRoot = Join-Path $stateRoot 'logs'
    $shimRoot = Join-Path $stateRoot 'shims'
    $runtimeRoot = Join-Path $stateRoot 'runtime'
    $attRoot = Join-Path $stateRoot 'attestation'
    [PSCustomObject]@{
        StateRoot      = $stateRoot
        LogRoot         = $logRoot
        ShimRoot        = $shimRoot
        RuntimeRoot     = $runtimeRoot
        AttRoot         = $attRoot
        RunstateFile    = Join-Path $runtimeRoot 'state.json'
        ProfileSnippet  = Join-Path $runtimeRoot 'profile.ps1'
        WrapperBin      = Join-Path $runtimeRoot 'manager-wrapper.ps1'
        CommonRuntime   = Join-Path $runtimeRoot 'SupplyGate.Common.psm1'
        PolicyRuntime   = Join-Path $runtimeRoot 'policy.conf'
        AggregateLog    = Join-Path $logRoot 'events.jsonl'
        StatusFile      = Join-Path $attRoot 'status.json'
    }
}

function Initialize-SupplyGate {
    param(
        [ValidateSet('User', 'Machine')][string]$Scope = 'User',
        [Parameter(Mandatory)][string]$PolicyFile,
        [string]$LocalPolicyFile,
        [string]$StateRootOverride
    )
    $Script:Scope = $Scope
    Initialize-SupplyGatePolicy -PolicyFile $PolicyFile -LocalPolicyFile $LocalPolicyFile
    $Script:Paths = Get-SupplyGateStatePaths -Scope $Scope -StateRootOverride $StateRootOverride
    $Script:EnforcementMode = $null
}

function Get-SupplyGatePaths { $Script:Paths }
function Get-SupplyGateScope { $Script:Scope }

function New-SupplyGateDirs {
    foreach ($d in @($Script:Paths.StateRoot, $Script:Paths.LogRoot, $Script:Paths.ShimRoot, $Script:Paths.RuntimeRoot, $Script:Paths.AttRoot)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# Timestamps / hashing
# ---------------------------------------------------------------------------
function Get-SupplyGateTimestampUtc { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-SupplyGateTimestampSlug { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }

function Get-SupplyGateFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Logging: a per-run text log plus an append-only JSONL aggregate log,
# mirroring log_init/log_line/log_json_event. ConvertTo-Json handles escaping,
# so there is no equivalent of common.sh's hand-rolled json_escape needed.
# ---------------------------------------------------------------------------
function Initialize-SupplyGateLog {
    param([string]$Context = 'tool')
    New-SupplyGateDirs
    $runId = "$(Get-SupplyGateTimestampSlug)-$PID"
    $candidate = Join-Path $Script:Paths.LogRoot "$runId-$Context.log"
    try {
        New-Item -ItemType File -Path $candidate -Force -ErrorAction Stop | Out-Null
        $Script:RunLogPath = $candidate
    }
    catch {
        # Best-effort, same as log_init's /dev/null fallback: logging must
        # never break the command it wraps.
        $Script:RunLogPath = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $Script:Paths.AggregateLog)) {
            New-Item -ItemType File -Path $Script:Paths.AggregateLog -Force -ErrorAction Stop | Out-Null
        }
        $Script:AggregateLogPath = $Script:Paths.AggregateLog
    }
    catch {
        $Script:AggregateLogPath = $null
    }
}

function Stop-SupplyGateLog {
    $Script:RunLogPath = $null
    $Script:AggregateLogPath = $null
}

function Write-SupplyGateLogLine {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $line = "$(Get-SupplyGateTimestampUtc) [$Level] $Message"
    Write-Host $line
    if ($Script:RunLogPath) {
        try { Add-Content -LiteralPath $Script:RunLogPath -Value $line -ErrorAction Stop }
        catch { }
    }
}

function Write-SupplyGateInfo { param([string]$Message) Write-SupplyGateLogLine -Level INFO -Message $Message }
function Write-SupplyGateWarn { param([string]$Message) Write-SupplyGateLogLine -Level WARN -Message $Message }
function Write-SupplyGateErr { param([string]$Message) Write-SupplyGateLogLine -Level ERROR -Message $Message }

function Write-SupplyGateJsonEvent {
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Event,
        [string]$Tool = '',
        [string]$Command = '',
        [string]$Status = '',
        [string]$Detail = ''
    )
    if (-not $Script:AggregateLogPath) { return }
    $obj = [ordered]@{
        timestamp      = Get-SupplyGateTimestampUtc
        level          = $Level
        event          = $Event
        tool           = $Tool
        command        = $Command
        status         = $Status
        policy_mode    = $(if ($Script:EnforcementMode) { $Script:EnforcementMode } else { 'unset' })
        policy_version = $Script:Policy['POLICY_VERSION']
        user           = $(if ($env:USERNAME) { $env:USERNAME } else { 'unknown' })
        host           = $env:COMPUTERNAME
        platform       = 'windows'
        detail         = $Detail
    }
    try {
        ($obj | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Script:AggregateLogPath -ErrorAction Stop
    }
    catch { }
}

# ---------------------------------------------------------------------------
# Runtime state (state.json) / status (status.json). JSON instead of the
# shell-sourced state.conf/status.env the POSIX side uses -- same purpose,
# fewer quoting hazards on this side.
# ---------------------------------------------------------------------------
function Save-SupplyGateRuntimeState {
    param([Parameter(Mandatory)][string]$Mode)
    $obj = [ordered]@{
        EnforcementMode      = $Mode
        PolicyVersionApplied = $Script:Policy['POLICY_VERSION']
        StateRoot            = $Script:Paths.StateRoot
        ShimRoot             = $Script:Paths.ShimRoot
        LogRoot              = $Script:Paths.LogRoot
        ProfileSnippet       = $Script:Paths.ProfileSnippet
        UpdatedAt            = Get-SupplyGateTimestampUtc
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Script:Paths.RunstateFile) | Out-Null
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $Script:Paths.RunstateFile -Encoding UTF8
    $Script:EnforcementMode = $Mode
}

function Get-SupplyGateRuntimeState {
    if (Test-Path -LiteralPath $Script:Paths.RunstateFile) {
        try { return (Get-Content -Raw -LiteralPath $Script:Paths.RunstateFile | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}

function Import-SupplyGateRuntimeState {
    $state = Get-SupplyGateRuntimeState
    if ($state -and $state.EnforcementMode) { $Script:EnforcementMode = $state.EnforcementMode }
    return $state
}

function Get-SupplyGateMode {
    Import-SupplyGateRuntimeState | Out-Null
    if ($Script:EnforcementMode) { return $Script:EnforcementMode }
    if ($Script:Policy['DEFAULT_MODE']) { return $Script:Policy['DEFAULT_MODE'] }
    return 'soft'
}

function Set-SupplyGateMode {
    param([Parameter(Mandatory)][string]$Mode)
    $Script:EnforcementMode = $Mode
}

function Save-SupplyGateStatus {
    param([Parameter(Mandatory)][string]$Result)
    $hash = if (Test-Path -LiteralPath $Script:Paths.WrapperBin) { Get-SupplyGateFileHash -Path $Script:Paths.WrapperBin } else { 'missing' }
    $obj = [ordered]@{
        Status          = $Result
        EnforcementMode = $(if ($Script:EnforcementMode) { $Script:EnforcementMode } else { 'unset' })
        PolicyVersion   = $Script:Policy['POLICY_VERSION']
        UpdatedAt       = Get-SupplyGateTimestampUtc
        ShimHash        = $hash
    }
    New-Item -ItemType Directory -Force -Path $Script:Paths.AttRoot | Out-Null
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $Script:Paths.StatusFile -Encoding UTF8
}

function Get-SupplyGateStatus {
    if (Test-Path -LiteralPath $Script:Paths.StatusFile) {
        try { return (Get-Content -Raw -LiteralPath $Script:Paths.StatusFile | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Managed blocks. Mirrors append_managed_block/remove_managed_block: content
# between MarkerBegin/MarkerEnd is replaced wholesale on every apply, and the
# rest of the file (the user's own content) is left untouched -- verified by
# tests/windows/test_common.ps1 the same way tests/test_checks.sh does for
# the shell side (uninstall must not destroy a user's own lines).
# ---------------------------------------------------------------------------
function Remove-SupplyGateManagedBlockText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $pattern = '(?ms)^' + [regex]::Escape($Script:MarkerBegin) + '.*?^' + [regex]::Escape($Script:MarkerEnd) + '\r?\n?'
    return [regex]::Replace($Text, $pattern, '')
}

function Add-SupplyGateManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Body
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $existing = if (Test-Path -LiteralPath $Path) { Get-Content -Raw -LiteralPath $Path } else { '' }
    if ($null -eq $existing) { $existing = '' }
    $clean = (Remove-SupplyGateManagedBlockText -Text $existing).TrimEnd()
    $parts = @()
    if ($clean.Length -gt 0) { $parts += $clean }
    $parts += $Script:MarkerBegin
    $parts += $Body
    $parts += $Script:MarkerEnd
    Set-Content -LiteralPath $Path -Value (($parts -join "`n") + "`n") -NoNewline -Encoding UTF8
}

function Remove-SupplyGateManagedBlock {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $existing = Get-Content -Raw -LiteralPath $Path
    $clean = Remove-SupplyGateManagedBlockText -Text $existing
    Set-Content -LiteralPath $Path -Value $clean -NoNewline -Encoding UTF8
}

function Test-SupplyGateMarker {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool](Select-String -LiteralPath $Path -Pattern ([regex]::Escape($Script:MarkerBegin)) -Quiet -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Hard-mode value validation. Same placeholder patterns as require_hard_value.
# ---------------------------------------------------------------------------
function Test-SupplyGateHardValuePlaceholder {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $true }
    if ($Value -match 'example\.corp' -or $Value -match 'invalid') { return $true }
    return $false
}

function Assert-SupplyGateHardValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )
    if (Test-SupplyGateHardValuePlaceholder -Value $Value) {
        Write-SupplyGateErr "Hard mode requires a real value for $Name"
        Write-SupplyGateJsonEvent -Level ERROR -Event 'policy.invalid' -Tool $Name -Status 'blocked' -Detail 'placeholder value'
        return $false
    }
    return $true
}

function Test-SupplyGateModePrereqs {
    if ((Get-SupplyGateMode) -ne 'hard') { return $true }
    $ok = $true
    $ok = (Assert-SupplyGateHardValue -Name 'NPM_REGISTRY_URL' -Value $Script:Policy['NPM_REGISTRY_URL']) -and $ok
    $ok = (Assert-SupplyGateHardValue -Name 'PYTHON_INDEX_URL' -Value $Script:Policy['PYTHON_INDEX_URL']) -and $ok
    $ok = (Assert-SupplyGateHardValue -Name 'CARGO_REGISTRY_URL' -Value $Script:Policy['CARGO_REGISTRY_URL']) -and $ok
    $ok = (Assert-SupplyGateHardValue -Name 'GO_PROXY_URL' -Value $Script:Policy['GO_PROXY_URL']) -and $ok
    return $ok
}

# ---------------------------------------------------------------------------
# Real-binary resolution. Mirrors find_real_binary/resolve_real_binary/
# is_managed_shim: walk $env:Path, skip our own shim directory by content
# (not by path string), so parallel/stale installs cannot resolve to
# themselves and loop.
# ---------------------------------------------------------------------------
function Test-SupplyGateManagedShim {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $head = Get-Content -LiteralPath $Path -TotalCount 20 -ErrorAction Stop
        return ($head -join "`n") -match 'manager-wrapper\.ps1'
    }
    catch { return $false }
}

function Find-SupplyGateRealBinary {
    param([Parameter(Mandatory)][string]$Tool)
    $exts = if ($env:PATHEXT) { $env:PATHEXT -split ';' } else { @('.COM', '.EXE', '.BAT', '.CMD') }
    $dirs = @($env:Path -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    foreach ($dir in $dirs) {
        foreach ($ext in $exts) {
            $candidate = Join-Path $dir "$Tool$ext"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                if ($candidate -match '\.(cmd|bat|ps1)$' -and (Test-SupplyGateManagedShim -Path $candidate)) { continue }
                return $candidate
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Local user enumeration for machine scope, reading the ProfileList registry
# hive -- the Windows analog of iterating /etc/passwd (Linux) or `dscl`
# (macOS) in list_local_users. SID-to-name edge cases (domain accounts,
# orphaned profiles) are not handled; see docs/windows-support.md.
# ---------------------------------------------------------------------------
function Get-SupplyGateLocalUsers {
    $result = @()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem -Path $key -ErrorAction SilentlyContinue | ForEach-Object {
        $profilePath = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) { return }
        if ($profilePath -match '\\(systemprofile|LocalService|NetworkService)$') { return }
        if (-not (Test-Path -LiteralPath $profilePath)) { return }
        $result += [PSCustomObject]@{
            Name = Split-Path -Leaf $profilePath
            Home = $profilePath
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Package-manager configuration. Mirrors configure_npm/bun/pip/cargo/go.
# HomeDir/ConfigDir default to the current user but are overridable so
# machine-scope apply can target other local users' profiles.
# ---------------------------------------------------------------------------
function Set-SupplyGateNpmConfig {
    param([string]$HomeDir = $env:USERPROFILE)
    $lines = @(
        'save-exact=true',
        'min-release-age=7',
        "minimum-release-age=$($Script:Policy['NODE_COOLDOWN_MINUTES'])"
    )
    if ((Get-SupplyGateMode) -eq 'hard') { $lines += "registry=$($Script:Policy['NPM_REGISTRY_URL'])" }
    Add-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.npmrc') -Body ($lines -join "`n")
}

function Set-SupplyGateBunConfig {
    param([string]$HomeDir = $env:USERPROFILE)
    $body = "[install]`nminimumReleaseAge = $($Script:Policy['BUN_COOLDOWN_SECONDS'])"
    Add-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.bunfig.toml') -Body $body
}

function Set-SupplyGatePipConfig {
    param([string]$ConfigDir = $env:APPDATA)
    $lines = @('[global]', 'disable-pip-version-check = true')
    if ((Get-SupplyGateMode) -eq 'hard') { $lines += "index-url = $($Script:Policy['PYTHON_INDEX_URL'])" }
    Add-SupplyGateManagedBlock -Path (Join-Path $ConfigDir 'pip\pip.ini') -Body ($lines -join "`n")
}

function Set-SupplyGateCargoConfig {
    param([string]$HomeDir = $env:USERPROFILE)
    if ((Get-SupplyGateMode) -eq 'hard') {
        $body = "[registries.crates-io]`nprotocol = `"sparse`"`n[source.crates-io]`nreplace-with = `"corporate`"`n[source.corporate]`nregistry = `"$($Script:Policy['CARGO_REGISTRY_URL'])`""
    }
    else {
        $body = "[registries.crates-io]`nprotocol = `"sparse`"`n[net]`ngit-fetch-with-cli = true"
    }
    Add-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.cargo\config.toml') -Body $body
}

function Set-SupplyGateGoConfig {
    $goCmd = Find-SupplyGateRealBinary -Tool 'go'
    if (-not $goCmd) { return $true }
    & $goCmd version *> $null
    if ($LASTEXITCODE -ne 0) {
        if ((Get-SupplyGateMode) -eq 'hard') {
            Write-SupplyGateErr "Detected go binary is not operable: $goCmd"
            return $false
        }
        Write-SupplyGateWarn 'Detected go binary is not operable in current environment; skipping go env hardening'
        return $true
    }
    if ((Get-SupplyGateMode) -eq 'hard') {
        if (-not (Assert-SupplyGateHardValue -Name 'GO_PROXY_URL' -Value $Script:Policy['GO_PROXY_URL'])) { return $false }
        & $goCmd env -w "GOPROXY=$($Script:Policy['GO_PROXY_URL'])" | Out-Null
    }
    else {
        & $goCmd env -w 'GOPROXY=https://proxy.golang.org,direct' | Out-Null
    }
    & $goCmd env -w "GOSUMDB=$($Script:Policy['GO_SUMDB'])" | Out-Null
    & $goCmd env -w "GOPRIVATE=$($Script:Policy['GO_PRIVATE_PATTERNS'])" | Out-Null
    & $goCmd env -w "GONOSUMDB=$($Script:Policy['GO_NO_SUMDB_PATTERNS'])" | Out-Null
    & $goCmd env -w "GOVCS=$($Script:Policy['GO_VCS_RULES'])" | Out-Null
    return $true
}

function Set-SupplyGatePackageConfigsForHome {
    param(
        [string]$HomeDir = $env:USERPROFILE,
        [string]$ConfigDir = $env:APPDATA
    )
    Set-SupplyGateNpmConfig -HomeDir $HomeDir
    Set-SupplyGateBunConfig -HomeDir $HomeDir
    Set-SupplyGatePipConfig -ConfigDir $ConfigDir
    Set-SupplyGateCargoConfig -HomeDir $HomeDir
}

function Remove-SupplyGatePackageConfigsForHome {
    param(
        [string]$HomeDir = $env:USERPROFILE,
        [string]$ConfigDir = $env:APPDATA
    )
    Remove-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.npmrc')
    Remove-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.bunfig.toml')
    Remove-SupplyGateManagedBlock -Path (Join-Path $ConfigDir 'pip\pip.ini')
    Remove-SupplyGateManagedBlock -Path (Join-Path $HomeDir '.cargo\config.toml')
}

# ---------------------------------------------------------------------------
# PATH + profile plumbing. cmd.exe needs only the Path environment variable
# (it has no rc-file equivalent); the profile snippet below exists for
# PowerShell sessions, to refresh $env:Path in-session and to host the
# <tool>-nojail convenience functions (mirrors write_profile_snippet's
# $tool-nojail in install.sh).
# ---------------------------------------------------------------------------
function Set-SupplyGateProfileSnippet {
    $lines = @("`$env:Path = `"$($Script:Paths.ShimRoot);`$env:Path`"")
    foreach ($tool in $Script:Policy['AI_COMMANDS_LIST']) {
        $lines += "function ${tool}-nojail { `$env:SCP_AI_JAIL_BYPASS = '1'; try { & $tool @args } finally { Remove-Item Env:\SCP_AI_JAIL_BYPASS -ErrorAction SilentlyContinue } }"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Script:Paths.ProfileSnippet) | Out-Null
    Set-Content -LiteralPath $Script:Paths.ProfileSnippet -Value ($lines -join "`n") -Encoding UTF8
}

function Add-SupplyGateShimRootToPath {
    param([Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$EnvScope)
    $existing = [Environment]::GetEnvironmentVariable('Path', $EnvScope)
    $parts = @()
    if ($existing) { $parts = @($existing.Split(';') | Where-Object { $_ -and $_.Trim() -ne '' }) }
    if ($parts -notcontains $Script:Paths.ShimRoot) {
        $new = (@($Script:Paths.ShimRoot) + $parts) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, $EnvScope)
    }
    if ($env:Path -notmatch [regex]::Escape($Script:Paths.ShimRoot)) {
        $env:Path = "$($Script:Paths.ShimRoot);$env:Path"
    }
}

function Remove-SupplyGateShimRootFromPath {
    param([Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$EnvScope)
    $existing = [Environment]::GetEnvironmentVariable('Path', $EnvScope)
    if (-not $existing) { return }
    $parts = @($existing.Split(';') | Where-Object { $_ -and $_ -ne $Script:Paths.ShimRoot })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), $EnvScope)
}

# AllUsersAllHosts profile paths: Windows PowerShell 5.1 and PowerShell 7 keep
# separate $PSHOME directories, so both are written when present -- the
# machine-scope analog of writing both /etc/bashrc and /etc/bash.bashrc.
function Get-SupplyGateAllUsersProfilePaths {
    $paths = @()
    $winPSHome = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0'
    if (Test-Path -LiteralPath $winPSHome) { $paths += Join-Path $winPSHome 'profile.ps1' }
    if ($env:ProgramFiles) {
        $pwshHome = Join-Path $env:ProgramFiles 'PowerShell\7'
        if (Test-Path -LiteralPath $pwshHome) { $paths += Join-Path $pwshHome 'profile.ps1' }
    }
    return $paths
}

function Set-SupplyGateSystemProfiles {
    Set-SupplyGateProfileSnippet
    $block = ". `"$($Script:Paths.ProfileSnippet)`""
    foreach ($p in (Get-SupplyGateAllUsersProfilePaths)) {
        Add-SupplyGateManagedBlock -Path $p -Body $block
    }
    Add-SupplyGateShimRootToPath -EnvScope Machine
}

function Remove-SupplyGateSystemProfiles {
    foreach ($p in (Get-SupplyGateAllUsersProfilePaths)) {
        Remove-SupplyGateManagedBlock -Path $p
    }
    Remove-SupplyGateShimRootFromPath -EnvScope Machine
}

function Set-SupplyGateUserProfile {
    Set-SupplyGateProfileSnippet
    $block = ". `"$($Script:Paths.ProfileSnippet)`""
    Add-SupplyGateManagedBlock -Path $PROFILE.CurrentUserAllHosts -Body $block
    Add-SupplyGateShimRootToPath -EnvScope User
}

function Remove-SupplyGateUserProfile {
    Remove-SupplyGateManagedBlock -Path $PROFILE.CurrentUserAllHosts
    Remove-SupplyGateShimRootFromPath -EnvScope User
}

function Test-SupplyGateIsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

Export-ModuleMember -Function * -Variable @()
