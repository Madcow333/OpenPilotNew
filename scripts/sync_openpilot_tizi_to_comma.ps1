[CmdletBinding()]
param(
  [string]$InstallerRepo = "https://github.com/Madcow333/openpilot.git",
  [string]$InstallerBranch = "OpenPilotNew",
  [string]$InstallerRemote = "installer",
  [string]$AdbPath = "C:\platform-tools\adb.exe",
  [string]$DevicePath = "/data/openpilot",
  [string]$BackupPath = "/data/openpilot.backup.previous",
  [string]$ContinuePath = "/data/continue.sh",
  [string]$BundleBranch = "",
  [string]$DeviceBundlePath = "/data/openpilot-install.bundle",
  [string]$DeviceScriptPath = "/data/install-openpilot-bundle.sh",
  [switch]$SkipPush,
  [switch]$SkipDeviceInstall,
  [switch]$SkipReboot,
  [switch]$AllowAnyBase,
  [switch]$KeepBundle
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkManagerScripts = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts"
$blobHooks = Join-Path $forkManagerScripts "device_blob_hooks.ps1"
if (-not (Test-Path -LiteralPath $blobHooks)) {
  throw "Required Fork Manager helper is missing: $blobHooks"
}
. $blobHooks
Assert-ForkManagerHelpersPresent
$AdbProbeTimeoutSeconds = 15
$AdbPushTimeoutSeconds = 600
$AdbInstallTimeoutSeconds = 900

function Get-InstallerInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  if ($RepoUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?/?$') {
    return [pscustomobject]@{
      Owner = $Matches.owner
      Repo = $Matches.repo
      CustomSoftware = "$($Matches.owner)/$BranchName"
    }
  }

  throw "Installer repo must be a GitHub URL like https://github.com/<owner>/openpilot.git"
}

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-GitOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return ($output | Out-String).Trim()
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 90
  )

  & $AdbPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-AdbOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 90
  )

  $output = & $AdbPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return ($output | Out-String).Trim()
}

function Start-InstalledSoftware {
  Invoke-Adb -Arguments @("shell", "sh", "-c", "pkill -9 -f launch_chffrplus.sh || true; cd $DevicePath && sudo -u comma nohup ./launch_openpilot.sh >/tmp/fork-switch-launch.log 2>&1 &")
}

function Wait-ForSoftwareReady {
  param([int]$TimeoutSeconds = 180, [int]$HoldSeconds = 60)
  return Wait-ForkManagerSustainedHealth -GetProcessList {
    Get-AdbOutput -Arguments @("shell", "pgrep -af 'manager.py|selfdrive.ui.ui|pandad' || true")
  } -Patterns @{
    manager = "manager\.py"
    ui = "ui"
    pandad = "pandad"
  } -ErrorPattern "text\.py" -StartupTimeoutSeconds $TimeoutSeconds -HoldSeconds $HoldSeconds
}

function Wait-ForBootCompleted {
  param([int]$TimeoutSeconds = 360)

  Invoke-Adb -Arguments @("wait-for-device")

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $bootCompleted = (Get-AdbOutput -Arguments @("shell", "getprop", "sys.boot_completed")).Trim()
    if ($bootCompleted -eq "1") {
      return
    }
  }

  throw "Timed out waiting for sys.boot_completed=1"
}

if (-not (Test-Path -LiteralPath $AdbPath)) {
  throw "ADB not found at $AdbPath"
}

$installerInfo = Get-InstallerInfo -RepoUrl $InstallerRepo -BranchName $InstallerBranch
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location -LiteralPath $repoRoot

Write-Step "Checking repository state"
$insideRepo = Get-GitOutput -Arguments @("rev-parse", "--is-inside-work-tree")
if ($insideRepo -ne "true") {
  throw "$repoRoot is not a git repository"
}

$headCommitShort = Get-GitOutput -Arguments @("rev-parse", "--short", "HEAD")
$currentBranch = Get-GitOutput -Arguments @("branch", "--show-current")
$statusShort = Get-GitOutput -Arguments @("status", "--short")
$bundleSourceBranch = if ($BundleBranch) { $BundleBranch } else { $currentBranch }

