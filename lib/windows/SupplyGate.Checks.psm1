# Integrity checks behind `install.ps1 status`. PowerShell port of
# lib/checks.sh -- same exit-code contract (0 healthy, 1 degraded/repairable,
# 2 manual action needed) and the same "record every check, decide the
# verdict from the worst one" shape. Read-only: the only writes are the
# events.jsonl append and a probe file under LogRoot that is removed
# immediately (mirrors check_evidence).
#
# Unlike lib/checks.sh's delimited-string CHECK_RESULTS (a shell workaround
# for not having real arrays of records), this keeps a plain array of
# PSCustomObjects -- no CHECK_SEP encoding needed.

Set-StrictMode -Version Latest

$Script:CheckResults = @()
$Script:CheckScope = 'User'
$Script:CheckFull = $false
$Script:RepoRoot = $null

function Reset-SupplyGateChecks {
    param(
        [ValidateSet('User', 'Machine')][string]$Scope = 'User',
        [switch]$Full,
        [string]$RepoRoot
    )
    $Script:CheckResults = @()
    $Script:CheckScope = $Scope
    $Script:CheckFull = [bool]$Full
    $Script:RepoRoot = $RepoRoot
}

# check_record <id> <ok|warn|fail|unknown> <detail> [repair|manual|none]
function Add-SupplyGateCheckResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail', 'unknown')][string]$Severity,
        [string]$Detail = '',
        [ValidateSet('repair', 'manual', 'none')][string]$Fix = 'none'
    )
    $Script:CheckResults += [PSCustomObject]@{
        Id       = $Id
        Severity = $Severity
        Detail   = ($Detail -replace '[\r\n]', ' ')
        Fix      = $Fix
    }
}

function Get-SupplyGateCheckResults { $Script:CheckResults }

function Get-SupplyGateVerdict {
    $fails = $Script:CheckResults | Where-Object { $_.Severity -eq 'fail' }
    if (-not $fails) { return 'healthy' }
    # A manual fail outranks a repairable one: repair would fail again for the
    # same reason while a manual blocker stands.
    if ($fails | Where-Object { $_.Fix -eq 'manual' }) { return 'action_required' }
    return 'degraded'
}

function Get-SupplyGateVerdictExitCode {
    param([Parameter(Mandatory)][string]$Verdict)
    switch ($Verdict) {
        'healthy' { return 0 }
        'degraded' { return 1 }
        default { return 2 }
    }
}

function Test-SupplyGateHash {
    param([string]$Id, [string]$InstalledPath, [string]$SourcePath)
    if (-not (Test-Path -LiteralPath $InstalledPath)) { return }
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Add-SupplyGateCheckResult -Id $Id -Severity unknown -Detail "shipped source not readable: $SourcePath" -Fix none
        return
    }
    $a = Get-SupplyGateFileHash -Path $InstalledPath
    $b = Get-SupplyGateFileHash -Path $SourcePath
    if ($a -eq $b) {
        Add-SupplyGateCheckResult -Id $Id -Severity ok -Detail 'matches shipped source' -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id $Id -Severity fail -Detail "installed copy differs from $SourcePath" -Fix repair
    }
}

function Test-SupplyGateInstall {
    $paths = Get-SupplyGatePaths
    if (-not (Test-Path -LiteralPath $paths.StateRoot)) {
        Add-SupplyGateCheckResult -Id 'install.state_root' -Severity fail -Detail "$($paths.StateRoot) does not exist; not installed in this scope" -Fix manual
        return $false
    }
    Add-SupplyGateCheckResult -Id 'install.state_root' -Severity ok -Detail $paths.StateRoot -Fix none
    $state = Get-SupplyGateRuntimeState
    if ($state -and $state.EnforcementMode) {
        Add-SupplyGateCheckResult -Id 'install.mode' -Severity ok -Detail "$($state.EnforcementMode) (applied $($state.UpdatedAt))" -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'install.mode' -Severity fail -Detail 'state.json missing or has no EnforcementMode' -Fix repair
    }
    return $true
}

