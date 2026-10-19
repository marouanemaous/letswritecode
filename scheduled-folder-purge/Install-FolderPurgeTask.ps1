# .SYNOPSIS
#     Interactively installs a scheduled task that purges old files from a folder,
#     on the local machine and/or on multiple remote servers.
#
# .DESCRIPTION
#     Prompts for:
#       - the target servers (comma separated, or the path to a .txt file with one per line)
#       - optional alternate credentials for the remote servers
#       - the folder to clean (a local path as seen on each target server)
#       - the file age (in days) after which files are deleted
#       - how often (every N days) the task runs
#       - the time of day the task runs
#       - whether to include subfolders and remove empty folders
#       - the scheduled task name
#
#     It first previews every server (folder exists, how many files would be deleted),
#     asks for confirmation, then on each server writes a small purge script to
#     C:\ProgramData\FolderPurge and registers a scheduled task that runs it as SYSTEM.
#     Each run is logged next to the purge script on that server.
#
#     Remote servers are reached with PowerShell remoting (WinRM), so it must be enabled
#     on them (Enable-PSRemoting) and the account used must be an administrator there.
#     Targets need Windows Server 2012 / Windows 8 or later (ScheduledTasks module).

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

function Test-IsLocal([string]$Name) {
    $Name -in @('localhost', '.', '127.0.0.1', '::1', $env:COMPUTERNAME) -or
        $Name -like "$env:COMPUTERNAME.*"
}

# Script that runs on every target server, either to preview or to install.
# It never throws: it always returns one result object per server.
$targetBlock = {
    param(
        [string] $Mode,            # 'Preview' or 'Install'
        [string] $TargetFolder,
        [int]    $OlderThanDays,
        [int]    $IntervalDays,
        [string] $StartTime,       # HH:mm
        [bool]   $Recurse,
        [bool]   $RemoveEmpty,
        [string] $TaskName,
        [bool]   $ReplaceExisting,
        [bool]   $RunNow,
        [string] $PurgeScript
    )

    $result = [pscustomobject]@{
        Server  = $env:COMPUTERNAME
        Status  = 'OK'
        Files   = $null
        SizeMB  = $null
        Message = ''
    }

    try {
        $ErrorActionPreference = 'Stop'

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
            IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { throw "Not running as administrator on this server." }

        if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
            throw "Folder '$TargetFolder' does not exist."
        }
        $folder = (Resolve-Path -LiteralPath $TargetFolder).ProviderPath.TrimEnd('\')

        # Refuse drive roots and system folders: a typo here would be destructive.
        $forbidden = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemDrive) |
            Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
        if ($folder -match '^[A-Za-z]:$' -or $forbidden -contains $folder) {
            throw "Refusing to purge a drive root or system folder ('$folder')."
        }

        if ($Mode -eq 'Preview') {
            $cutoff = (Get-Date).AddDays(-$OlderThanDays)
            $files = @(Get-ChildItem -LiteralPath $folder -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
            $size = ($files | Measure-Object -Property Length -Sum).Sum
            $result.Files  = $files.Count
            $result.SizeMB = [math]::Round($(if ($size) { $size } else { 0 }) / 1MB, 2)
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                $result.Message = "Task '$TaskName' already exists."
            }
            return $result
        }

        # --- Install ---
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            if (-not $ReplaceExisting) {
                $result.Status  = 'Skipped'
                $result.Message = "Task '$TaskName' already exists."
                return $result
            }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        $installDir = Join-Path $env:ProgramData 'FolderPurge'
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null

        $safeName   = ($TaskName -replace '[\\/:*?"<>|]', '_')
        $scriptPath = Join-Path $installDir "$safeName.ps1"
        $logPath    = Join-Path $installDir "$safeName.log"
        Set-Content -LiteralPath $scriptPath -Value $PurgeScript -Encoding UTF8

        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" " +
                     "-Path `"$folder`" -OlderThanDays $OlderThanDays -LogPath `"$logPath`""
        if ($Recurse)     { $arguments += ' -Recurse' }
        if ($RemoveEmpty) { $arguments += ' -RemoveEmptyFolders' }

        $at        = [datetime]::ParseExact($StartTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger   = New-ScheduledTaskTrigger -Daily -DaysInterval $IntervalDays -At $at
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
                        -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description "Deletes files older than $OlderThanDays day(s) from '$folder'." | Out-Null

        if ($RunNow) { Start-ScheduledTask -TaskName $TaskName }

        $result.Status  = 'Installed'
        $result.Message = "Log: $logPath"
    } catch {
        $result.Status  = 'Error'
        $result.Message = $_.Exception.Message
    }
    return $result
}

