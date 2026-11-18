<#
.SYNOPSIS
    Route Windows Error Reporting dumps for zerk_play.exe to a folder you choose.

.DESCRIPTION
    The app used to write its own MiniDumpNormal from inside the crashing process.
    That is the worst possible moment to serialise a process: the crash happened in
    a driver worker thread, the other threads were never suspended, and the file was
    written seconds after the fault (so the mpv log around it is noisy).

    WER writes the dump from outside the process, at the moment of the fault, and
    includes every thread - which is what `cdb -z <dmp> !analyze -v` needs to name
    the faulting module and the failing call.

    This script only sets the per-executable LocalDumps policy. It needs an
    elevated shell because LocalDumps lives under HKLM.

.PARAMETER Folder
    Where dumps land. Defaults to D:\crashdumps - put it off the system drive, a
    full dump of this player is a few hundred MB and C: is nearly full.

.PARAMETER DumpCount
    How many dumps to keep. Older ones are overwritten by Windows.

.PARAMETER Undo
    Remove the policy and stop collecting.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\wer-localdumps.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\wer-localdumps.ps1 -Folder E:\dumps -DumpCount 3

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\wer-localdumps.ps1 -Undo
#>
param(
    [string]$Folder = 'D:\crashdumps',
    [int]$DumpCount = 5,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'

$exe = 'zerk_play.exe'
$root = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$key = Join-Path $root $exe

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'LocalDumps is under HKLM - run this from an elevated PowerShell window.'
}

if ($Undo) {
    if (Test-Path $key) {
        Remove-Item $key -Recurse -Force
        Write-Host "removed $key - dump collection is off"
    } else {
        Write-Host 'nothing to remove: the policy was not set'
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $Folder | Out-Null
if (-not (Test-Path $root)) { New-Item -Path $root -Force | Out-Null }
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }

# DumpType 2 = full dump: !analyze needs the whole address space to resolve the
# driver stack, and a mini dump is exactly what hid the truth last time.
New-ItemProperty -Path $key -Name DumpFolder -PropertyType ExpandString -Value $Folder -Force | Out-Null
New-ItemProperty -Path $key -Name DumpType   -PropertyType DWord        -Value 2       -Force | Out-Null
New-ItemProperty -Path $key -Name DumpCount  -PropertyType DWord        -Value $DumpCount -Force | Out-Null

Write-Host ''
Write-Host "zerk_play.exe crashes will now be written to: $Folder"
Write-Host "  full dumps, newest $DumpCount kept"
Write-Host ''
Write-Host 'Verify with:'
Write-Host "  Get-ItemProperty '$key'"
Write-Host 'After the next crash:'
Write-Host "  Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 5"
Write-Host "  cdb -z `"$Folder\zerk_play.exe.<pid>.dmp`" -c `".exr -1; !analyze -v; lm; ~*kb; q`""
