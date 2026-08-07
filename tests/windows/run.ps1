# Run every unit test file. Exits non-zero if any file failed.
#   powershell.exe -File tests/windows/run.ps1
#
# These run against temp directories and never touch the real registry PATH,
# $PROFILE, or C:\ProgramData. Mirrors tests/run.sh; there is no end-to-end
# equivalent of tests/docker/run.sh yet -- see docs/windows-support.md.

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc = 0

Get-ChildItem -Path $ScriptDir -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    Write-Output ("`n================ {0} ================" -f $_.Name)
    & $_.FullName
    if ($LASTEXITCODE -ne 0) { $script:rc = 1 }
}

Write-Output ''
if ($rc -eq 0) {
    Write-Output 'all test files passed'
}
else {
    Write-Output 'SOME TEST FILES FAILED'
}
exit $rc
