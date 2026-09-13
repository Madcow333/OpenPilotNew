[CmdletBinding()]
param(
  [string]$InstallerRepo = "https://github.com/Madcow333/openpilot.git",
  [string]$InstallerBranch = "OpenPilotNew",
  [string]$InstallerRemote = "installer",
  [string]$AdbPath = "",
  [string]$DevicePath = "/data/openpilot",
  [string]$BackupPath = "/data/openpilot.backup.previous",
  [string]$ContinuePath = "/data/continue.sh",
  [string]$DeviceScriptPath = "/data/install-openpilot-branch.sh",
  [switch]$SkipPush,
  [switch]$ForcePush,
  [switch]$SkipDeviceInstall,
  [switch]$CheckAdbOnly,
  [switch]$SkipReboot,
  [switch]$AllowAnyBase,
  [int]$AdbCommandTimeoutSeconds = 90,
  [int]$AdbPushTimeoutSeconds = 600,
  [int]$AdbInstallTimeoutSeconds = 900,
  [int]$AdbRestartTimeoutSeconds = 60,
  [int]$AdbProbeTimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-InstallerInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  if ($RepoUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?/?$') {
    $owner = $Matches.owner
    $repo = $Matches.repo
  } else {
    throw "Installer repo must be a GitHub URL like https://github.com/<owner>/openpilot.git"
  }

  if ($repo -ne "openpilot") {
    Write-Warning "Installer repo name is '$repo'. Custom software installs usually expect an 'openpilot' repo."
  }

  return [pscustomobject]@{
    Owner = $owner
    Repo = $repo
    CustomSoftware = "$owner/$BranchName"
  }
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

function ConvertTo-ProcessArgument {
  param([AllowNull()][string]$Argument)

  if ($null -eq $Argument -or $Argument -eq "") {
    return '""'
  }
  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  $result = New-Object System.Text.StringBuilder
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes += 1
      continue
    }
    if ($char -eq '"') {
      if ($backslashes -gt 0) {
        [void]$result.Append(('\' * ($backslashes * 2)))
      }
      [void]$result.Append('\"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$result.Append(('\' * $backslashes))
      $backslashes = 0
    }
    [void]$result.Append($char)
  }
  if ($backslashes -gt 0) {
    [void]$result.Append(('\' * ($backslashes * 2)))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-ProcessArguments {
  param([string[]]$Arguments)
  return (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Argument $_ }) -join " ")
}

function Invoke-AdbProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $AdbPath
  $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $timeoutMilliseconds = [Math]::Max(1, $TimeoutSeconds) * 1000

  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
      try {
        $process.Kill()
      } catch {
      }
      throw "adb $($Arguments -join ' ') timed out after $TimeoutSeconds second(s)"
    }

    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    if ($process.ExitCode -ne 0) {
      $details = (($stdoutText, $stderrText) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) -join "`n"
      if ($details) {
        throw "adb $($Arguments -join ' ') failed with exit code $($process.ExitCode): $details"
      }
      throw "adb $($Arguments -join ' ') failed with exit code $($process.ExitCode)"
    }

    return [pscustomobject]@{
      Stdout = $stdoutText
      Stderr = $stderrText
    }
  } finally {
    $process.Dispose()
  }
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
  if ($result.Stdout -and $result.Stdout.Trim()) {
    Write-Host $result.Stdout.TrimEnd()
  }
  if ($result.Stderr -and $result.Stderr.Trim()) {
    Write-Host $result.Stderr.TrimEnd()
  }
}

function Get-AdbOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
  return $result.Stdout.Trim()
}

function Request-DeviceReboot {
  $rebootAttempts = @(
    @{ Label = "device shell reboot"; Args = @("shell", "reboot") },
    @{ Label = "device powerctl reboot"; Args = @("shell", "setprop", "sys.powerctl", "reboot") },
    @{ Label = "adb reboot"; Args = @("reboot") }
  )

  foreach ($attempt in $rebootAttempts) {
    try {
      Write-Host "Using reboot method: $($attempt.Label)"
      Invoke-Adb -Arguments $attempt.Args -TimeoutSeconds $AdbRestartTimeoutSeconds
      return
    } catch {
      Write-Warning "$($attempt.Label) failed: $($_.Exception.Message)"
    }
  }

  throw "Unable to request a device reboot over adb"
}

