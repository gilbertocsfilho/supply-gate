#Requires -Version 5.1
<#
Native Windows installer -- PowerShell port of install.sh. Same subcommands,
same --scope/--mode contract, same exit-code meaning for `status` (0 healthy,
1 degraded, 2 manual action). Runs under both Windows PowerShell 5.1 and
PowerShell 7 (pwsh).

Usage:
  .\install.ps1 apply [-Mode soft|hard] [-Scope user|machine]
  .\install.ps1 audit [-Scope user|machine]
  .\install.ps1 repair [-Scope user|machine]
  .\install.ps1 status [-Scope user|machine] [-Full]
  .\install.ps1 install-optional-tools
  .\install.ps1 uninstall [-Scope user|machine|all]

See docs/windows-support.md for the architecture this mirrors and the known
gaps versus the POSIX installer (install.sh).
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('apply', 'audit', 'repair', 'status', 'install-optional-tools', 'uninstall', 'help')]
    [string]$Command = 'help',

    [ValidateSet('user', 'machine', 'all')]
    [string]$Scope,

    [ValidateSet('soft', 'hard')]
    [string]$Mode,

    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'lib\windows\SupplyGate.Common.psm1') -Force
Import-Module (Join-Path $RepoRoot 'lib\windows\SupplyGate.Checks.psm1') -Force

function Show-SupplyGateUsage {
    @'
Usage:
  .\install.ps1 apply [-Mode soft|hard] [-Scope user|machine]
  .\install.ps1 audit [-Scope user|machine]
  .\install.ps1 repair [-Scope user|machine]
  .\install.ps1 status [-Scope user|machine] [-Full]
  .\install.ps1 install-optional-tools
  .\install.ps1 uninstall [-Scope user|machine|all]

  status          read-only integrity report. Exit 0 = healthy, 1 = degraded
                  (run 'repair'), 2 = manual action required. -Full lists
                  every individual check instead of a per-section summary.

  -Scope user     (default) apply only to the current user
  -Scope machine  apply to all local users and the AllUsersAllHosts PowerShell
                  profile layer; requires an elevated (Run as Administrator)
                  session
  -Scope all      uninstall only: alias for machine scope. Removes the
                  machine-wide layer plus every local user's config.
'@ | Write-Output
}

function Assert-SupplyGateAdmin {
    if (-not (Test-SupplyGateIsAdministrator)) {
        Write-Error 'ERROR: this scope requires an elevated session (Run as Administrator)'
        exit 1
    }
}

function Get-SupplyGatePolicyFiles {
    $default = Join-Path $RepoRoot 'policy\default-policy.conf'
    $local = Join-Path $RepoRoot 'policy\local-policy.conf'
    if (Test-Path -LiteralPath $local) {
        return @{ Default = $default; Local = $local }
    }
    return @{ Default = $default; Local = $null }
}

function Install-SupplyGateRuntimeFiles {
    $paths = Get-SupplyGatePaths
    Copy-Item -Path (Join-Path $RepoRoot 'lib\windows\SupplyGate.Common.psm1') -Destination $paths.CommonRuntime -Force
    Copy-Item -Path (Join-Path $RepoRoot 'shims\windows\manager-wrapper.ps1') -Destination $paths.WrapperBin -Force
    $files = Get-SupplyGatePolicyFiles
    $content = Get-Content -LiteralPath $files.Default -Raw
    if ($files.Local) {
        $content += "`n`n# Local overrides applied at install time`n" + (Get-Content -LiteralPath $files.Local -Raw)
    }
    Set-Content -LiteralPath $paths.PolicyRuntime -Value $content -Encoding UTF8
}

