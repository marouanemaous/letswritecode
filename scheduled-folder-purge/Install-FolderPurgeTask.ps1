<#
.SYNOPSIS
    Interactively installs a Windows scheduled task that purges old files from a folder.

.DESCRIPTION
    Prompts for:
      - the folder to clean
      - the file age (in days) after which files are deleted
      - how often (every N days) the task runs
      - the time of day the task runs
      - whether to include subfolders and remove empty folders
      - the scheduled task name

    It then writes a small purge script to C:\ProgramData\FolderPurge and registers
    a scheduled task that runs it as SYSTEM. Each run is logged next to the script.

    Run this script from an elevated (Administrator) PowerShell prompt.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

function Read-PositiveInt {
    param([string]$Prompt, [int]$Default)
    while ($true) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        $n = 0
        if ([int]::TryParse($value, [ref]$n) -and $n -gt 0) { return $n }
        Write-Host "  Please enter a whole number greater than 0." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host "$Prompt [$hint]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        switch -Regex ($value.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
        }
        Write-Host "  Please answer y or n." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Folder purge scheduled task installer ===" -ForegroundColor Cyan
Write-Host ""

# --- Folder to purge ---
while ($true) {
    $targetFolder = (Read-Host "Folder to purge (full path)").Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($targetFolder)) {
        Write-Host "  A folder is required." -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path -LiteralPath $targetFolder -PathType Container)) {
        Write-Host "  Folder '$targetFolder' does not exist." -ForegroundColor Yellow
        continue
    }
    $targetFolder = (Resolve-Path -LiteralPath $targetFolder).ProviderPath.TrimEnd('\')
    # Refuse drive roots and system folders: a typo here would be destructive.
    $forbidden = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemDrive) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($targetFolder -match '^[A-Za-z]:$' -or $forbidden -contains $targetFolder) {
        Write-Host "  Refusing to purge a drive root or system folder." -ForegroundColor Red
        continue
    }
    break
}

$olderThanDays = Read-PositiveInt "Delete files older than how many days?" 30
$intervalDays  = Read-PositiveInt "Run the task every how many days?" 1

while ($true) {
    $timeInput = Read-Host "Time of day to run (HH:mm, 24h)"
    if ([string]::IsNullOrWhiteSpace($timeInput)) { $timeInput = '02:00' }
    $startTime = [datetime]::MinValue
    if ([datetime]::TryParseExact($timeInput.Trim(), 'HH:mm', $null, 'None', [ref]$startTime)) { break }
    Write-Host "  Please use the HH:mm format, e.g. 02:00 or 23:30." -ForegroundColor Yellow
}

$recurse      = Read-YesNo "Include subfolders?" $true
$removeEmpty  = if ($recurse) { Read-YesNo "Remove subfolders left empty after the purge?" $false } else { $false }

$defaultName = 'Purge - ' + (Split-Path -Leaf $targetFolder)
$taskName = Read-Host "Scheduled task name [$defaultName]"
if ([string]::IsNullOrWhiteSpace($taskName)) { $taskName = $defaultName }
$taskName = $taskName.Trim()

# --- Preview what would be deleted right now ---
$cutoff = (Get-Date).AddDays(-$olderThanDays)
$preview = Get-ChildItem -LiteralPath $targetFolder -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff }
$previewSize = ($preview | Measure-Object -Property Length -Sum).Sum
if (-not $previewSize) { $previewSize = 0 }

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "  Task name        : $taskName"
Write-Host "  Folder           : $targetFolder"
Write-Host "  Delete files     : older than $olderThanDays day(s) (by last modified time)"
Write-Host "  Include subdirs  : $recurse"
Write-Host "  Remove empty dirs: $removeEmpty"
Write-Host "  Schedule         : every $intervalDays day(s) at $($startTime.ToString('HH:mm'))"
Write-Host "  Runs as          : SYSTEM"
Write-Host ("  If run now, it would delete {0} file(s), {1:N2} MB" -f @($preview).Count, ($previewSize / 1MB))
Write-Host ""

if (-not (Read-YesNo "Install this scheduled task?" $true)) {
    Write-Host "Cancelled. Nothing was installed." -ForegroundColor Yellow
    return
}

# --- Write the purge script ---
$installDir = Join-Path $env:ProgramData 'FolderPurge'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

$safeName   = ($taskName -replace '[\\/:*?"<>|]', '_')
$scriptPath = Join-Path $installDir "$safeName.ps1"
$logPath    = Join-Path $installDir "$safeName.log"

$purgeScript = @'
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [int]    $OlderThanDays,
    [Parameter(Mandatory)] [string] $LogPath,
    [switch] $Recurse,
    [switch] $RemoveEmptyFolders
)

function Write-Log([string]$Message) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message | Add-Content -LiteralPath $LogPath
}

# Keep the log from growing forever (~5 MB).
if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 5MB) {
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Log "ERROR: folder '$Path' not found. Nothing deleted."
    exit 1
}

$cutoff  = (Get-Date).AddDays(-$OlderThanDays)
$deleted = 0
$failed  = 0
$bytes   = 0

Write-Log "Start: purging files in '$Path' older than $OlderThanDays day(s) (before $cutoff), recurse=$Recurse"

Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object {
        try {
            $size = $_.Length
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            $deleted++
            $bytes += $size
        } catch {
            $failed++
            Write-Log "  FAILED: $($_.TargetObject) - $($_.Exception.Message)"
        }
    }

if ($RemoveEmptyFolders) {
    # Deepest folders first so parents become empty after their children are removed.
    Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Log ("Done: deleted {0} file(s), {1:N2} MB freed, {2} failure(s)" -f $deleted, ($bytes / 1MB), $failed)
'@

Set-Content -LiteralPath $scriptPath -Value $purgeScript -Encoding UTF8

# --- Register the scheduled task ---
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" " +
             "-Path `"$targetFolder`" -OlderThanDays $olderThanDays -LogPath `"$logPath`""
if ($recurse)     { $arguments += ' -Recurse' }
if ($removeEmpty) { $arguments += ' -RemoveEmptyFolders' }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger   = New-ScheduledTaskTrigger -Daily -DaysInterval $intervalDays -At $startTime
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
                -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    if (-not (Read-YesNo "A task named '$taskName' already exists. Replace it?" $false)) {
        Write-Host "Cancelled. Existing task left unchanged." -ForegroundColor Yellow
        return
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "Deletes files older than $olderThanDays day(s) from '$targetFolder'." | Out-Null

Write-Host ""
Write-Host "Scheduled task '$taskName' installed." -ForegroundColor Green
Write-Host "  Purge script : $scriptPath"
Write-Host "  Log file     : $logPath"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Run now : Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  Remove  : Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"

if (Read-YesNo "Run the task once now?" $false) {
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Task started. Check the log at $logPath" -ForegroundColor Green
}
