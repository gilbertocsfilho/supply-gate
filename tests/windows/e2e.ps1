# End-to-end scenario for a REAL Windows machine.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\windows\e2e.ps1
#
# tests/windows/run.ps1 is the temp-dir-only unit suite: by design it never
# touches the real registry PATH, the real $PROFILE or %LOCALAPPDATA%. That
# leaves exactly the layer docs/windows-support.md says only a real box can
# cover -- and the two bugs it documents (a status exit code swallowed by
# PowerShell's success stream, a shim chain that only breaks when actually
# invoked) both hid below that line. This is that layer, run on a disposable
# Windows host: install for real at user scope, resolve a shim off the real
# persisted PATH, then uninstall and prove nothing is left.
#
# Machine scope is deliberately not exercised here: it rewrites the system
# PATH and the AllUsersAllHosts profile of the runner itself. User scope
# covers the same code paths that can be asserted without that blast radius.

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ($env:SCP_TEST_ALLOW_DESTRUCTIVE -ne '1') {
    Write-Output 'REFUSING: this installs Supply Gate for real (user scope: real PATH, real $PROFILE).'
    Write-Output 'Set SCP_TEST_ALLOW_DESTRUCTIVE=1 only on a disposable Windows host.'
    exit 1
}

$script:Pass = 0
$script:Fail = 0
function Ok($m)   { $script:Pass++; Write-Output "  PASS  $m" }
function No($m)   { $script:Fail++; Write-Output "  FAIL  $m" }
function Step($m) { Write-Output ''; Write-Output "=== $m ===" }

# Exit code of install.ps1, with its output kept for assertions. Run in a child
# powershell.exe so `exit` inside it cannot take this script down with it.
$script:LastOut = ''
function Invoke-Sg {
    param([Parameter(ValueFromRemainingArguments)][string[]]$SgArgs)
    $installer = Join-Path $RepoRoot 'install.ps1'
    $script:LastOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @SgArgs 2>&1 | Out-String)
    return $LASTEXITCODE
}
function Assert-Exit($label, $expected, $actual) {
    if ($expected -eq $actual) { Ok "$label (exit $actual)" }
    else {
        No "$label (exit $actual, expected $expected)"
        Write-Output ($script:LastOut -split "`n" | Select-Object -Last 20 | ForEach-Object { "    $_" })
    }
}

$paths = $null
$FakeRealDir = Join-Path ([System.IO.Path]::GetTempPath()) "supply-gate-e2e-real-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $FakeRealDir | Out-Null