if ($statusShort) {
  Write-Warning "Working tree is not clean. This script syncs committed HEAD only; uncommitted changes will not be included."
}

if (-not $bundleSourceBranch) {
  throw "Could not determine a branch name for bundle creation. Check out a branch or pass -BundleBranch."
}

$remotes = @((Get-GitOutput -Arguments @("remote")) -split "\r?\n" | Where-Object { $_ })
if ($InstallerRemote -notin $remotes) {
  Write-Step "Adding installer remote $InstallerRemote"
  Invoke-Git -Arguments @("remote", "add", $InstallerRemote, $InstallerRepo)
} else {
  Write-Step "Refreshing installer remote $InstallerRemote"
  Invoke-Git -Arguments @("remote", "set-url", $InstallerRemote, $InstallerRepo)
}

Write-Step "Fetching installer branch metadata"
Invoke-Git -Arguments @("fetch", $InstallerRemote, $InstallerBranch)

if (-not $AllowAnyBase) {
  & git merge-base --is-ancestor "refs/remotes/$InstallerRemote/$InstallerBranch" "HEAD"
  if ($LASTEXITCODE -ne 0) {
    throw @"
HEAD is not based on $InstallerRemote/$InstallerBranch.

This flow expects a TIZI-safe branch derived from $InstallerRemote/$InstallerBranch.
Check out the installer branch first, or rerun with -AllowAnyBase if you really want to override that guard.
"@
  }
}