function Wait-ForAdbDevice {
  param([int]$TimeoutSeconds = 90)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $resetAttempted = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
      $onlineDevices = @(
        $devices -split "\r?\n" |
          Where-Object { $_ -match "^\S+\s+device$" }
      )
      if ($onlineDevices.Count -gt 0) {
        if (Get-Command Reset-AdbDaemon -ErrorAction SilentlyContinue) {
          Reset-AdbDaemon -AdbPath $AdbPath
        }
        return
      }
    } catch {
      if (-not $resetAttempted -and (Get-Command Reset-AdbDaemon -ErrorAction SilentlyContinue)) {
        $resetAttempted = $true
        try { Reset-AdbDaemon -AdbPath $AdbPath } catch { }
      }
    }

    Start-Sleep -Seconds 2
  }

  throw "Timed out waiting for an adb device after $TimeoutSeconds second(s)."
}

function Wait-ForDeviceReady {
  param([int]$TimeoutSeconds = 360)

  Wait-ForAdbDevice -TimeoutSeconds $TimeoutSeconds

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5

    foreach ($bootProbe in @(
      @{ Args = @("shell", "getprop", "sys.boot_completed"); ReadyValue = "1" },
      @{ Args = @("shell", "getprop", "dev.bootcomplete"); ReadyValue = "1" },
      @{ Args = @("shell", "getprop", "service.bootanim.exit"); ReadyValue = "1" }
    )) {
      try {
        $probeValue = (Get-AdbOutput -Arguments $bootProbe.Args -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
        if ($probeValue -eq $bootProbe.ReadyValue) {
          return
        }
      } catch {
      }
    }

    try {
      $gitHead = (Get-AdbOutput -Arguments @("shell", "git", "-c", "safe.directory=$DevicePath", "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
      if ($gitHead) {
        return
      }
    } catch {
    }

    try {
      $launchScriptReady = (Get-AdbOutput -Arguments @("shell", "sh", "-c", "test -x $DevicePath/launch_openpilot.sh && echo ready") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
      if ($launchScriptReady -eq "ready") {
        return
      }
    } catch {
    }
  }

  throw @"
Timed out waiting for the device to come back online after reboot.

Some comma units can boot into a USB recovery/adb mode when the data cable stays connected during restart.
If that happens, disconnect the USB data cable, boot the comma on power only, then reconnect data after the normal boot screen appears.
"@
}

function Start-InstalledSoftware {
  $deviceStartScript = @'
set -e
pkill -9 -f 'launch_chffrplus.sh|system/manager/manager.py|./manager.py|system.updated.updated|selfdrive.pandad.pandad|./pandad|selfdrive.ui.ui|system/ui/text.py|spinner.py|build.py|starpilot\.|the_pond|device_syncd|mapd_wrapper|starpilot_process|galaxy' || true
rm -f /tmp/fork-switch-launch.log
sudo -u comma bash -lc 'cd __DEVICE_PATH__ && nohup ./launch_openpilot.sh >/tmp/fork-switch-launch.log 2>&1 &'
'@

  $deviceStartScript = $deviceStartScript.Replace("__DEVICE_PATH__", $DevicePath)
  Invoke-Adb -Arguments @("shell", "sh", "-c", $deviceStartScript) -TimeoutSeconds $AdbRestartTimeoutSeconds
}

function Wait-ForSoftwareReady {
  param([int]$TimeoutSeconds = 120)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5

    try {
      $procSummary = Get-AdbOutput -Arguments @("shell", "sh", "-c", "pgrep -af 'manager.py|build.py|spinner.py|text.py|selfdrive.ui.ui|selfdrive.pandad.pandad|./pandad' || true") -TimeoutSeconds $AdbProbeTimeoutSeconds
    } catch {
      continue
    }

    if ($procSummary -match 'manager\.py|build\.py|spinner\.py|selfdrive\.ui\.ui|selfdrive\.pandad\.pandad|\.\/pandad') {
      return $true
    }

    if ($procSummary -match 'text\.py') {
      return $false
    }
  }

  return $false
}

function Get-DevicePandaCounts {
  $probe = @'
import sys
sys.path.insert(0, "/data/openpilot")
from panda import Panda, PandaDFU
print(f"{len(Panda.list())},{len(PandaDFU.list())}")
'@

  $localProbePath = Join-Path ([System.IO.Path]::GetTempPath()) ("panda-visibility-" + [guid]::NewGuid().ToString("N") + ".py")
  $remoteProbePath = "/data/panda-visibility-$([guid]::NewGuid().ToString('N')).py"

  try {
    [System.IO.File]::WriteAllText($localProbePath, $probe, [System.Text.UTF8Encoding]::new($false))
    Invoke-Adb -Arguments @("push", $localProbePath, $remoteProbePath) -TimeoutSeconds $AdbPushTimeoutSeconds
    $output = Get-AdbOutput -Arguments @("shell", "sh", "-c", "cd /data/openpilot && PYTHONPATH=/data/openpilot /usr/local/venv/bin/python3 $remoteProbePath") -TimeoutSeconds $AdbCommandTimeoutSeconds
  } finally {
    Remove-Item -LiteralPath $localProbePath -Force -ErrorAction SilentlyContinue
    try {
      Invoke-Adb -Arguments @("shell", "rm", "-f", $remoteProbePath) -TimeoutSeconds $AdbProbeTimeoutSeconds
    } catch {
    }
  }

  $parts = (($output | Out-String).Trim()) -split ","
  if ($parts.Count -ne 2) {
    throw "Unexpected panda visibility probe output: $output"
  }

  return @{
    PandaCount = [int]$parts[0]
    DfuCount = [int]$parts[1]
  }
}

if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
  $adbCandidates = @(
    (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "tools\platform-tools\adb.exe"),
    "C:\platform-tools\adb.exe"
  )
  foreach ($candidate in $adbCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      $AdbPath = (Resolve-Path -LiteralPath $candidate).Path
      break
    }
  }
  if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
    $adbCommand = Get-Command adb -ErrorAction SilentlyContinue
    if ($adbCommand) {
      $AdbPath = $adbCommand.Source
    }
  }
}
if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
  throw "ADB not found. Pass -AdbPath, run Fork_Manager.bat setup adb, or put adb.exe on PATH."
}