# Purge script written to each server and run by the scheduled task.
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

# Runs $targetBlock on the given servers (in parallel for remote ones) and returns one result per server.
function Invoke-OnTargets {
    param([string[]]$Servers, [object[]]$ArgumentList, [pscredential]$Credential)

    $results = @()
    $local   = @($Servers | Where-Object { Test-IsLocal $_ })
    $remote  = @($Servers | Where-Object { -not (Test-IsLocal $_) })

    if ($local.Count -gt 0) {
        $results += & $targetBlock @ArgumentList
    }

    if ($remote.Count -gt 0) {
        $params = @{
            ComputerName  = $remote
            ScriptBlock   = $targetBlock
            ArgumentList  = $ArgumentList
            ErrorAction   = 'SilentlyContinue'
            ErrorVariable = 'remoteErrors'
        }
        if ($Credential) { $params.Credential = $Credential }

        $remoteResults = @(Invoke-Command @params)
        $results += $remoteResults | ForEach-Object {
            # Report by the name the user typed, so it lines up with connection errors.
            $_.Server = $_.PSComputerName
            $_ | Select-Object Server, Status, Files, SizeMB, Message
        }

        # Servers that returned nothing could not be reached.
        $answered = @($remoteResults | ForEach-Object { $_.PSComputerName })
        foreach ($server in $remote | Where-Object { $answered -notcontains $_ }) {
            $err = $remoteErrors | Where-Object {
                $_.TargetObject -eq $server -or $_.OriginInfo.PSComputerName -eq $server
            } | Select-Object -First 1
            $results += [pscustomobject]@{
                Server  = $server
                Status  = 'Unreachable'
                Files   = $null
                SizeMB  = $null
                Message = if ($err) { $err.Exception.Message } else { 'No response from server.' }
            }
        }
    }
    return $results
}

Write-Host ""
Write-Host "=== Folder purge scheduled task installer ===" -ForegroundColor Cyan
Write-Host ""

# --- Target servers ---
while ($true) {
    $serverInput = (Read-Host "Target servers (comma separated, or path to a .txt file) [localhost]").Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($serverInput)) { $serverInput = 'localhost' }

    if (Test-Path -LiteralPath $serverInput -PathType Leaf) {
        $servers = Get-Content -LiteralPath $serverInput
    } else {
        $servers = $serverInput -split '[,;\s]+'
    }
    $servers = @($servers | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)

    if ($servers.Count -gt 0) { break }
    Write-Host "  At least one server is required." -ForegroundColor Yellow
}
Write-Host "  $($servers.Count) server(s): $($servers -join ', ')"

$hasLocal  = @($servers | Where-Object { Test-IsLocal $_ }).Count -gt 0
$hasRemote = @($servers | Where-Object { -not (Test-IsLocal $_) }).Count -gt 0

$credential = $null
if ($hasRemote -and (Read-YesNo "Use different credentials for the remote servers?" $false)) {
    $credential = Get-Credential -Message "Administrator account for the target servers"
}

