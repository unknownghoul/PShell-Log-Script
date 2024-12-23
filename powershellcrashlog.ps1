# Set execution policy to allow the script to run
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force

# Initialize PowerShell window appearance
$psHost = Get-Host
$psWindow = $psHost.UI.RawUI
$psWindow.BufferSize = New-Object Management.Automation.Host.Size(170, 3000)
$psWindow.WindowSize = New-Object Management.Automation.Host.Size(170, 50)
$psHost.UI.RawUI.BackgroundColor = "Black"
$psHost.UI.RawUI.ForegroundColor = "White"
$Host.UI.RawUI.WindowTitle = "PCHH Crashlog Script"

# Check for administrator privileges
function Check-Admin {
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "============================================" -ForegroundColor Red
        Write-Host "-- Script must be run as Administrator --" -ForegroundColor Red
        Write-Host "============================================" -ForegroundColor Red
        Write-Host "Press any key to exit..." -ForegroundColor Yellow
        $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}

# Setup paths for files and directories
$random = Get-Random -Minimum 1 -Maximum 5000
$minidump = "$env:SystemRoot\minidump"
$source = "$env:SystemRoot\minidump\*.dmp"
$kerneldmp = "$env:SystemRoot\LiveKernelReports\*.dmp"
$File = "$env:TEMP\Crash-LOGS"
$kernelFile = "$File\Live-Kernel-Dumps"
$infofile = "$File\specs-programs.txt"
$ziptar = "$File\Crashlog-Files_$random.zip"
$transcript = "$env:temp\crashlog_transcript.txt"
$sys_eventlog_path = "$File\system_eventlogs.evtx"
$dmpfound = $false
$kerneldmpfound = $false
$errors = @{ fileCreate = $false; Compress = $false; event = $false }

# Function to suppress progress bar output
function Invoke-WithoutProgress {
    param([scriptblock]$ScriptBlock)
    $prevProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        . $ScriptBlock
    } finally {
        $global:ProgressPreference = $prevProgressPreference
    }
}

# Function for check and removal of old dump files
function Cleanup-OldDumps {
    $limit = (Get-Date).AddDays(-60)
    # Remove old MEMORY.dmp files
    Get-ChildItem -Path $env:systemroot -Filter "MEMORY.dmp" -File | Remove-Item -Force -ErrorAction SilentlyContinue
    # Remove old minidump files
    if (Test-Path $minidump) {
        Get-ChildItem -Path $source -Recurse | Where-Object { !$_.PSIsContainer -and $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
        if (Test-Path $source) { $dmpfound = $true }
    }
    # Remove old kernel dump files
    if (Test-Path $kerneldmp) {
        Get-ChildItem -Path $kerneldmp -Recurse | Where-Object { !$_.PSIsContainer -and $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
        if (Test-Path $kerneldmp) { $kerneldmpfound = $true }
    }
}

# Function to create necessary directories and files
function Create-Files {
    Remove-Item -Path "$File\*" -Force -Recurse -ErrorAction SilentlyContinue
    try {
        New-Item -Path $File -ItemType Directory -Force | Out-Null
        New-Item -Path $infofile -ItemType File -Force | Out-Null
        if ($kerneldmpfound) {
            New-Item -Path $kernelFile -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $kerneldmp | Copy-Item -Destination $kernelFile -Force
        }
    }
    catch { $errors.fileCreate = $true }
}

# Function to collect system specifications
function Collect-Specs {
    $secCompat = $false
    $username = whoami
    $cpu = Get-WmiObject Win32_Processor
    $cpuName = $cpu | Select-Object -ExpandProperty Name
    $cpuSpeed = $cpu | Select-Object -ExpandProperty MaxClockSpeed
    $gpu = Get-WmiObject Win32_VideoController | Select-Object -ExpandProperty Name
    $motherboardModel = Get-WmiObject Win32_BaseBoard | Select-Object -ExpandProperty Product
    $bios = Get-WmiObject Win32_BIOS
    $biosVersion = $bios | Select-Object -ExpandProperty SMBIOSBIOSVersion
    $biosDate = $bios | Select-Object -ExpandProperty ReleaseDate
    $os = Get-WmiObject Win32_OperatingSystem
    $osName = $os | Select-Object -ExpandProperty Caption
    $osVersion = $os | Select-Object -ExpandProperty Version
    $uptime = (Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $installedMemory = Get-WmiObject Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory
    $ramSpeed = Get-WmiObject Win32_PhysicalMemory | Select-Object -ExpandProperty Speed

    # Write collected data to the file
    Add-Content -Path $infofile -Value "Username: $username"
    Add-Content -Path $infofile -Value "`nCPU: $cpuName, $cpuSpeed MHz"
    Add-Content -Path $infofile -Value "GPU: $gpu"
    Add-Content -Path $infofile -Value "Motherboard: $motherboardModel"
    Add-Content -Path $infofile -Value "BIOS: $biosVersion, $([System.Management.ManagementDateTimeConverter]::ToDateTime($biosDate))"
    Add-Content -Path $infofile -Value "`nOS: $osName $osVersion"
    Add-Content -Path $infofile -Value "System Uptime: $($uptime.Days) days, $($uptime.Hours) hours"
    Add-Content -Path $infofile -Value "RAM: $([math]::Round($installedMemory/1GB)) GB at $ramSpeed MT/s"
}

# Function to collect installed programs
function Collect-Programs {
    $installedPrograms = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
                         Where-Object { $_.DisplayName } | Select-Object DisplayName
    $programs = $installedPrograms | Out-String
    Add-Content -Path $infofile -Value "`nInstalled Programs:`n $programs"
}

# Function to collect event logs
function Collect-EventLogs {
    $startTime = (Get-Date).AddDays(-14).ToString("yyyy-MM-ddTHH:mm:ss")
    try {
        wevtutil epl System $sys_eventlog_path /q:"*[System[TimeCreated[@SystemTime>='$startTime']]]"
    }
    catch { $errors.event = $true }
}

# Function to compress collected files
function Compress-Files {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "DisplayParameters" -Value 1 -Type DWord -Force
    $filesToCompress = @($infofile, $sys_eventlog_path)
    if ($dmpfound) { $filesToCompress += Get-ChildItem -Path $source }
    if ($kerneldmpfound) { $filesToCompress += $kernelFile }

    try {
        Invoke-WithoutProgress { Compress-Archive -Path $filesToCompress -CompressionLevel Optimal -DestinationPath $ziptar -Force }
    }
    catch {
        $errors.Compress = $true
    }
}

# Final step to clean up and prompt user
function End-Script {
    Write-Host "Files are ready to be shared!"
    Start-Process explorer.exe -ArgumentList $File
    $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# Main script execution
Check-Admin
Cleanup-OldDumps
Create-Files
Collect-Specs
Collect-Programs
Collect-EventLogs
Compress-Files


# ------------------------------------------------------------
# PowerShell Crash Log Script
# Created by: [Rat's PC Cult]
# ------------------------------------------------------------


End-Script