# Shims are one .cmd per managed tool, unconditionally, whether or not the
# real binary is on PATH right now: the wrapper resolves it live on every
# invocation, so a tool installed later is intercepted with no reapply.
# Mirrors create_shims in install.sh.
function New-SupplyGateToolShims {
    $policy = Get-SupplyGatePolicy
    $paths = Get-SupplyGatePaths
    foreach ($tool in $policy['MANAGED_COMMANDS_LIST']) {
        $shimPath = Join-Path $paths.ShimRoot "$tool.cmd"
        $content = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($paths.WrapperBin)`" $tool %*`r`n"
        Set-Content -LiteralPath $shimPath -Value $content -Encoding ASCII -NoNewline
    }
}

# ===========================================================================
# apply
# ===========================================================================
function Invoke-ApplyUserCmd {
    Initialize-SupplyGateLog -Context 'apply'
    Write-SupplyGateInfo "Applying policy mode: $script:EnforcementModeArg (scope: user)"
    Write-SupplyGateJsonEvent -Level INFO -Event 'apply.started' -Tool 'install.ps1' -Command 'apply' -Status started -Detail $script:EnforcementModeArg
    New-SupplyGateDirs
    Set-SupplyGateMode -Mode $script:EnforcementModeArg
    if ($script:EnforcementModeArg -eq 'hard' -and -not (Test-SupplyGateModePrereqs)) {
        Write-SupplyGateJsonEvent -Level ERROR -Event 'apply.completed' -Tool 'install.ps1' -Command 'apply' -Status failure -Detail 'hard mode prereqs not met'
        exit 1
    }
    Install-SupplyGateRuntimeFiles
    Save-SupplyGateRuntimeState -Mode $script:EnforcementModeArg
    New-SupplyGateToolShims
    Set-SupplyGateUserProfile
    Set-SupplyGateNpmConfig
    Set-SupplyGateBunConfig
    Set-SupplyGatePipConfig
    Set-SupplyGateCargoConfig
    Set-SupplyGateGoConfig | Out-Null
    Save-SupplyGateStatus -Result 'applied'
    Write-SupplyGateInfo 'Policy applied. Open a new shell to pick up PATH changes.'
    Write-SupplyGateJsonEvent -Level INFO -Event 'apply.completed' -Tool 'install.ps1' -Command 'apply' -Status success -Detail 'policy applied'
}

function Invoke-ApplyMachineCmd {
    Assert-SupplyGateAdmin
    Initialize-SupplyGateLog -Context 'apply'
    Write-SupplyGateInfo "Applying policy mode: $script:EnforcementModeArg (scope: machine)"
    Write-SupplyGateJsonEvent -Level INFO -Event 'apply.started' -Tool 'install.ps1' -Command 'apply-machine' -Status started -Detail $script:EnforcementModeArg
    New-SupplyGateDirs
    Set-SupplyGateMode -Mode $script:EnforcementModeArg
    if ($script:EnforcementModeArg -eq 'hard' -and -not (Test-SupplyGateModePrereqs)) {
        Write-SupplyGateJsonEvent -Level ERROR -Event 'apply.completed' -Tool 'install.ps1' -Command 'apply-machine' -Status failure -Detail 'hard mode prereqs not met'
        exit 1
    }
    Install-SupplyGateRuntimeFiles
    Save-SupplyGateRuntimeState -Mode $script:EnforcementModeArg
    New-SupplyGateToolShims
    Set-SupplyGateSystemProfiles
    # configure_go writes machine-wide GOENV; non-fatal like the POSIX side.
    Set-SupplyGateGoConfig | Out-Null

    # Applies to every local profile, including the invoking admin's own --
    # unlike list_local_users (which excludes root and is applied separately
    # from it), Windows has no root/non-root split worth mirroring here.
    foreach ($u in (Get-SupplyGateLocalUsers)) {
        Write-SupplyGateInfo "Configuring user: $($u.Name) ($($u.Home))"
        try {
            Set-SupplyGatePackageConfigsForHome -HomeDir $u.Home -ConfigDir (Join-Path $u.Home 'AppData\Roaming')
        }
        catch {
            Write-SupplyGateWarn "Failed to configure user: $($u.Name)"
        }
    }
    Save-SupplyGateStatus -Result 'applied'
    Write-SupplyGateInfo 'Machine-scope policy applied. Users must start a new session to pick up PATH changes.'
    Write-SupplyGateJsonEvent -Level INFO -Event 'apply.completed' -Tool 'install.ps1' -Command 'apply-machine' -Status success -Detail 'machine scope'
}

function Invoke-ApplySubcommand {
    if ($Scope -eq 'all') {
        Write-Error 'ERROR: -Scope all is only supported by uninstall'
        exit 2
    }
    $resolvedScope = if ($Scope) { $Scope } else { 'user' }
    $psScope = if ($resolvedScope -eq 'machine') { 'Machine' } else { 'User' }
    $files = Get-SupplyGatePolicyFiles
    Initialize-SupplyGate -Scope $psScope -PolicyFile $files.Default -LocalPolicyFile $files.Local
    $script:EnforcementModeArg = if ($Mode) { $Mode } else { (Get-SupplyGatePolicy)['DEFAULT_MODE'] }
    if ($psScope -eq 'Machine') { Invoke-ApplyMachineCmd } else { Invoke-ApplyUserCmd }
}

# ===========================================================================
# audit -- a stricter binary compliance signal (exit 0/1 only), independent
# of the 3-tier status verdict. Mirrors audit_user_cmd/audit_machine_cmd,
# which are deliberately a separate, narrower check than lib/checks.sh.
# ===========================================================================
function Invoke-AuditUserCmd {
    Initialize-SupplyGateLog -Context 'audit'
    Import-SupplyGateRuntimeState | Out-Null
    $mode = Get-SupplyGateMode
    $failures = 0
    Write-SupplyGateInfo "Auditing local hardening state in mode: $mode"
    Write-SupplyGateJsonEvent -Level INFO -Event 'audit.started' -Tool 'install.ps1' -Command 'audit' -Status started -Detail $mode

    $paths = Get-SupplyGatePaths
    foreach ($f in @($paths.CommonRuntime, $paths.WrapperBin, $paths.RunstateFile, $paths.ProfileSnippet)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-SupplyGateErr "Missing required runtime file: $f"
            $failures++
        }
    }
    if (-not (Test-SupplyGateMarker -Path $PROFILE.CurrentUserAllHosts)) {
        Write-SupplyGateWarn 'Managed profile block missing from $PROFILE.CurrentUserAllHosts'
    }
    foreach ($pair in @(
            @{ Label = '.npmrc'; Path = (Join-Path $env:USERPROFILE '.npmrc') },
            @{ Label = '.bunfig.toml'; Path = (Join-Path $env:USERPROFILE '.bunfig.toml') },
            @{ Label = 'pip.ini'; Path = (Join-Path $env:APPDATA 'pip\pip.ini') },
            @{ Label = 'cargo config'; Path = (Join-Path $env:USERPROFILE '.cargo\config.toml') }
        )) {
        if (-not (Test-SupplyGateMarker -Path $pair.Path)) {
            Write-SupplyGateErr "Managed block missing from $($pair.Label)"
            $failures++
        }
    }

    if ($mode -eq 'hard') {
        if (-not (Test-SupplyGateModePrereqs)) { $failures++ }
        $policy = Get-SupplyGatePolicy
        $go = Find-SupplyGateRealBinary -Tool 'go'
        if ($go) {
            & $go version *> $null
            if ($LASTEXITCODE -eq 0) {
                $eff = ((& $go env GOPROXY 2>$null) -join '').Trim()
                if ($eff -ne $policy['GO_PROXY_URL']) {
                    Write-SupplyGateErr 'GOPROXY drift detected'
                    $failures++
                }
            }
        }
    }

    foreach ($tool in (Get-SupplyGatePolicy)['MANAGED_COMMANDS_LIST']) {
        if (-not (Test-Path -LiteralPath (Join-Path $paths.ShimRoot "$tool.cmd"))) {
            Write-SupplyGateErr "Missing shim for: $tool"
            $failures++
        }
    }
    if (-not (Test-Path -LiteralPath $paths.AggregateLog)) {
        Write-SupplyGateErr 'Aggregate JSONL log missing'
        $failures++
    }

    if ($failures -gt 0) {
        Save-SupplyGateStatus -Result 'non-compliant'
        Write-SupplyGateErr "Audit failed with $failures issue(s)"
        Write-SupplyGateJsonEvent -Level ERROR -Event 'audit.completed' -Tool 'install.ps1' -Command 'audit' -Status failure -Detail "$failures issues"
        exit 1
    }
    Save-SupplyGateStatus -Result 'compliant'
    Write-SupplyGateInfo 'Audit passed'
    Write-SupplyGateJsonEvent -Level INFO -Event 'audit.completed' -Tool 'install.ps1' -Command 'audit' -Status success -Detail 'compliant'
}

function Invoke-AuditMachineCmd {
    Assert-SupplyGateAdmin
    Initialize-SupplyGateLog -Context 'audit'
    Import-SupplyGateRuntimeState | Out-Null
    $mode = Get-SupplyGateMode
    $failures = 0
    Write-SupplyGateInfo "Auditing machine-scope hardening state in mode: $mode"
    Write-SupplyGateJsonEvent -Level INFO -Event 'audit.started' -Tool 'install.ps1' -Command 'audit-machine' -Status started -Detail $mode

    $paths = Get-SupplyGatePaths
    foreach ($f in @($paths.CommonRuntime, $paths.WrapperBin, $paths.RunstateFile, $paths.ProfileSnippet)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-SupplyGateErr "Missing required runtime file: $f"
            $failures++
        }
    }
    $anyProfile = $false
    foreach ($p in (Get-SupplyGateAllUsersProfilePaths)) {
        if (Test-SupplyGateMarker -Path $p) { $anyProfile = $true }
    }
    if (-not $anyProfile) {
        Write-SupplyGateErr 'Missing managed block in every AllUsersAllHosts PowerShell profile'
        $failures++
    }
    foreach ($tool in (Get-SupplyGatePolicy)['MANAGED_COMMANDS_LIST']) {
        if (-not (Test-Path -LiteralPath (Join-Path $paths.ShimRoot "$tool.cmd"))) {
            Write-SupplyGateErr "Missing shim for: $tool"
            $failures++
        }
    }
    if (-not (Test-Path -LiteralPath $paths.AggregateLog)) {
        Write-SupplyGateErr 'Aggregate JSONL log missing'
        $failures++
    }
    foreach ($u in (Get-SupplyGateLocalUsers)) {
        if (-not (Test-SupplyGateMarker -Path (Join-Path $u.Home '.npmrc'))) {
            Write-SupplyGateWarn "npmrc missing managed block: $($u.Name)"
        }
    }
    if ($mode -eq 'hard' -and -not (Test-SupplyGateModePrereqs)) { $failures++ }

    if ($failures -gt 0) {
        Save-SupplyGateStatus -Result 'non-compliant'
        Write-SupplyGateErr "Audit failed with $failures issue(s)"
        Write-SupplyGateJsonEvent -Level ERROR -Event 'audit.completed' -Tool 'install.ps1' -Command 'audit-machine' -Status failure -Detail "$failures issues"
        exit 1
    }
    Save-SupplyGateStatus -Result 'compliant'
    Write-SupplyGateInfo 'Machine-scope audit passed'
    Write-SupplyGateJsonEvent -Level INFO -Event 'audit.completed' -Tool 'install.ps1' -Command 'audit-machine' -Status success -Detail 'compliant'
}

function Invoke-AuditSubcommand {
    if ($Scope -eq 'all') {
        Write-Error 'ERROR: -Scope all is only supported by uninstall'
        exit 2
    }
    $resolvedScope = if ($Scope) { $Scope } else { 'user' }
    $psScope = if ($resolvedScope -eq 'machine') { 'Machine' } else { 'User' }
    $files = Get-SupplyGatePolicyFiles
    Initialize-SupplyGate -Scope $psScope -PolicyFile $files.Default -LocalPolicyFile $files.Local
    if ($psScope -eq 'Machine') { Invoke-AuditMachineCmd } else { Invoke-AuditUserCmd }
}

# ===========================================================================
# repair -- re-runs apply with the currently-recorded mode. Scope resolution
# mirrors repair_cmd: an explicit -Scope wins; otherwise, elevated + an
# existing machine install infers machine, so `repair` run as admin after a
# machine apply doesn't silently do a user-scope apply instead.
# ===========================================================================
function Invoke-RepairSubcommand {
    $resolvedScope = $Scope
    if (-not $resolvedScope -and (Test-SupplyGateIsAdministrator) -and (Test-Path -LiteralPath (Join-Path $env:ProgramData 'supply-gate'))) {
        $resolvedScope = 'machine'
        Write-Output 'No -Scope given, running elevated, and a machine-scope install was detected; repairing machine scope'
    }
    if (-not $resolvedScope) { $resolvedScope = 'user' }
    $psScope = if ($resolvedScope -eq 'machine') { 'Machine' } else { 'User' }
    $files = Get-SupplyGatePolicyFiles
    Initialize-SupplyGate -Scope $psScope -PolicyFile $files.Default -LocalPolicyFile $files.Local
    Import-SupplyGateRuntimeState | Out-Null
    $script:EnforcementModeArg = Get-SupplyGateMode
    if ($psScope -eq 'Machine') { Invoke-ApplyMachineCmd } else { Invoke-ApplyUserCmd }
}

# ===========================================================================
# status
# ===========================================================================
function Invoke-StatusSubcommand {
    $resolvedScope = $Scope
    if (-not $resolvedScope) {
        $files = Get-SupplyGatePolicyFiles
        Initialize-SupplyGate -Scope User -PolicyFile $files.Default -LocalPolicyFile $files.Local
        $userPaths = Get-SupplyGatePaths
        if (-not (Test-Path -LiteralPath $userPaths.StateRoot) -and (Test-Path -LiteralPath (Join-Path $env:ProgramData 'supply-gate'))) {
            $resolvedScope = 'machine'
        }
        else {
            $resolvedScope = 'user'
        }
    }
    $psScope = if ($resolvedScope -eq 'machine') { 'Machine' } else { 'User' }
    $files = Get-SupplyGatePolicyFiles
    Initialize-SupplyGate -Scope $psScope -PolicyFile $files.Default -LocalPolicyFile $files.Local
    $exitCode = Invoke-SupplyGateStatusRun -Scope $psScope -Full:$Full -RepoRoot $RepoRoot
    exit $exitCode
}

# ===========================================================================
# uninstall
# ===========================================================================
function Invoke-UninstallUserCmd {
    Initialize-SupplyGateLog -Context 'uninstall'
    Write-SupplyGateInfo 'Removing managed profile block and local state'
    Remove-SupplyGateUserProfile
    Remove-SupplyGatePackageConfigsForHome -HomeDir $env:USERPROFILE -ConfigDir $env:APPDATA
    $paths = Get-SupplyGatePaths
    Stop-SupplyGateLog
    if (Test-Path -LiteralPath $paths.StateRoot) { Remove-Item -LiteralPath $paths.StateRoot -Recurse -Force }
    Write-Output 'Uninstall complete'
}

function Invoke-UninstallMachineCmd {
    Assert-SupplyGateAdmin
    Initialize-SupplyGateLog -Context 'uninstall'
    Write-SupplyGateInfo 'Removing machine-scope managed blocks and system state'
    Write-SupplyGateJsonEvent -Level INFO -Event 'uninstall.started' -Tool 'install.ps1' -Command 'uninstall-machine' -Status started -Detail 'machine scope'
    Remove-SupplyGateSystemProfiles
    foreach ($u in (Get-SupplyGateLocalUsers)) {
        Write-SupplyGateInfo "Removing from user: $($u.Name) ($($u.Home))"
        try {
            Remove-SupplyGatePackageConfigsForHome -HomeDir $u.Home -ConfigDir (Join-Path $u.Home 'AppData\Roaming')
        }
        catch {
            Write-SupplyGateWarn "Failed to fully remove config for user: $($u.Name)"
        }
    }
    $paths = Get-SupplyGatePaths
    Write-SupplyGateInfo 'Machine-scope uninstall complete'
    Write-SupplyGateJsonEvent -Level INFO -Event 'uninstall.completed' -Tool 'install.ps1' -Command 'uninstall-machine' -Status success -Detail 'machine scope'
    Stop-SupplyGateLog
    if (Test-Path -LiteralPath $paths.StateRoot) { Remove-Item -LiteralPath $paths.StateRoot -Recurse -Force }
}

function Invoke-UninstallSubcommand {
    $resolvedScope = $Scope
    if (-not $resolvedScope -and (Test-SupplyGateIsAdministrator)) {
        $resolvedScope = 'machine'
        Write-Output 'No -Scope given and running elevated; defaulting uninstall to machine scope'
    }
    if (-not $resolvedScope) { $resolvedScope = 'user' }
    $psScope = if ($resolvedScope -in 'machine', 'all') { 'Machine' } else { 'User' }
    $files = Get-SupplyGatePolicyFiles
    Initialize-SupplyGate -Scope $psScope -PolicyFile $files.Default -LocalPolicyFile $files.Local
    if ($psScope -eq 'Machine') { Invoke-UninstallMachineCmd } else { Invoke-UninstallUserCmd }
}

function Invoke-OptionalToolsSubcommand {
    # scfw/bumblebee have no Windows upstream support; install.sh treats this
    # identically (log_warn + success, never fails apply/repair on it).
    Write-Output 'scfw/bumblebee installation is not supported on Windows; nothing to do.'
}

switch ($Command) {
    'apply' { Invoke-ApplySubcommand }
    'audit' { Invoke-AuditSubcommand }
    'repair' { Invoke-RepairSubcommand }
    'status' { Invoke-StatusSubcommand }
    'install-optional-tools' { Invoke-OptionalToolsSubcommand }
    'uninstall' { Invoke-UninstallSubcommand }
    default { Show-SupplyGateUsage }
}
