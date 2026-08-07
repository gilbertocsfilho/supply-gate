# Unit tests for lib/windows/SupplyGate.Checks.psm1.
#   powershell.exe -File tests/windows/test_checks.ps1
#
# Builds a complete, healthy fake install under a temp StateRootOverride (like
# tests/test_checks.sh's make_install), then breaks one piece at a time and
# checks the verdict/exit-code contract.

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

. (Join-Path $ScriptDir 'helpers.ps1')
Import-Module (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Common.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Checks.psm1') -Force

$FakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "supply-gate-checktest-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $FakeRoot | Out-Null
$StateRoot = Join-Path $FakeRoot 'state'

function New-FakeInstall {
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $StateRoot
    if (Test-Path -LiteralPath $StateRoot) { Remove-Item -LiteralPath $StateRoot -Recurse -Force }
    New-SupplyGateDirs
    $paths = Get-SupplyGatePaths
    Copy-Item -Path (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Common.psm1') -Destination $paths.CommonRuntime -Force
    Copy-Item -Path (Join-Path $ProjectRoot 'shims\windows\manager-wrapper.ps1') -Destination $paths.WrapperBin -Force
    Copy-Item -Path (Join-Path $ProjectRoot 'policy\default-policy.conf') -Destination $paths.PolicyRuntime -Force
    Set-Content -LiteralPath $paths.ProfileSnippet -Value "`$env:Path = `"$($paths.ShimRoot);`$env:Path`""
    foreach ($tool in (Get-SupplyGatePolicy)['MANAGED_COMMANDS_LIST']) {
        Set-Content -LiteralPath (Join-Path $paths.ShimRoot "$tool.cmd") -Value "@echo off`r`npowershell.exe -File `"$($paths.WrapperBin)`" $tool %*"
    }
    Set-Content -LiteralPath $paths.AggregateLog -Value ''
    Save-SupplyGateRuntimeState -Mode 'soft'
}

try {
    # =======================================================================
    Write-Output "`n--- verdict and exit codes (record-level, no filesystem) ---"
    # =======================================================================
    Reset-SupplyGateChecks -Scope User
    Add-SupplyGateCheckResult -Id 'a.one' -Severity ok -Detail 'fine'
    Assert-SupplyGateEqual 'all ok -> healthy' 'healthy' (Get-SupplyGateVerdict)
    Assert-SupplyGateEqual 'healthy -> exit 0' 0 (Get-SupplyGateVerdictExitCode -Verdict (Get-SupplyGateVerdict))

    Reset-SupplyGateChecks -Scope User
    Add-SupplyGateCheckResult -Id 'a.one' -Severity fail -Detail 'broken' -Fix repair
    Assert-SupplyGateEqual 'repairable fail -> degraded' 'degraded' (Get-SupplyGateVerdict)
    Assert-SupplyGateEqual 'degraded -> exit 1' 1 (Get-SupplyGateVerdictExitCode -Verdict (Get-SupplyGateVerdict))

    Reset-SupplyGateChecks -Scope User
    Add-SupplyGateCheckResult -Id 'a.one' -Severity fail -Detail 'broken' -Fix manual
    Assert-SupplyGateEqual 'manual fail -> action_required' 'action_required' (Get-SupplyGateVerdict)
    Assert-SupplyGateEqual 'action_required -> exit 2' 2 (Get-SupplyGateVerdictExitCode -Verdict (Get-SupplyGateVerdict))

    Reset-SupplyGateChecks -Scope User
    Add-SupplyGateCheckResult -Id 'a.one' -Severity fail -Detail 'repairable' -Fix repair
    Add-SupplyGateCheckResult -Id 'b.two' -Severity fail -Detail 'manual' -Fix manual
    Assert-SupplyGateEqual 'a manual fail outranks a repairable one' 'action_required' (Get-SupplyGateVerdict)

    # =======================================================================
    Write-Output "`n--- healthy install passes every check ---"
    # =======================================================================
    New-FakeInstall
    Reset-SupplyGateChecks -Scope User -RepoRoot $ProjectRoot
    Test-SupplyGateInstall | Out-Null
    Test-SupplyGateRuntime
    Test-SupplyGateShims
    $fails = Get-SupplyGateCheckResults | Where-Object { $_.Severity -eq 'fail' }
    Assert-SupplyGateEqual 'fresh fake install: runtime+shims have no failures' 0 @($fails).Count

    # =======================================================================
    Write-Output "`n--- runtime hash drift is detected ---"
    # =======================================================================
    New-FakeInstall
    $paths = Get-SupplyGatePaths
    Add-Content -LiteralPath $paths.CommonRuntime -Value "`n# drifted"
    Reset-SupplyGateChecks -Scope User -RepoRoot $ProjectRoot
    Test-SupplyGateRuntime
    $drift = Get-SupplyGateCheckResults | Where-Object { $_.Id -eq 'runtime.common_current' }
    Assert-SupplyGateEqual 'drifted common runtime is flagged fail' 'fail' $drift.Severity

    # =======================================================================
    Write-Output "`n--- missing shim is detected and named ---"
    # =======================================================================
    New-FakeInstall
    $paths = Get-SupplyGatePaths
    Remove-Item -LiteralPath (Join-Path $paths.ShimRoot 'npm.cmd') -Force
    Reset-SupplyGateChecks -Scope User -RepoRoot $ProjectRoot
    Test-SupplyGateShims
    $shimFail = Get-SupplyGateCheckResults | Where-Object { $_.Id -eq 'shim.present' }
    Assert-SupplyGateEqual 'missing shim -> fail' 'fail' $shimFail.Severity
    Assert-SupplyGateTrue 'missing shim names npm' ($shimFail.Detail -match 'npm')

    # =======================================================================
    Write-Output "`n--- hard mode with placeholder registries fails closed ---"
    # =======================================================================
    New-FakeInstall
    Save-SupplyGateRuntimeState -Mode 'hard'
    Reset-SupplyGateChecks -Scope User -RepoRoot $ProjectRoot
    Test-SupplyGateModeChecks
    $modeFail = Get-SupplyGateCheckResults | Where-Object { $_.Id -eq 'mode.registries' }
    Assert-SupplyGateEqual 'placeholder registries in hard mode -> fail' 'fail' $modeFail.Severity
    Assert-SupplyGateEqual 'placeholder registries are a manual fix, not repair' 'manual' $modeFail.Fix

    # =======================================================================
    Write-Output "`n--- full status run is robust end to end ---"
    # =======================================================================
    # Test-SupplyGateShimPath/Test-SupplyGateConfig read the REAL user PATH
    # and REAL %USERPROFILE% dotfiles (they are not parameterized for
    # override, same as lib/checks.sh's check_path/check_config reading the
    # real $HOME) -- so a temp-dir fake install cannot be asserted "healthy"
    # end to end without touching the real machine, which this test suite
    # deliberately does not do. What IS asserted: the full run composes
    # cleanly against a fake install (no exception) and returns one of the
    # three documented exit codes. install.sh's own tests/docker/run.sh plays
    # the equivalent full-machine role on the POSIX side; there is no Windows
    # container available to do the same here (see docs/windows-support.md).
    New-FakeInstall
    $out = Invoke-SupplyGateStatusRun -Scope User -RepoRoot $ProjectRoot | Select-Object -Last 1
    Assert-SupplyGateTrue 'status run returns a documented exit code' ($out -in 0, 1, 2)

    if (Get-SupplyGateTestSummary) { exit 0 } else { exit 1 }
}
finally {
    Remove-Item -LiteralPath $FakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