function Test-SupplyGateRuntime {
    $paths = Get-SupplyGatePaths
    if (Test-Path -LiteralPath $paths.CommonRuntime) {
        Add-SupplyGateCheckResult -Id 'runtime.common_present' -Severity ok -Detail $paths.CommonRuntime -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'runtime.common_present' -Severity fail -Detail "missing: $($paths.CommonRuntime)" -Fix repair
    }
    if ($Script:RepoRoot) {
        Test-SupplyGateHash -Id 'runtime.common_current' -InstalledPath $paths.CommonRuntime `
            -SourcePath (Join-Path $Script:RepoRoot 'lib\windows\SupplyGate.Common.psm1')
    }

    if (Test-Path -LiteralPath $paths.WrapperBin) {
        Add-SupplyGateCheckResult -Id 'runtime.wrapper_present' -Severity ok -Detail 'present' -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'runtime.wrapper_present' -Severity fail -Detail "missing: $($paths.WrapperBin)" -Fix repair
    }
    if ($Script:RepoRoot) {
        Test-SupplyGateHash -Id 'runtime.wrapper_current' -InstalledPath $paths.WrapperBin `
            -SourcePath (Join-Path $Script:RepoRoot 'shims\windows\manager-wrapper.ps1')
    }

    if (Test-Path -LiteralPath $paths.PolicyRuntime) {
        Add-SupplyGateCheckResult -Id 'runtime.policy_present' -Severity ok -Detail $paths.PolicyRuntime -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'runtime.policy_present' -Severity fail -Detail "missing: $($paths.PolicyRuntime)" -Fix repair
    }

    $state = Get-SupplyGateRuntimeState
    $policy = Get-SupplyGatePolicy
    if (-not $state -or -not $state.PolicyVersionApplied) {
        Add-SupplyGateCheckResult -Id 'runtime.policy_version' -Severity unknown -Detail 'not recorded in state.json' -Fix none
    }
    elseif ($state.PolicyVersionApplied -eq $policy['POLICY_VERSION']) {
        Add-SupplyGateCheckResult -Id 'runtime.policy_version' -Severity ok -Detail $policy['POLICY_VERSION'] -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'runtime.policy_version' -Severity fail `
            -Detail "applied $($state.PolicyVersionApplied), shipped $($policy['POLICY_VERSION'])" -Fix repair
    }

    if (-not (Test-Path -LiteralPath $paths.ProfileSnippet)) {
        Add-SupplyGateCheckResult -Id 'runtime.profile_snippet' -Severity fail -Detail "missing: $($paths.ProfileSnippet)" -Fix repair
    }
    elseif (Select-String -LiteralPath $paths.ProfileSnippet -Pattern ([regex]::Escape($paths.ShimRoot)) -Quiet -ErrorAction SilentlyContinue) {
        Add-SupplyGateCheckResult -Id 'runtime.profile_snippet' -Severity ok -Detail "prepends $($paths.ShimRoot)" -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'runtime.profile_snippet' -Severity fail -Detail "does not prepend $($paths.ShimRoot)" -Fix repair
    }
}

function Test-SupplyGateShims {
    $paths = Get-SupplyGatePaths
    $policy = Get-SupplyGatePolicy
    $missing = @()
    $bad = @()
    $ok = 0
    $total = 0
    foreach ($tool in $policy['MANAGED_COMMANDS_LIST']) {
        $total++
        $shimPath = Join-Path $paths.ShimRoot "$tool.cmd"
        if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
            $missing += $tool
            continue
        }
        if (Select-String -LiteralPath $shimPath -Pattern ([regex]::Escape($paths.WrapperBin)) -Quiet -ErrorAction SilentlyContinue) {
            $ok++
        }
        else {
            $bad += $tool
        }
    }
    if ($missing.Count -gt 0) {
        Add-SupplyGateCheckResult -Id 'shim.present' -Severity fail -Detail "missing: $($missing -join ' ')" -Fix repair
    }
    else {
        Add-SupplyGateCheckResult -Id 'shim.present' -Severity ok -Detail "$total/$total present" -Fix none
    }
    if ($bad.Count -gt 0) {
        Add-SupplyGateCheckResult -Id 'shim.target' -Severity fail -Detail "point at a different wrapper: $($bad -join ' ')" -Fix repair
    }
    else {
        Add-SupplyGateCheckResult -Id 'shim.target' -Severity ok -Detail "$ok/$total point at the current wrapper" -Fix none
    }
}

function Test-SupplyGateShimPath {
    $paths = Get-SupplyGatePaths
    $envScope = if ($Script:CheckScope -eq 'Machine') { 'Machine' } else { 'User' }
    $persisted = [Environment]::GetEnvironmentVariable('Path', $envScope)
    $persistedHasShim = $false
    if ($persisted) {
        $persistedHasShim = @($persisted.Split(';')) -contains $paths.ShimRoot
    }
    $sessionHasShim = @($env:Path -split ';') -contains $paths.ShimRoot

    if ($persistedHasShim) {
        Add-SupplyGateCheckResult -Id 'path.shim_dir' -Severity ok -Detail "present in $envScope PATH" -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'path.shim_dir' -Severity fail -Detail "$($paths.ShimRoot) is not in the persisted $envScope PATH" -Fix repair
    }

    if ($persistedHasShim -and -not $sessionHasShim) {
        Add-SupplyGateCheckResult -Id 'path.session' -Severity warn `
            -Detail 'not in THIS session; open a new shell to pick it up' -Fix none
    }

    $installed = 0
    $hit = 0
    $leaked = @()
    foreach ($tool in (Get-SupplyGatePolicy)['MANAGED_COMMANDS_LIST']) {
        $found = Find-SupplyGateRealBinary -Tool $tool
        if (-not $found) { continue }
        $installed++
        if (Test-SupplyGateManagedShim -Path $found) { $hit++ } else { $leaked += $tool }
    }
    if ($installed -eq 0) {
        Add-SupplyGateCheckResult -Id 'path.effective' -Severity ok -Detail 'no managed tools installed yet' -Fix none
    }
    elseif ($leaked.Count -eq 0) {
        Add-SupplyGateCheckResult -Id 'path.effective' -Severity ok -Detail "$hit/$installed resolve to shims" -Fix none
    }
    elseif (-not $sessionHasShim) {
        # Nothing can be concluded about interception from a session whose
        # $env:Path predates the install -- the persisted PATH is already
        # reported by path.shim_dir/path.session above. Very common: a
        # provisioning run (the NSIS installer, CI) checking status in the same
        # session that just ran apply. warn, not fail; the machine is fine, and
        # repair could not change this anyway. Mirrors check_path in
        # lib/checks.sh, which downgrades the identical case.
        Add-SupplyGateCheckResult -Id 'path.effective' -Severity warn `
            -Detail 'cannot judge from this session (shim dir not in its PATH)' -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'path.effective' -Severity fail -Detail "shadowed for: $($leaked -join ' ')" -Fix repair
    }
}

function Test-SupplyGateConfig {
    $paths = Get-SupplyGatePaths
    if ($Script:CheckScope -ne 'Machine') {
        foreach ($pair in @(
                @{ Id = 'config.npmrc'; Path = (Join-Path $env:USERPROFILE '.npmrc') },
                @{ Id = 'config.bunfig'; Path = (Join-Path $env:USERPROFILE '.bunfig.toml') },
                @{ Id = 'config.pip'; Path = (Join-Path $env:APPDATA 'pip\pip.ini') },
                @{ Id = 'config.cargo'; Path = (Join-Path $env:USERPROFILE '.cargo\config.toml') }
            )) {
            if (Test-SupplyGateMarker -Path $pair.Path) {
                Add-SupplyGateCheckResult -Id $pair.Id -Severity ok -Detail $pair.Path -Fix none
            }
            elseif (Test-Path -LiteralPath $pair.Path) {
                Add-SupplyGateCheckResult -Id $pair.Id -Severity fail -Detail "no managed block in $($pair.Path)" -Fix repair
            }
            else {
                Add-SupplyGateCheckResult -Id $pair.Id -Severity fail -Detail "missing: $($pair.Path)" -Fix repair
            }
        }
        if (Test-SupplyGateMarker -Path $PROFILE.CurrentUserAllHosts) {
            Add-SupplyGateCheckResult -Id 'config.profile' -Severity ok -Detail $PROFILE.CurrentUserAllHosts -Fix none
        }
        else {
            Add-SupplyGateCheckResult -Id 'config.profile' -Severity fail -Detail 'no managed block in $PROFILE.CurrentUserAllHosts' -Fix repair
        }
        return
    }

    $missing = @()
    $ok = @()
    foreach ($p in (Get-SupplyGateAllUsersProfilePaths)) {
        if (Test-SupplyGateMarker -Path $p) { $ok += $p } else { $missing += $p }
    }
    if ($missing.Count -gt 0) {
        Add-SupplyGateCheckResult -Id 'config.system.profile' -Severity fail -Detail "no managed block in: $($missing -join ' ')" -Fix repair
    }
    else {
        Add-SupplyGateCheckResult -Id 'config.system.profile' -Severity ok -Detail $(if ($ok) { $ok -join ' ' } else { 'no PowerShell host installed on this box' }) -Fix none
    }

    $bad = @()
    $n = 0
    foreach ($u in (Get-SupplyGateLocalUsers)) {
        if ((Test-SupplyGateMarker -Path (Join-Path $u.Home '.npmrc'))) { $n++ } else { $bad += $u.Name }
    }
    if ($bad.Count -gt 0) {
        Add-SupplyGateCheckResult -Id 'config.users' -Severity warn -Detail "$n configured; incomplete: $($bad -join ' ')" -Fix repair
    }
    else {
        Add-SupplyGateCheckResult -Id 'config.users' -Severity ok -Detail "$n user(s) configured" -Fix none
    }
}

function Test-SupplyGateModeChecks {
    $policy = Get-SupplyGatePolicy
    if ((Get-SupplyGateMode) -ne 'hard') {
        Add-SupplyGateCheckResult -Id 'mode.registries' -Severity ok -Detail 'not applicable in soft mode' -Fix none
        return
    }
    $bad = @()
    foreach ($pair in @(
            @{ Name = 'NPM_REGISTRY_URL'; Value = $policy['NPM_REGISTRY_URL'] },
            @{ Name = 'PYTHON_INDEX_URL'; Value = $policy['PYTHON_INDEX_URL'] },
            @{ Name = 'CARGO_REGISTRY_URL'; Value = $policy['CARGO_REGISTRY_URL'] },
            @{ Name = 'GO_PROXY_URL'; Value = $policy['GO_PROXY_URL'] }
        )) {
        if (Test-SupplyGateHardValuePlaceholder -Value $pair.Value) { $bad += $pair.Name }
    }
    if ($bad.Count -gt 0) {
        Add-SupplyGateCheckResult -Id 'mode.registries' -Severity fail `
            -Detail "unset/placeholder in hard mode: $($bad -join ' ') -- edit policy/local-policy.conf" -Fix manual
    }
    else {
        Add-SupplyGateCheckResult -Id 'mode.registries' -Severity ok -Detail 'all four hard-mode URLs are real' -Fix none
    }

    $npm = Find-SupplyGateRealBinary -Tool 'npm'
    if (-not $npm) {
        Add-SupplyGateCheckResult -Id 'mode.npm_registry' -Severity ok -Detail 'npm not installed' -Fix none
    }
    else {
        $eff = (& $npm config get registry 2>$null) -join ''
        if ($eff -eq $policy['NPM_REGISTRY_URL'] -or "$eff/" -eq $policy['NPM_REGISTRY_URL']) {
            Add-SupplyGateCheckResult -Id 'mode.npm_registry' -Severity ok -Detail $eff -Fix none
        }
        elseif (-not $eff) {
            Add-SupplyGateCheckResult -Id 'mode.npm_registry' -Severity unknown -Detail 'npm reported no registry' -Fix none
        }
        else {
            Add-SupplyGateCheckResult -Id 'mode.npm_registry' -Severity fail -Detail "registry $eff, expected $($policy['NPM_REGISTRY_URL'])" -Fix repair
        }
    }

    $pipConf = if ($Script:CheckScope -eq 'Machine') { Join-Path $env:ProgramData 'supply-gate\pip.ini' } else { Join-Path $env:APPDATA 'pip\pip.ini' }
    if (-not (Test-Path -LiteralPath $pipConf)) {
        Add-SupplyGateCheckResult -Id 'mode.pip_index' -Severity fail -Detail "missing: $pipConf" -Fix repair
    }
    elseif (Select-String -LiteralPath $pipConf -Pattern ([regex]::Escape("index-url = $($policy['PYTHON_INDEX_URL'])")) -Quiet -ErrorAction SilentlyContinue) {
        Add-SupplyGateCheckResult -Id 'mode.pip_index' -Severity ok -Detail $policy['PYTHON_INDEX_URL'] -Fix none
    }
    else {
        Add-SupplyGateCheckResult -Id 'mode.pip_index' -Severity fail -Detail "$pipConf does not set index-url to $($policy['PYTHON_INDEX_URL'])" -Fix repair
    }

    $go = Find-SupplyGateRealBinary -Tool 'go'
    if ($go) {
        & $go version *> $null
        if ($LASTEXITCODE -eq 0) {
            $eff = ((& $go env GOPROXY 2>$null) -join '').Trim()
            if ($eff -eq $policy['GO_PROXY_URL']) {
                Add-SupplyGateCheckResult -Id 'mode.goproxy' -Severity ok -Detail $eff -Fix none
            }
            else {
                Add-SupplyGateCheckResult -Id 'mode.goproxy' -Severity fail -Detail "GOPROXY=$eff, expected $($policy['GO_PROXY_URL'])" -Fix repair
            }
            return
        }
    }
    Add-SupplyGateCheckResult -Id 'mode.goproxy' -Severity ok -Detail 'go not installed or not operable' -Fix none
}