if (-not $SkipPush) {
  Write-Step "Pushing $headCommitShort to $InstallerRemote/$InstallerBranch"
  Invoke-Git -Arguments @("push", $InstallerRemote, "HEAD:refs/heads/$InstallerBranch")
} else {
  Write-Step "Skipping git push"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "openpilot-sync-$headCommitShort"
$bundlePath = Join-Path $tempDir "openpilot-$headCommitShort.bundle"
$localInstallScriptPath = Join-Path $tempDir "install-openpilot-bundle.sh"
$tmpPath = "/data/tmppilot"

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$payloadDir = Join-Path $tempDir "payload"
$DevicePayload = "/data/fork-manager-payload"
$stagingPath = "/data/fork-manager-staging"
try {
  Invoke-ForkManagerPreparePayload -ForkKey "openpilot" -RepoPath (Get-Location).Path -Ref $headCommit -OutputDir $payloadDir
  $bundlePath = Join-Path $payloadDir "source.bundle"

  if ($SkipDeviceInstall) {
    Write-Step "Skipping device install"
    Write-Host "Installer target: $InstallerRepo branch $InstallerBranch"
    Write-Host "Custom software string: $($installerInfo.CustomSoftware)"
    if ($KeepBundle) {
      Write-Host "Local bundle kept at: $bundlePath"
    }
    exit 0
  }

  Write-Step "Checking adb connection"
  $devices = Get-AdbOutput -Arguments @("devices")
  $onlineDevices = @(
    $devices -split "\r?\n" |
      Where-Object { $_ -match "^\S+\s+device$" }
  )
  if ($onlineDevices.Count -eq 0) {
    throw "No adb device detected"
  }

  $isOffroad = (Get-AdbOutput -Arguments @("exec-out", "cat", "/data/params/d/IsOffroad") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  if ($isOffroad -ne "1") { throw "Turn the vehicle ignition fully off before installing. IsOffroad=$isOffroad." }
  $installedAgnosVersion = (Get-AdbOutput -Arguments @("shell", "cat", "/VERSION") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  $hardware = (Get-AdbOutput -Arguments @("shell", "cat", "/sys/firmware/devicetree/base/model") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim().ToLower()
  $hardware = ($hardware -replace "comma\s+", "").Trim()
  Invoke-ForkManagerCheckCombo -ForkKey "openpilot" -Hardware $hardware -Agnos $installedAgnosVersion

  Write-Step "Pushing verified payload and shared install helpers"
  Invoke-Adb -Arguments @("shell", "mkdir", "-p", $DevicePayload) -TimeoutSeconds $AdbProbeTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Get-ForkManagerDeviceHelperPath -Name "device_install_common.sh"), "/data/device_install_common.sh") -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Get-ForkManagerDeviceHelperPath -Name "device_install_agnos_sync.sh"), "/data/device_install_agnos_sync.sh") -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Get-ForkManagerDeviceHelperPath -Name "fetch_device_blobs.sh"), "/data/fetch_device_blobs.sh") -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Join-Path $payloadDir "source.bundle"), "$DevicePayload/source.bundle") -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Join-Path $payloadDir "artifacts.tar"), "$DevicePayload/artifacts.tar") -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("push", (Join-Path $payloadDir "install_manifest.json"), "$DevicePayload/install_manifest.json") -TimeoutSeconds $AdbPushTimeoutSeconds

  $envPrefix = "FORK_KEY=openpilot DEVICE_PATH=$DevicePath BACKUP_PATH=$BackupPath STAGING_PATH=$stagingPath CONTINUE_PATH=$ContinuePath BUNDLE_PATH=$DevicePayload/source.bundle ARTIFACTS_TAR=$DevicePayload/artifacts.tar MANIFEST_PATH=$DevicePayload/install_manifest.json INSTALLER_BRANCH=$InstallerBranch"
  Write-Step "Staging payload without disrupting the live installation"
  Invoke-Adb -Arguments @("shell", "sh", "-c", "$envPrefix sh /data/device_install_common.sh stage") -TimeoutSeconds $AdbInstallTimeoutSeconds
  $isOffroad = (Get-AdbOutput -Arguments @("exec-out", "cat", "/data/params/d/IsOffroad") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  if ($isOffroad -ne "1") { throw "Vehicle is no longer offroad; activation blocked." }

  $installStatus = "staged"
  $safeDirectory = "safe.directory=$DevicePath"
  try {
    Write-Step "Activating staged installation"
    Invoke-Adb -Arguments @("shell", "sh", "-c", "$envPrefix sh /data/device_install_common.sh activate") -TimeoutSeconds $AdbInstallTimeoutSeconds
    $installStatus = "activated"
    $got = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
    if ($got -ne $headCommit) { throw "Device commit $got != $headCommit" }
    $null = $null
    if ($SkipReboot) {
      Write-Host "Status: staged; runtime unverified (SkipReboot)."
      $installStatus = "staged; runtime unverified"
    } else {
      Start-InstalledSoftware
      if (-not (Wait-ForSoftwareReady)) { throw "OpenPilot failed sustained offroad health." }
      $installStatus = "healthy"
    }
  } catch {
    Write-Warning "Activation/health failed; rolling back. $($_.Exception.Message)"
    try {
      Invoke-Adb -Arguments @("shell", "sh", "-c", "$envPrefix sh /data/device_install_common.sh rollback") -TimeoutSeconds $AdbInstallTimeoutSeconds
      $installStatus = "rolled back"
    } catch { $installStatus = "recovery required" }
    throw "Install did not complete ($installStatus). $($_.Exception.Message)"
  }
  Write-Step "Verifying deployed branch"
  $deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", "safe.directory=/data/openpilot", "-C", "/data/openpilot", "branch", "--show-current")).Trim()
  $deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", "safe.directory=/data/openpilot", "-C", "/data/openpilot", "rev-parse", "--short", "HEAD")).Trim()
  $deviceRemote = Get-AdbOutput -Arguments @("shell", "git", "-c", "safe.directory=/data/openpilot", "-C", "/data/openpilot", "remote", "-v")

  Write-Host ""
  Write-Host "Sync complete." -ForegroundColor Green
  Write-Host "Local branch:   $currentBranch"
  Write-Host "Local commit:   $headCommitShort"
  Write-Host "Device branch:  $deviceBranch"
  Write-Host "Device commit:  $deviceCommit"
  Write-Host "Installer repo: $InstallerRepo"
  Write-Host "Remote state:"
  Write-Host $deviceRemote
  Write-Host ""
  Write-Host "Future custom software string: $($installerInfo.CustomSoftware)"
} finally {
  if (-not $KeepBundle) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