try {
    Import-Module (Join-Path $RepoRoot 'lib\windows\SupplyGate.Common.psm1') -Force
    $paths = Get-SupplyGateStatePaths -Scope User

    Step '0. preconditions'
    Ok "PowerShell $($PSVersionTable.PSVersion) on $([System.Environment]::OSVersion.VersionString)"
    if (Test-Path -LiteralPath $paths.StateRoot) {
        Remove-Item -LiteralPath $paths.StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    # A managed command no runner ships, so the real npm/pip on the box are
    # never shadowed by the fake used to observe interception.
    Set-Content -LiteralPath (Join-Path $FakeRealDir 'bun.cmd') `
        -Value "@echo off`r`necho REAL-BUN-RAN args=%*`r`n" -Encoding ASCII

    Step '1. status before install'
    Assert-Exit 'status reports not installed' 2 (Invoke-Sg status)

    Step '2. apply -Scope user -Mode soft'
    Assert-Exit 'apply' 0 (Invoke-Sg apply -Scope user -Mode soft)

    Step '3. status after apply'
    Assert-Exit 'status healthy' 0 (Invoke-Sg status)
    # The exact bug docs/windows-support.md records: the report used to be
    # swallowed into the return value and the exit code silently coerced to 0.
    if ($script:LastOut -match 'verdict') { Ok 'status actually printed its report' }
    else { No 'status printed no report (success stream swallowed it?)' }

    Step '4. audit'
    Assert-Exit 'audit' 0 (Invoke-Sg audit)

    Step '5. the runtime and shims exist on disk'
    foreach ($f in @($paths.CommonRuntime, $paths.WrapperBin, $paths.RunstateFile, $paths.ProfileSnippet)) {
        if (Test-Path -LiteralPath $f) { Ok "present: $(Split-Path -Leaf $f)" }
        else { No "missing: $f" }
    }
    foreach ($t in @('npm', 'pip', 'cargo', 'go', 'claude')) {
        if (Test-Path -LiteralPath (Join-Path $paths.ShimRoot "$t.cmd")) { Ok "shim present: $t.cmd" }
        else { No "shim missing: $t.cmd" }
    }

    Step '6. the shim dir is on the persisted user PATH'
    # The registry value, not this process's $env:Path: that is what a new
    # cmd.exe window will actually get.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and ($userPath -split ';' | Where-Object { $_ -eq $paths.ShimRoot })) {
        Ok 'shim dir persisted to the user PATH'
    }
    else { No "shim dir not on the persisted user PATH ($userPath)" }
    if (Test-SupplyGateMarker -Path $PROFILE.CurrentUserAllHosts) {
        Ok 'managed block in $PROFILE.CurrentUserAllHosts'
    }
    else { No 'no managed block in $PROFILE.CurrentUserAllHosts' }

    Step '7. a real cmd.exe resolves the shim off that PATH and it runs'
    # PATH order here is the real persisted one plus the fake real binary --
    # cmd.exe resolves `bun` itself, and the wrapper has to skip past its own
    # shim by content to find the fake.
    $savedPath = $env:Path
    try {
        $env:Path = "$userPath;$FakeRealDir;$savedPath"
        $out = (& cmd.exe /c 'bun install lodash --save' 2>&1 | Out-String)
        $rc = $LASTEXITCODE
    }
    finally { $env:Path = $savedPath }
    Write-Output "--- shim output (exit $rc) ---"
    Write-Output $out
    Write-Output '--- end shim output ---'
    if ($rc -eq 0) { Ok 'shim invocation exit 0' } else { No "shim invocation exit $rc" }
    if ($out -match 'REAL-BUN-RAN args=install lodash --save') { Ok 'real binary reached with args intact' }
    else { No 'real binary did not run, or args were mangled' }

    $events = @(Get-Content -LiteralPath $paths.AggregateLog -ErrorAction SilentlyContinue |
        Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $bunEvent = $events | Where-Object { $_.tool -eq 'bun' -and $_.event -eq 'command.completed' } | Select-Object -Last 1
    if ($bunEvent) { Ok 'bun event recorded in events.jsonl' } else { No 'no bun event in events.jsonl' }
    if ($bunEvent -and $bunEvent.status -eq 'success') { Ok 'event reports success' }
    elseif ($bunEvent) { No "event status is $($bunEvent.status)" }
    if ($bunEvent -and $bunEvent.user -eq $env:USERNAME) { Ok "event attributed to $env:USERNAME" }
    elseif ($bunEvent) { No "event attributed to $($bunEvent.user)" }

    Step '8. drift in the installed runtime is detected'
    Add-Content -LiteralPath $paths.CommonRuntime -Value "`r`n# drifted"
    Assert-Exit 'status degraded' 1 (Invoke-Sg status)

    Step '9. repair clears it'
    Assert-Exit 'repair' 0 (Invoke-Sg repair)
    Assert-Exit 'status healthy again' 0 (Invoke-Sg status)

    Step '10. hard mode with placeholder registries fails closed'
    $hardRc = Invoke-Sg apply -Scope user -Mode hard
    if ($hardRc -ne 0) { Ok "apply -Mode hard refused the placeholder URLs (exit $hardRc)" }
    else { No 'apply -Mode hard accepted registry.example.corp placeholders' }
    # Whatever that refusal left behind, put the box back in a known state.
    Invoke-Sg apply -Scope user -Mode soft | Out-Null

    Step '11. uninstall leaves nothing behind'
    Assert-Exit 'uninstall' 0 (Invoke-Sg uninstall -Scope user)
    if (Test-Path -LiteralPath $paths.StateRoot) { No "state root left behind: $($paths.StateRoot)" }
    else { Ok 'state root removed' }
    $userPathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPathAfter -and ($userPathAfter -split ';' | Where-Object { $_ -eq $paths.ShimRoot })) {
        No 'shim dir still on the persisted user PATH'
    }
    else { Ok 'shim dir removed from the persisted user PATH' }
    if (Test-SupplyGateMarker -Path $PROFILE.CurrentUserAllHosts) {
        No 'managed block left in $PROFILE.CurrentUserAllHosts'
    }
    else { Ok 'managed block removed from $PROFILE.CurrentUserAllHosts' }
    Assert-Exit 'status reports not installed again' 2 (Invoke-Sg status)

    Write-Output ''
    Write-Output '====================================='
    Write-Output "PASS=$script:Pass  FAIL=$script:Fail"
    if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
}
finally {
    Remove-Item -LiteralPath $FakeRealDir -Recurse -Force -ErrorAction SilentlyContinue
}