function Test-SupplyGateJail {
    $policy = Get-SupplyGatePolicy
    if (-not $policy['AI_COMMANDS_LIST'] -or $policy['AI_COMMANDS_LIST'].Count -eq 0) { return }
    $launcher = $policy['AI_JAIL_LAUNCHER_WINDOWS']
    $backend = $policy['AI_JAIL_BACKEND_WINDOWS']
    $aiCommands = $policy['AI_COMMANDS_LIST'] -join ' '

    if ($launcher -and (Test-Path -LiteralPath $launcher)) {
        Add-SupplyGateCheckResult -Id 'jail.launcher' -Severity ok -Detail "$launcher (backend: $backend)" -Fix none
        Add-SupplyGateCheckResult -Id 'jail.runtime_effect' -Severity ok -Detail "$aiCommands run JAILED" -Fix none
    }
    elseif ((Get-SupplyGateMode) -eq 'hard') {
        Add-SupplyGateCheckResult -Id 'jail.launcher' -Severity fail -Detail 'AI_JAIL_LAUNCHER_WINDOWS unset or missing' -Fix manual
        Add-SupplyGateCheckResult -Id 'jail.runtime_effect' -Severity fail -Detail "$aiCommands will be BLOCKED" -Fix manual
    }
    else {
        Add-SupplyGateCheckResult -Id 'jail.launcher' -Severity warn -Detail 'AI_JAIL_LAUNCHER_WINDOWS unset or missing' -Fix manual
        Add-SupplyGateCheckResult -Id 'jail.runtime_effect' -Severity warn -Detail "$aiCommands run UNJAILED" -Fix manual
    }

    if ($env:SCP_AI_JAIL_BYPASS -eq '1') {
        Add-SupplyGateCheckResult -Id 'jail.bypass_env' -Severity warn -Detail 'SCP_AI_JAIL_BYPASS=1 is set' -Fix manual
    }
    else {
        Add-SupplyGateCheckResult -Id 'jail.bypass_env' -Severity ok -Detail 'no bypass set' -Fix none
    }
}

