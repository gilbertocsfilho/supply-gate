# End-to-end check of the shim -> manager-wrapper.ps1 -> real-binary chain,
# entirely inside a throwaway temp directory: a fake npm.cmd stands in for
# the real binary (no network, no real npm needed), and PATH is set only for
# the child cmd.exe process this test launches -- the real user/machine PATH
# is never touched. This is the riskiest boundary in the port (cmd.exe's %*
# argument expansion feeding PowerShell's automatic $args), so it gets a real
# run instead of only being reasoned about. Mirrors step 6 ("wrapper really
# runs") of tests/docker/scenario.sh on the POSIX side.
#
#   powershell.exe -File tests/windows/test_wrapper.ps1

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

. (Join-Path $ScriptDir 'helpers.ps1')
Import-Module (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Common.psm1') -Force

$FakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "supply-gate-wraptest-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $FakeRoot | Out-Null
$StateRoot = Join-Path $FakeRoot 'state'
$RealDir = Join-Path $FakeRoot 'real'
New-Item -ItemType Directory -Force -Path $RealDir | Out-Null

try {
    Initialize-SupplyGate -Scope User -PolicyFile (Join-Path $ProjectRoot 'policy\default-policy.conf') -StateRootOverride $StateRoot
    New-SupplyGateDirs
    $paths = Get-SupplyGatePaths
    Copy-Item -Path (Join-Path $ProjectRoot 'lib\windows\SupplyGate.Common.psm1') -Destination $paths.CommonRuntime -Force
    Copy-Item -Path (Join-Path $ProjectRoot 'shims\windows\manager-wrapper.ps1') -Destination $paths.WrapperBin -Force
    Copy-Item -Path (Join-Path $ProjectRoot 'policy\default-policy.conf') -Destination $paths.PolicyRuntime -Force
    Set-Content -LiteralPath (Join-Path $paths.ShimRoot 'npm.cmd') -Value "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($paths.WrapperBin)`" npm %*`r`n"
    Set-Content -LiteralPath $paths.AggregateLog -Value ''
    Save-SupplyGateRuntimeState -Mode 'soft'

    # Fake npm: interception is observable with no network and no real npm.
    Set-Content -LiteralPath (Join-Path $RealDir 'npm.cmd') -Value "@echo off`r`necho REAL-NPM-RAN args=%*`r`n"

    $savedPath = $env:Path
    $savedEap = $ErrorActionPreference
    try {
        # Order matters: shim dir first, so the wrapper's own resolution logic
        # (not PATH order alone) is what has to skip past it.
        $env:Path = "$($paths.ShimRoot);$RealDir;$savedPath"
        # 'Continue' for this one call: Windows PowerShell turns ANY stderr
        # line from a native command into a terminating error under 'Stop',
        # which would abort here on cmd.exe's own harmless warnings before we
        # ever see the real output.
        $ErrorActionPreference = 'Continue'
        $output = & cmd.exe /c 'npm.cmd install lodash --save' 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:Path = $savedPath
        $ErrorActionPreference = $savedEap
    }
    Write-Output "--- raw shim output (exit $exitCode) ---"
    Write-Output $output
    Write-Output '--- end raw shim output ---'

    Assert-SupplyGateEqual 'shim invocation exits 0' 0 $exitCode
    Assert-SupplyGateTrue 'real npm ran with args intact' (($output -join "`n") -match 'REAL-NPM-RAN args=install lodash --save')

    $events = Get-Content -LiteralPath $paths.AggregateLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    $npmEvent = $events | Where-Object { $_.tool -eq 'npm' -and $_.event -eq 'command.completed' }
    Assert-SupplyGateTrue 'npm event recorded in events.jsonl' ($null -ne $npmEvent)
    Assert-SupplyGateEqual 'event reports success' 'success' $npmEvent.status
    Assert-SupplyGateEqual 'event attributed to current user' $env:USERNAME $npmEvent.user

    if (Get-SupplyGateTestSummary) { exit 0 } else { exit 1 }
}
finally {
    Remove-Item -LiteralPath $FakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