$forkManagerScripts = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts"
$adbSessionHelper = Join-Path $forkManagerScripts "adb_session.ps1"
$blobHooks = Join-Path $forkManagerScripts "device_blob_hooks.ps1"
if (Test-Path -LiteralPath $blobHooks) {
  . $blobHooks
}
if (Test-Path -LiteralPath $adbSessionHelper) {
  . $adbSessionHelper
} else {
  Write-Warning "Shared ADB session helper missing: $adbSessionHelper"
}

if ($CheckAdbOnly) {
  Write-Step "Checking adb connection"
  if (Get-Command Ensure-AdbSession -ErrorAction SilentlyContinue) {
    $null = Ensure-AdbSession -AdbPath $AdbPath -ProbeShell
  }
  $devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
  $onlineDevices = @(
    $devices -split "\r?\n" |
      Where-Object { $_ -match "^\S+\s+device$" } |
      ForEach-Object { ($_ -split "\s+")[0] }
  )
  if ($onlineDevices.Count -eq 0) {
    throw "No adb device detected"
  }
  if ($onlineDevices.Count -gt 1 -and -not $env:ANDROID_SERIAL) {
    throw "Multiple adb devices detected ($($onlineDevices -join ', ')). Set ANDROID_SERIAL or disconnect the extra devices."
  }

  $deviceSerial = if ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { $onlineDevices[0] }
  Write-Host "ADB device: $deviceSerial"

  try {
    $safeDirectory = "safe.directory=$DevicePath"
    $deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "branch", "--show-current") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
    $deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
    Write-Host "Device branch: $deviceBranch"
    Write-Host "Device commit: $deviceCommit"
  } catch {
    Write-Warning "ADB is connected, but $DevicePath could not be inspected: $($_.Exception.Message)"
  }

  if (Get-Command Finalize-AdbSession -ErrorAction SilentlyContinue) {
    Finalize-AdbSession -AdbPath $AdbPath
  }
  exit 0
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

