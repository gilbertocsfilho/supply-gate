param(
  [Parameter(Mandatory = $true)][string]$ShimRoot,
  [Parameter(Mandatory = $true)][string]$ProfileSnippet,
  [Parameter(Mandatory = $true)][string]$MarkerBegin,
  [Parameter(Mandatory = $true)][string]$MarkerEnd,
  [ValidateSet("Apply","Audit","Remove")][string]$Action = "Apply"
)

$ErrorActionPreference = "Stop"

function Get-UserProfilePath {
  if (-not $PROFILE.CurrentUserAllHosts) {
    throw "PowerShell profile path is unavailable."
  }
  return $PROFILE.CurrentUserAllHosts
}

function Ensure-ParentDirectory([string]$Path) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

function Set-ManagedBlock([string]$Path, [string]$Block) {
  Ensure-ParentDirectory $Path
  $existing = if (Test-Path $Path) { Get-Content -Raw $Path } else { "" }
  $escapedBegin = [regex]::Escape($MarkerBegin)
  $escapedEnd = [regex]::Escape($MarkerEnd)
  $pattern = "(?ms)^$escapedBegin.*?^$escapedEnd\r?\n?"
  $clean = [regex]::Replace($existing, $pattern, "")
  $newContent = ($clean.TrimEnd(), $MarkerBegin, $Block, $MarkerEnd) -join [Environment]::NewLine
  Set-Content -Path $Path -Value ($newContent + [Environment]::NewLine) -Encoding UTF8
}

function Remove-ManagedBlock([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  $existing = Get-Content -Raw $Path
  $escapedBegin = [regex]::Escape($MarkerBegin)
  $escapedEnd = [regex]::Escape($MarkerEnd)
  $pattern = "(?ms)^$escapedBegin.*?^$escapedEnd\r?\n?"
  $clean = [regex]::Replace($existing, $pattern, "")
  Set-Content -Path $Path -Value $clean -Encoding UTF8
}

function Ensure-PathContainsShimRoot {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($userPath) {
    $parts = $userPath.Split(";") | Where-Object { $_ -and $_.Trim() -ne "" }
  }
  if ($parts -notcontains $ShimRoot) {
    $newPath = ($ShimRoot + ";" + ($parts -join ";")).TrimEnd(";")
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  }
}

function Remove-ShimRootFromPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { return }
  $parts = $userPath.Split(";") | Where-Object { $_ -and $_ -ne $ShimRoot }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

$profilePath = Get-UserProfilePath
$profileBlock = @"
. "$ProfileSnippet"
"@

switch ($Action) {
  "Apply" {
    Ensure-PathContainsShimRoot
    Set-ManagedBlock -Path $profilePath -Block $profileBlock
    Write-Output "Applied Windows PATH/profile settings."
  }
  "Audit" {
    $hasPath = ([Environment]::GetEnvironmentVariable("Path", "User") -split ";") -contains $ShimRoot
    $hasProfile = (Test-Path $profilePath) -and ((Get-Content -Raw $profilePath) -match [regex]::Escape($MarkerBegin))
    [pscustomobject]@{
      ShimRootInUserPath = $hasPath
      ManagedProfileBlock = $hasProfile
      ProfilePath = $profilePath
    } | ConvertTo-Json -Compress
  }
  "Remove" {
    Remove-ShimRootFromPath
    Remove-ManagedBlock -Path $profilePath
    Write-Output "Removed Windows PATH/profile settings."
  }
}