function Test-SupplyGateEvidence {
    $paths = Get-SupplyGatePaths
    if (-not (Test-Path -LiteralPath $paths.LogRoot)) {
        Add-SupplyGateCheckResult -Id 'evidence.log_writable' -Severity fail -Detail "missing: $($paths.LogRoot)" -Fix repair
    }
    else {
        $probe = Join-Path $paths.LogRoot ".status-probe.$PID"
        try {
            New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            Add-SupplyGateCheckResult -Id 'evidence.log_writable' -Severity ok -Detail "writable by $env:USERNAME" -Fix none
        }
        catch {
            Add-SupplyGateCheckResult -Id 'evidence.log_writable' -Severity fail -Detail "$($paths.LogRoot) not writable by $env:USERNAME" -Fix repair
        }
    }

    if (-not (Test-Path -LiteralPath $paths.AggregateLog)) {
        Add-SupplyGateCheckResult -Id 'evidence.events' -Severity fail -Detail "missing: $($paths.AggregateLog)" -Fix repair
    }
    else {
        $n = @(Get-Content -LiteralPath $paths.AggregateLog -ErrorAction SilentlyContinue).Count
        if ($n -eq 0) {
            Add-SupplyGateCheckResult -Id 'evidence.events' -Severity warn -Detail 'no events recorded yet' -Fix none
        }
        else {
            Add-SupplyGateCheckResult -Id 'evidence.events' -Severity ok -Detail "$n event(s)" -Fix none
        }
    }
}