$headCommit = Get-GitOutput -Arguments @("rev-parse", "HEAD")
$headCommitShort = Get-GitOutput -Arguments @("rev-parse", "--short", "HEAD")
$currentBranch = Get-GitOutput -Arguments @("branch", "--show-current")
$statusShort = Get-GitOutput -Arguments @("status", "--short")

if ($statusShort) {
  Write-Warning "Working tree is not clean. This script deploys committed HEAD only; uncommitted changes will not be included."
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
  $mergeBaseOk = & git merge-base --is-ancestor "refs/remotes/$InstallerRemote/$InstallerBranch" "HEAD"
  if ($LASTEXITCODE -ne 0) {
    throw @"
HEAD is not based on $InstallerRemote/$InstallerBranch.

This device flow expects a TIZI-safe branch derived from $InstallerRemote/$InstallerBranch.
Check out the installer branch first, or rerun with -AllowAnyBase if you really want to override that guard.
"@
  }
}

if (-not $SkipPush) {
  Write-Step "Pushing $headCommitShort to $InstallerRemote/$InstallerBranch"
  $pushArgs = @("push", $InstallerRemote, "HEAD:refs/heads/$InstallerBranch")
  if ($ForcePush) {
    $pushArgs += "--force-with-lease"
  }
  Invoke-Git -Arguments $pushArgs
} else {
  Write-Step "Skipping git push"
}

if ($SkipDeviceInstall) {
  Write-Step "Skipping device install"
  Write-Host "Installer target: $InstallerRepo branch $InstallerBranch"
  Write-Host "Custom software string: $($installerInfo.CustomSoftware)"
  exit 0
}

if (Get-Command Invoke-ForkManagerHostBlobFetch -ErrorAction SilentlyContinue) {
  Invoke-ForkManagerHostBlobFetch -RepoPath (Get-Location).Path
}

Write-Step "Checking adb connection"
if (Get-Command Ensure-AdbSession -ErrorAction SilentlyContinue) {
  $null = Ensure-AdbSession -AdbPath $AdbPath -ProbeShell
}
$devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
$onlineDevices = @(
  $devices -split "\r?\n" |
    Where-Object { $_ -match "^\S+\s+device$" }
)
if ($onlineDevices.Count -eq 0) {
  throw "No adb device detected"
}

$tmpPath = "/data/tmppilot"
$deviceInstallScript = @'
set -e

pkill -9 -f 'launch_chffrplus.sh|system/manager/manager.py|./manager.py|system.updated.updated|selfdrive.pandad.pandad|./pandad|selfdrive.ui.ui|system/ui/text.py|starpilot\.' || true

if grep -q ' /data/safe_staging/merged ' /proc/mounts 2>/dev/null; then
  umount -l /data/safe_staging/merged || true
fi

rm -rf /data/safe_staging
rm -f /tmp/safe_staging_overlay.lock

# Reset StarPilot-specific persistent data so stock-ish installs do not inherit
# custom themes, test data, or stale toggle markers.
rm -rf /data/themes /data/stats_sp /data/testing_grounds
rm -f /data/starpilot_defaults_parity_v1 /data/starpilot_humanlike_disable_v1 /data/starpilot_param_canonicalization_v1 /data/starpilot_param_rename_v1 /data/starpilot_pc_root_v1
rm -f /data/params/d/BootLogo /data/params/d/ColorScheme /data/params/d/CustomThemes /data/params/d/DistanceIconPack /data/params/d/HolidayThemes /data/params/d/IconPack /data/params/d/RandomThemes /data/params/d/SignalAnimation /data/params/d/SoundPack /data/params/d/WheelIcon

# If the old install is StarPilot, restore its stock boot background in the
# landscape orientation expected by AGNOS startup. StarPilot keeps this asset in
# portrait form, which makes the second loading-screen comma logo appear rotated
# after switching to non-StarPilot forks.
stock_boot_bg=/tmp/fork-switch-stock-bg-landscape.jpg
rm -f "$stock_boot_bg"
if [ -f __DEVICE_PATH__/starpilot/assets/other_images/stock_bg.jpg ] && [ -x /usr/local/venv/bin/python ]; then
  /usr/local/venv/bin/python - "__DEVICE_PATH__/starpilot/assets/other_images/stock_bg.jpg" "$stock_boot_bg" <<'PY' || rm -f "$stock_boot_bg"