# --- Folder to purge (validated on each server during the preview) ---
while ($true) {
    $targetFolder = (Read-Host "Folder to purge (full local path on the target servers, e.g. D:\Logs)").Trim().Trim('"')
    if ($targetFolder -match '^[A-Za-z]:\\.+') { $targetFolder = $targetFolder.TrimEnd('\'); break }
    Write-Host "  Please enter a full local path like D:\Logs (no drive root, no UNC path)." -ForegroundColor Yellow
}

$olderThanDays = Read-PositiveInt "Delete files older than how many days?" 30
$intervalDays  = Read-PositiveInt "Run the task every how many days?" 1

while ($true) {
    $timeInput = Read-Host "Time of day to run (HH:mm, 24h) [02:00]"
    if ([string]::IsNullOrWhiteSpace($timeInput)) { $timeInput = '02:00' }
    $startTime = [datetime]::MinValue
    if ([datetime]::TryParseExact($timeInput.Trim(), 'HH:mm', [Globalization.CultureInfo]::InvariantCulture,
            'None', [ref]$startTime)) { break }
    Write-Host "  Please use the HH:mm format, e.g. 02:00 or 23:30." -ForegroundColor Yellow
}
$startTimeText = $startTime.ToString('HH:mm')

$recurse     = Read-YesNo "Include subfolders?" $true
$removeEmpty = if ($recurse) { Read-YesNo "Remove subfolders left empty after the purge?" $false } else { $false }

$defaultName = 'Purge - ' + (Split-Path -Leaf $targetFolder)
$taskName = Read-Host "Scheduled task name [$defaultName]"
if ([string]::IsNullOrWhiteSpace($taskName)) { $taskName = $defaultName }
$taskName = $taskName.Trim()

if ($hasLocal) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "  Note: this console is not elevated, so installing on the local machine will fail." -ForegroundColor Yellow
    }
}

# --- Preview on every server ---
Write-Host ""
Write-Host "Checking servers..." -ForegroundColor Cyan
$previewArgs = @('Preview', $targetFolder, $olderThanDays, $intervalDays, $startTimeText,
                 $recurse, $removeEmpty, $taskName, $false, $false, '')
$preview = Invoke-OnTargets -Servers $servers -ArgumentList $previewArgs -Credential $credential

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "  Task name        : $taskName"
Write-Host "  Folder           : $targetFolder"
Write-Host "  Delete files     : older than $olderThanDays day(s) (by last modified time)"
Write-Host "  Include subdirs  : $recurse"
Write-Host "  Remove empty dirs: $removeEmpty"
Write-Host "  Schedule         : every $intervalDays day(s) at $startTimeText (each server's local time)"
Write-Host "  Runs as          : SYSTEM"
Write-Host ""
Write-Host "Files that would be deleted if the task ran now:"
$preview | Sort-Object Server | Format-Table Server, Status, Files, SizeMB, Message -AutoSize -Wrap | Out-Host

$ready = @($preview | Where-Object { $_.Status -eq 'OK' } | ForEach-Object { $_.Server })
if ($ready.Count -eq 0) {
    Write-Host "No server is ready for installation. Nothing was installed." -ForegroundColor Red
    return
}
if ($ready.Count -lt $servers.Count) {
    Write-Host "$($servers.Count - $ready.Count) server(s) with errors will be skipped." -ForegroundColor Yellow
}

if (-not (Read-YesNo "Install the scheduled task on $($ready.Count) server(s)?" $true)) {
    Write-Host "Cancelled. Nothing was installed." -ForegroundColor Yellow
    return
}

$replaceExisting = $false
if (@($preview | Where-Object { $_.Status -eq 'OK' -and $_.Message -like '*already exists*' }).Count -gt 0) {
    $replaceExisting = Read-YesNo "Some servers already have a task named '$taskName'. Replace it there?" $false
}
$runNow = Read-YesNo "Run the task once right after installing?" $false

# --- Install ---
Write-Host ""
Write-Host "Installing..." -ForegroundColor Cyan
$installArgs = @('Install', $targetFolder, $olderThanDays, $intervalDays, $startTimeText,
                 $recurse, $removeEmpty, $taskName, $replaceExisting, $runNow, $purgeScript)
$installed = Invoke-OnTargets -Servers $ready -ArgumentList $installArgs -Credential $credential

$installed | Sort-Object Server | Format-Table Server, Status, Message -AutoSize -Wrap | Out-Host

$ok = @($installed | Where-Object { $_.Status -eq 'Installed' }).Count
$color = if ($ok -eq $servers.Count) { 'Green' } else { 'Yellow' }
Write-Host "Installed on $ok of $($servers.Count) server(s)." -ForegroundColor $color
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Run now : Invoke-Command -ComputerName <server> { Start-ScheduledTask -TaskName '$taskName' }"
Write-Host "  Remove  : Invoke-Command -ComputerName <server> { Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false }"
