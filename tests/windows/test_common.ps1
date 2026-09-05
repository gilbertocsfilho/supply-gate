# Unit tests for lib/windows/SupplyGate.Common.psm1.
#   powershell.exe -File tests/windows/test_common.ps1
#
# Runs entirely against temp directories via -StateRootOverride / -HomeDir /
# -ConfigDir parameters -- never touches the real registry PATH, the real
# $PROFILE, or C:\ProgramData. Functions that DO touch machine state
# (Add-SupplyGateShimRootToPath, Set-SupplyGateUserProfile, New-Item under a
# real profile) are intentionally not exercised here; see
# docs/windows-support.md for what end-to-end coverage would need.

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

. (Join-Path $ScriptDir 'helpers.ps1')
Import-Module (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Common.psm1') -Force

$FakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "supply-gate-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $FakeRoot | Out-Null
$StateRoot = Join-Path $FakeRoot 'state'

try {
    # =======================================================================
    Write-Output "`n--- policy parsing ---"
    # =======================================================================
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $StateRoot
    $policy = Get-SupplyGatePolicy
    Assert-SupplyGateEqual 'POLICY_VERSION parsed' '1.0.0' $policy['POLICY_VERSION']
    Assert-SupplyGateTrue 'MANAGED_COMMANDS_LIST contains npm' ($policy['MANAGED_COMMANDS_LIST'] -contains 'npm')
    Assert-SupplyGateTrue 'MANAGED_COMMANDS_LIST contains go' ($policy['MANAGED_COMMANDS_LIST'] -contains 'go')
    Assert-SupplyGateTrue 'AI_COMMANDS_LIST contains claude' ($policy['AI_COMMANDS_LIST'] -contains 'claude')
    Assert-SupplyGateTrue 'is AI tool: claude' (Test-SupplyGateIsAiTool -Tool 'claude')
    Assert-SupplyGateFalse 'is AI tool: npm' (Test-SupplyGateIsAiTool -Tool 'npm')
    Assert-SupplyGateTrue 'is package manager: npm' (Test-SupplyGateIsPackageManager -Tool 'npm')

    $localOverlay = Join-Path $FakeRoot 'local-policy.conf'
    Set-Content -LiteralPath $localOverlay -Value 'NPM_REGISTRY_URL="https://npm.internal.example/"'
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -LocalPolicyFile $localOverlay -StateRootOverride $StateRoot
    Assert-SupplyGateEqual 'local overlay overrides a value' 'https://npm.internal.example/' (Get-SupplyGatePolicy)['NPM_REGISTRY_URL']

    # Re-init without overlay for the rest of the tests.
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $StateRoot

    # =======================================================================
    Write-Output "`n--- state paths ---"
    # =======================================================================
    $userPaths = Get-SupplyGateStatePaths -Scope User
    Assert-SupplyGateTrue 'user scope lands under LOCALAPPDATA' ($userPaths.StateRoot -like "*SupplyChainProtect")
    $machinePaths = Get-SupplyGateStatePaths -Scope Machine
    Assert-SupplyGateTrue 'machine scope lands under ProgramData' ($machinePaths.StateRoot -like "*supply-gate")
    Assert-SupplyGateFalse 'user and machine roots differ' ($userPaths.StateRoot -eq $machinePaths.StateRoot)
    $overridden = Get-SupplyGateStatePaths -Scope User -StateRootOverride 'C:\explicit\override'
    Assert-SupplyGateEqual 'StateRootOverride wins' 'C:\explicit\override' $overridden.StateRoot

    # =======================================================================
    Write-Output "`n--- managed blocks ---"
    # =======================================================================
    $npmrc = Join-Path $FakeRoot '.npmrc'
    Set-Content -LiteralPath $npmrc -Value "; alice's own line, must survive`nregistry=https://alice-custom.example/"
    Add-SupplyGateManagedBlock -Path $npmrc -Body "save-exact=true"
    $content = Get-Content -Raw -LiteralPath $npmrc
    Assert-SupplyGateTrue 'managed block added' ($content -match [regex]::Escape((Get-SupplyGateMarkerBegin)))
    Assert-SupplyGateTrue "user's own line preserved after apply" ($content -match "alice's own line")

    # Reapply must replace the block, not duplicate it.
    Add-SupplyGateManagedBlock -Path $npmrc -Body "save-exact=true`nmin-release-age=7"
    $content2 = Get-Content -Raw -LiteralPath $npmrc
    $beginCount = ([regex]::Matches($content2, [regex]::Escape((Get-SupplyGateMarkerBegin)))).Count
    Assert-SupplyGateEqual 'reapply does not duplicate the marker' 1 $beginCount
    Assert-SupplyGateTrue 'reapply picks up new body content' ($content2 -match 'min-release-age=7')

    Assert-SupplyGateTrue 'Test-SupplyGateMarker true when present' (Test-SupplyGateMarker -Path $npmrc)
    Remove-SupplyGateManagedBlock -Path $npmrc
    $content3 = Get-Content -Raw -LiteralPath $npmrc
    Assert-SupplyGateFalse 'Test-SupplyGateMarker false after removal' (Test-SupplyGateMarker -Path $npmrc)
    Assert-SupplyGateTrue "user's own line survives uninstall" ($content3 -match "alice's own line")
    Assert-SupplyGateFalse 'marker text gone after removal' ($content3 -match [regex]::Escape((Get-SupplyGateMarkerBegin)))

    # =======================================================================
    Write-Output "`n--- hard-value placeholder detection ---"
    # =======================================================================
    Assert-SupplyGateTrue 'empty is a placeholder' (Test-SupplyGateHardValuePlaceholder -Value '')
    Assert-SupplyGateTrue 'example.corp is a placeholder' (Test-SupplyGateHardValuePlaceholder -Value 'https://registry.example.corp/npm/')
    Assert-SupplyGateFalse 'a real URL is not a placeholder' (Test-SupplyGateHardValuePlaceholder -Value 'https://npm.internal.example/')

    # The mode being APPLIED wins over the recorded one. This used to ask
    # Get-SupplyGateMode, which re-reads state.json and clobbers whatever
    # Set-SupplyGateMode just set -- so `apply -Mode hard` over an existing soft
    # install skipped the check entirely and installed hard mode with the
    # shipped placeholder registries. tests/windows/e2e.ps1 covers that whole
    # path against a real install; this pins the contract it depends on.
    Set-SupplyGateMode -Mode 'soft'
    Assert-SupplyGateFalse 'hard prereqs fail on the shipped placeholders' `
        (Test-SupplyGateModePrereqs -Mode 'hard')
    Assert-SupplyGateTrue 'soft mode has no prereqs' (Test-SupplyGateModePrereqs -Mode 'soft')

    # =======================================================================
    Write-Output "`n--- real-binary resolution skips our own shim ---"
    # =======================================================================
    $fakePathDir = Join-Path $FakeRoot 'fakepath'
    New-Item -ItemType Directory -Force -Path $fakePathDir | Out-Null
    Set-Content -LiteralPath (Join-Path $fakePathDir 'npm.cmd') -Value "@echo off`r`npowershell.exe -File `"C:\state\runtime\manager-wrapper.ps1`" npm %*"
    $realDir = Join-Path $FakeRoot 'realpath'
    New-Item -ItemType Directory -Force -Path $realDir | Out-Null
    Set-Content -LiteralPath (Join-Path $realDir 'npm.cmd') -Value '@echo off'

    $savedPath = $env:Path
    try {
        $env:Path = "$fakePathDir;$realDir;$savedPath"
        Assert-SupplyGateTrue 'shim detected as managed by content' (Test-SupplyGateManagedShim -Path (Join-Path $fakePathDir 'npm.cmd'))
        $resolved = Find-SupplyGateRealBinary -Tool 'npm'
        Assert-SupplyGateEqual 'resolution skips the shim dir and finds the real one' (Join-Path $realDir 'npm.cmd') $resolved
    }
    finally {
        $env:Path = $savedPath
    }

    # =======================================================================
    Write-Output "`n--- package-manager config (soft mode) ---"
    # =======================================================================
    Set-SupplyGateMode -Mode 'soft'
    $home1 = Join-Path $FakeRoot 'home1'
    New-Item -ItemType Directory -Force -Path $home1 | Out-Null
    Set-SupplyGateNpmConfig -HomeDir $home1
    $npmrcContent = Get-Content -Raw -LiteralPath (Join-Path $home1 '.npmrc')
    Assert-SupplyGateTrue 'soft mode npmrc has no registry override' (-not ($npmrcContent -match 'registry='))
    Assert-SupplyGateTrue 'npmrc carries save-exact' ($npmrcContent -match 'save-exact=true')

    Set-SupplyGateCargoConfig -HomeDir $home1
    $cargoContent = Get-Content -Raw -LiteralPath (Join-Path $home1 '.cargo\config.toml')
    Assert-SupplyGateTrue 'soft mode cargo config uses git-fetch-with-cli' ($cargoContent -match 'git-fetch-with-cli')

    # =======================================================================
    Write-Output "`n--- package-manager config (hard mode) ---"
    # =======================================================================
    Set-SupplyGateMode -Mode 'hard'
    $home2 = Join-Path $FakeRoot 'home2'
    New-Item -ItemType Directory -Force -Path $home2 | Out-Null
    Set-SupplyGateNpmConfig -HomeDir $home2
    $npmrcHard = Get-Content -Raw -LiteralPath (Join-Path $home2 '.npmrc')
    Assert-SupplyGateTrue 'hard mode npmrc sets registry' ($npmrcHard -match [regex]::Escape("registry=$($policy['NPM_REGISTRY_URL'])"))

    Set-SupplyGateCargoConfig -HomeDir $home2
    $cargoHard = Get-Content -Raw -LiteralPath (Join-Path $home2 '.cargo\config.toml')
    Assert-SupplyGateTrue 'hard mode cargo config replaces crates-io' ($cargoHard -match 'replace-with = "corporate"')

    # =======================================================================
    Write-Output "`n--- runtime state / status round-trip ---"
    # =======================================================================
    $unsavedRoot = Join-Path $FakeRoot 'unsaved'
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $unsavedRoot
    Assert-SupplyGateEqual 'mode falls back to policy default before any save' 'soft' (Get-SupplyGateMode)

    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $StateRoot
    New-SupplyGateDirs
    Save-SupplyGateRuntimeState -Mode 'hard'
    $state = Get-SupplyGateRuntimeState
    Assert-SupplyGateEqual 'saved state round-trips EnforcementMode' 'hard' $state.EnforcementMode
    Assert-SupplyGateEqual 'Get-SupplyGateMode reads back saved state' 'hard' (Get-SupplyGateMode)

    Save-SupplyGateStatus -Result 'applied'
    $status = Get-SupplyGateStatus
    Assert-SupplyGateEqual 'saved status round-trips' 'applied' $status.Status

    # =======================================================================
    Write-Output "`n--- JSON event logging ---"
    # =======================================================================
    Initialize-SupplyGateLog -Context 'test'
    Write-SupplyGateJsonEvent -Level 'INFO' -Event 'test.event' -Tool 'npm' -Command 'npm install' -Status 'success' -Detail 'unit test'
    $paths = Get-SupplyGatePaths
    $lastLine = Get-Content -LiteralPath $paths.AggregateLog | Select-Object -Last 1
    $obj = $lastLine | ConvertFrom-Json
    Assert-SupplyGateEqual 'json event tool field' 'npm' $obj.tool
    Assert-SupplyGateEqual 'json event platform field' 'windows' $obj.platform
    Assert-SupplyGateEqual 'json event policy_mode reflects current mode' 'hard' $obj.policy_mode
    Stop-SupplyGateLog

    if (Get-SupplyGateTestSummary) { exit 0 } else { exit 1 }
}
finally {
    Remove-Item -LiteralPath $FakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