import sys
from PIL import Image, ImageOps

source_path, target_path = sys.argv[1:3]
with Image.open(source_path) as image:
  image = ImageOps.exif_transpose(image).convert("RGB")
  if image.height > image.width:
    image = image.rotate(-90, expand=True)
  image.save(target_path, "JPEG", quality=95)
PY
fi

rm -rf __TMP_PATH__
git clone --progress __INSTALLER_REPO__ -b __INSTALLER_BRANCH__ --depth=1 --recurse-submodules __TMP_PATH__

rm -rf __BACKUP_PATH__
if [ -d __DEVICE_PATH__ ]; then
  mv __DEVICE_PATH__ __BACKUP_PATH__
fi
mv __TMP_PATH__ __DEVICE_PATH__

# Fork Manager: drop .gitignore and fetch proprietary runtime blobs.
if [ -f /data/fetch_device_blobs.sh ]; then
  DEVICE_PATH=__DEVICE_PATH__ sh /data/fetch_device_blobs.sh
fi

# Align AGNOS startup gate with the OS already on this comma.
if [ -r /VERSION ]; then
  device_agnos="$(tr -d '\n\r' < /VERSION)"
  for launch_env in __DEVICE_PATH__/launch_env.sh __DEVICE_PATH__/sunnypilot/system/hardware/c3/launch_env.sh; do
    [ -f "$launch_env" ] || continue
    if grep -q 'export AGNOS_VERSION=' "$launch_env"; then
      sed -i "s/export AGNOS_VERSION=\"[^\"]*\"/export AGNOS_VERSION=\"${device_agnos}\"/" "$launch_env"
    fi
  done
fi

if [ -f "$stock_boot_bg" ]; then
  root_mount_options="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
  if mount -o remount,rw / 2>/dev/null || sudo mount -o remount,rw / 2>/dev/null; then
    cp "$stock_boot_bg" /usr/comma/bg.jpg
    chmod 664 /usr/comma/bg.jpg 2>/dev/null || true
    chown root:root /usr/comma/bg.jpg 2>/dev/null || true
    rm -f /tmp/bg.jpg 2>/dev/null || true
    if [ -n "$root_mount_options" ]; then
      mount -o "remount,$root_mount_options" / 2>/dev/null || sudo mount -o "remount,$root_mount_options" / 2>/dev/null || true
    else
      mount -o remount,ro / 2>/dev/null || sudo mount -o remount,ro / 2>/dev/null || true
    fi
  fi
  rm -f "$stock_boot_bg"
fi

mkdir -p /data/params/d
printf '%s' '__INSTALLER_BRANCH__' > /data/params/d/UpdaterTargetBranch
printf '%s' 'idle' > /data/params/d/UpdaterState
rm -f /data/params/d/JoystickDebugMode /data/params/d/UpdateAvailable /data/params/d/Updated /data/params/d/UpdaterAvailableBranches /data/params/d/UpdaterCurrentDescription /data/params/d/UpdaterCurrentReleaseNotes /data/params/d/UpdaterFetchAvailable /data/params/d/UpdaterNewDescription /data/params/d/UpdaterNewReleaseNotes /data/params/d/LastUpdateException
chown comma:comma /data/params/d/UpdaterTargetBranch /data/params/d/UpdaterState 2>/dev/null || true

cat >__CONTINUE_PATH__ <<'EOF'
#!/usr/bin/env bash

cd __DEVICE_PATH__
exec ./launch_openpilot.sh
EOF

chmod +x __CONTINUE_PATH__
chown comma:comma __CONTINUE_PATH__
chown -R comma:comma __DEVICE_PATH__
sync
'@

