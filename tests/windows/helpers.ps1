# Minimal hand-rolled assertion helpers -- mirrors tests/helpers.sh. No
# Pester dependency on purpose: the POSIX side ships zero-extra-install tests
# (any Debian/Ubuntu box already has dpkg-deb; any Windows box already has
# powershell.exe), and pulling in a test framework just for this side would
# break that property.

$Script:TestPass = 0
$Script:TestFail = 0

function Assert-SupplyGateEqual {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter()]$Expected,
        [Parameter()]$Actual
    )
    if ("$Expected" -eq "$Actual") {
        $Script:TestPass++
        Write-Output "  PASS  $Label"
    }
    else {
        $Script:TestFail++
        Write-Output "  FAIL  $Label (expected [$Expected], got [$Actual])"
    }
}

function Assert-SupplyGateTrue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Condition
    )
    if ($Condition) {
        $Script:TestPass++
        Write-Output "  PASS  $Label"
    }
    else {
        $Script:TestFail++
        Write-Output "  FAIL  $Label"
    }
}

function Assert-SupplyGateFalse {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Condition
    )
    Assert-SupplyGateTrue -Label $Label -Condition (-not $Condition)
}

function Get-SupplyGateTestSummary {
    Write-Output ''
    Write-Output "PASS=$Script:TestPass  FAIL=$Script:TestFail"
    return $Script:TestFail -eq 0
}