function Get-SupplyGateRepairHint {
    if ($Script:CheckScope -eq 'Machine') { return '.\install.ps1 repair -Scope Machine' }
    return '.\install.ps1 repair'
}

function Show-SupplyGateStatusReport {
    param([switch]$Full)
    $policy = Get-SupplyGatePolicy
    $paths = Get-SupplyGatePaths
    Write-Host "Supply Gate -- scope: $Script:CheckScope   mode: $(Get-SupplyGateMode)   policy: $($policy['POLICY_VERSION'])"
    Write-Host "host: $env:COMPUTERNAME   platform: windows   state root: $($paths.StateRoot)"
    Write-Host ''

    $verdict = Get-SupplyGateVerdict
    $ok = @($Script:CheckResults | Where-Object { $_.Severity -eq 'ok' }).Count
    $warn = @($Script:CheckResults | Where-Object { $_.Severity -eq 'warn' }).Count
    $fail = @($Script:CheckResults | Where-Object { $_.Severity -eq 'fail' }).Count

    if ($Full) {
        $section = ''
        foreach ($r in $Script:CheckResults) {
            $sec = $r.Id.Split('.')[0]
            if ($sec -ne $section) { $section = $sec; Write-Host "`n$section" }
            $tag = switch ($r.Severity) { 'ok' { ' ok ' } 'warn' { 'warn' } 'fail' { 'FAIL' } default { ' ?? ' } }
            if ($r.Severity -eq 'fail') {
                Write-Host ('  [{0}] {1,-26} {2}  -> {3}' -f $tag, $r.Id, $r.Detail, $r.Fix)
            }
            else {
                Write-Host ('  [{0}] {1,-26} {2}' -f $tag, $r.Id, $r.Detail)
            }
        }
        Write-Host "`nverdict: $verdict   ($fail fail, $warn warn, $ok ok)"
    }
    else {
        $sections = $Script:CheckResults | Group-Object { $_.Id.Split('.')[0] }
        Write-Host 'Checks:'
        foreach ($grp in $sections) {
            $worstFail = $grp.Group | Where-Object { $_.Severity -eq 'fail' } | Select-Object -First 1
            $worstWarn = $grp.Group | Where-Object { $_.Severity -eq 'warn' } | Select-Object -First 1
            if ($worstFail) { Write-Host ('  [FAIL] {0,-9} ({1})' -f $grp.Name, $worstFail.Id) }
            elseif ($worstWarn) { Write-Host ('  [warn] {0,-9} ({1})' -f $grp.Name, $worstWarn.Id) }
            else { Write-Host "  [ ok ] $($grp.Name)" }
        }
        Write-Host "`nverdict: $verdict   ($fail fail, $warn warn, $ok ok)"
    }

    if ($verdict -eq 'healthy') {
        Write-Host 'Nothing to repair.'
    }
    else {
        $manual = $Script:CheckResults | Where-Object { $_.Severity -eq 'fail' -and $_.Fix -eq 'manual' }
        $repair = $Script:CheckResults | Where-Object { $_.Severity -eq 'fail' -and $_.Fix -eq 'repair' }
        if ($manual) {
            Write-Host "`nManual action required first (repair cannot fix these):"
            foreach ($m in $manual) { Write-Host "  - $($m.Id): $($m.Detail)" }
        }
        if ($repair) {
            Write-Host "`nRepairable -- run:  $(Get-SupplyGateRepairHint)"
            foreach ($r in $repair) { Write-Host "  - $($r.Id)" }
        }
    }
}