$deviceInstallScript = $deviceInstallScript.Replace("__TMP_PATH__", $tmpPath)
$deviceInstallScript = $deviceInstallScript.Replace("__INSTALLER_REPO__", $InstallerRepo)
$deviceInstallScript = $deviceInstallScript.Replace("__INSTALLER_BRANCH__", $InstallerBranch)
$deviceInstallScript = $deviceInstallScript.Replace("__BACKUP_PATH__", $BackupPath)
$deviceInstallScript = $deviceInstallScript.Replace("__DEVICE_PATH__", $DevicePath)
$deviceInstallScript = $deviceInstallScript.Replace("__CONTINUE_PATH__", $ContinuePath)

$localInstallScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("install-openpilot-branch-" + [guid]::NewGuid().ToString("N") + ".sh")

Write-Step "Installing $InstallerBranch to the connected device"
try {
  $deviceInstallScript = $deviceInstallScript.Replace("`r`n", "`n")
  [System.IO.File]::WriteAllText($localInstallScriptPath, $deviceInstallScript, [System.Text.UTF8Encoding]::new($false))
  if (Get-Command Get-ForkManagerDeviceBlobFetchScript -ErrorAction SilentlyContinue) {
    Invoke-Adb -Arguments @("push", (Get-ForkManagerDeviceBlobFetchScript), "/data/fetch_device_blobs.sh") -TimeoutSeconds $AdbPushTimeoutSeconds
  }
  Invoke-Adb -Arguments @("push", $localInstallScriptPath, $DeviceScriptPath) -TimeoutSeconds $AdbPushTimeoutSeconds
  Invoke-Adb -Arguments @("shell", "sh", $DeviceScriptPath) -TimeoutSeconds $AdbInstallTimeoutSeconds
} finally {
  Remove-Item -LiteralPath $localInstallScriptPath -Force -ErrorAction SilentlyContinue
  try {
    Invoke-Adb -Arguments @("shell", "rm", "-f", $DeviceScriptPath) -TimeoutSeconds $AdbProbeTimeoutSeconds
  } catch {
  }
}

$safeDirectory = "safe.directory=$DevicePath"
$deviceCommitBeforeReboot = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
if ($deviceCommitBeforeReboot -ne $headCommit) {
  throw "Device install did not stage expected commit $headCommit before reboot. Device is still on $deviceCommitBeforeReboot."
}

  if (-not $SkipReboot) {
    Write-Step "Restarting software and waiting for it to start"
    $softwareRestarted = $false
    try {
      Start-InstalledSoftware
      $softwareRestarted = Wait-ForSoftwareReady
    } catch {
      Write-Warning "Soft restart failed, falling back to a full reboot."
    }

    if (-not $softwareRestarted) {
      Write-Step "Falling back to full device reboot"
      Request-DeviceReboot
      Wait-ForDeviceReady
    }
  } else {
    Write-Step "Skipping reboot"
  }

Write-Step "Verifying deployed branch"
$deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "branch", "--show-current") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
$deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
$deviceRemote = Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "remote", "-v") -TimeoutSeconds $AdbProbeTimeoutSeconds
$pandaStatus = Get-DevicePandaCounts

if (($pandaStatus.PandaCount + $pandaStatus.DfuCount) -eq 0) {
  Write-Warning @"
OpenPilot is installed, but the device currently sees no panda hardware.

If the comma is booted only from USB power, or the harness/vehicle ignition is off, the UI can show "update required"
until the panda is visible again. Boot the comma on normal car/harness power, then reconnect USB data after the normal boot
screen appears if needed.
"@
}

Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
Write-Host "Local branch:   $currentBranch"
Write-Host "Local commit:   $headCommitShort"
Write-Host "Device branch:  $deviceBranch"
Write-Host "Device commit:  $deviceCommit"
Write-Host "Visible pandas: $($pandaStatus.PandaCount)"
Write-Host "DFU pandas:     $($pandaStatus.DfuCount)"
Write-Host "Installer repo: $InstallerRepo"
Write-Host "Remote state:"
Write-Host $deviceRemote
Write-Host ""
Write-Host "Future custom software string: $($installerInfo.CustomSoftware)"

if (Get-Command Finalize-AdbSession -ErrorAction SilentlyContinue) {
  # Best-effort on success path; early failures before ADB may skip this.
  Finalize-AdbSession -AdbPath $AdbPath
}