function Invoke-SupplyGateStatusRun {
    param(
        [ValidateSet('User', 'Machine')][string]$Scope = 'User',
        [switch]$Full,
        [string]$RepoRoot
    )
    Reset-SupplyGateChecks -Scope $Scope -Full:$Full -RepoRoot $RepoRoot
    $paths = Get-SupplyGatePaths
    if (Test-Path -LiteralPath $paths.StateRoot) { Initialize-SupplyGateLog -Context 'status' } else { Stop-SupplyGateLog }
    Import-SupplyGateRuntimeState | Out-Null
    Write-SupplyGateJsonEvent -Level INFO -Event 'status.started' -Tool 'install.ps1' -Command 'status' -Status 'started' -Detail $Scope

    if (Test-SupplyGateInstall) {
        Test-SupplyGateRuntime
        Test-SupplyGateShims
        Test-SupplyGateShimPath
        Test-SupplyGateConfig
        Test-SupplyGateModeChecks
        Test-SupplyGateJail
        Test-SupplyGateEvidence
    }

    $verdict = Get-SupplyGateVerdict
    $exitCode = Get-SupplyGateVerdictExitCode -Verdict $verdict
    Show-SupplyGateStatusReport -Full:$Full

    $fail = @($Script:CheckResults | Where-Object { $_.Severity -eq 'fail' }).Count
    $warn = @($Script:CheckResults | Where-Object { $_.Severity -eq 'warn' }).Count
    $ok = @($Script:CheckResults | Where-Object { $_.Severity -eq 'ok' }).Count
    Write-SupplyGateJsonEvent -Level INFO -Event 'status.completed' -Tool 'install.ps1' -Command 'status' -Status $verdict -Detail "$fail fail, $warn warn, $ok ok"
    return $exitCode
}

Export-ModuleMember -Function * -Variable @()
