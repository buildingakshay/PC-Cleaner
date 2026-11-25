<#
  PC Cleaner - frees disk space and shows what is slowing the laptop down.

  Usage (from PowerShell in this folder):
    .\PCCleaner.ps1              # Scan only. Nothing is deleted.
    .\PCCleaner.ps1 -Clean       # Scan, then ask before cleaning each category.
    .\PCCleaner.ps1 -Clean -Yes  # Clean every safe category without asking.

  Safety rules built in:
    - Scan mode never changes anything.
    - Only caches / temp / junk folders are cleaned. Documents, Downloads, Desktop,
      videos and photos are only REPORTED, never deleted.
    - Links/junctions (for example C: folders that point to D:\MASH) are never
      followed or deleted.
    - Files changed in the last 24 hours are skipped (they may be in use).
    - Claude's own working folder in Temp is skipped.
    - Locked files are skipped silently.
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Yes,
    [int]$MinAgeHours = 24
)

$ErrorActionPreference = 'SilentlyContinue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$LocalApp = $env:LOCALAPPDATA
$RoamApp  = $env:APPDATA
$WinDir   = $env:WINDIR
$Cutoff   = (Get-Date).AddHours(-$MinAgeHours)

# Folders that must never be touched, even if they sit inside a cleanable folder.
$Protected = @(
    (Join-Path $env:TEMP 'claude'),
    (Join-Path $LocalApp 'Temp\claude')
) | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

# Real space a file takes on disk. Some Windows caches use "sparse" files whose
# listed size is far bigger than what they actually occupy, so Length alone lies.
if (-not ('PCCleaner.Disk' -as [type])) {
    Add-Type -Namespace PCCleaner -Name Disk -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@
}
function Get-DiskSize([IO.FileInfo]$file) {
    $high = [uint32]0
    $low = [PCCleaner.Disk]::GetCompressedFileSizeW($file.FullName, [ref]$high)
    if ($low -eq [uint32]::MaxValue -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) { return $file.Length }
    return ([int64]$high -shl 32) + $low
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { '{0:N0} MB' -f ($bytes / 1MB) }
    else { '{0:N0} KB' -f ($bytes / 1KB) }
}

function Test-Protected([string]$path) {
    $p = $path.TrimEnd('\').ToLowerInvariant()
    foreach ($x in $Protected) { if ($p -eq $x -or $p.StartsWith($x + '\')) { return $true } }
    return $false
}

function Test-Link([IO.FileSystemInfo]$item) {
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Walks a folder without ever entering links/junctions. Returns [size, count].
function Measure-Folder([string]$path) {
    $size = [int64]0; $count = 0
    if (-not (Test-Path -LiteralPath $path)) { return @(0, 0) }
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $path -Force))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if (Test-Protected $dir.FullName) { continue }
        try { $children = $dir.EnumerateFileSystemInfos() } catch { continue }
        try {
            foreach ($c in $children) {
                if (Test-Link $c) { continue }
                if ($c -is [IO.DirectoryInfo]) { $stack.Push($c) }
                elseif ($c.LastWriteTime -lt $Cutoff) { $size += (Get-DiskSize $c); $count++ }
            }
        } catch { }
    }
    return @($size, $count)
}

# Deletes old files inside a folder (never the folder itself, never links). Returns bytes freed.
function Clear-Folder([string]$path) {
    $freed = [int64]0
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $root = Get-Item -LiteralPath $path -Force
    if (Test-Link $root) { return 0 }
    $dirs = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if (Test-Protected $dir.FullName) { continue }
        try { $children = @($dir.EnumerateFileSystemInfos()) } catch { continue }
        foreach ($c in $children) {
            if (Test-Link $c) { continue }
            if ($c -is [IO.DirectoryInfo]) { $stack.Push($c); $dirs.Add($c) }
            elseif ($c.LastWriteTime -lt $Cutoff) {
                try {
                    $len = Get-DiskSize $c
                    if ($c.IsReadOnly) { $c.IsReadOnly = $false }
                    $c.Delete(); $freed += $len
                } catch { }
            }
        }
    }
    # Remove folders left empty, deepest first.
    $dirs | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
        try { if (-not ($_.EnumerateFileSystemInfos() | Select-Object -First 1)) { $_.Delete() } } catch { }
    }
    return $freed
}

# ---------------- What can be cleaned ----------------
$chromeLike = @(
    @{ Name = 'Google Chrome';  Root = "$LocalApp\Google\Chrome\User Data" },
    @{ Name = 'Microsoft Edge'; Root = "$LocalApp\Microsoft\Edge\User Data" },
    @{ Name = 'Brave';          Root = "$LocalApp\BraveSoftware\Brave-Browser\User Data" }
)
$browserCache = @()
foreach ($b in $chromeLike) {
    if (Test-Path $b.Root) {
        Get-ChildItem -LiteralPath $b.Root -Directory -Force | Where-Object {
            $_.Name -eq 'Default' -or $_.Name -like 'Profile *'
        } | ForEach-Object {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') {
                $browserCache += (Join-Path $_.FullName $sub)
            }
        }
    }
}
if (Test-Path "$LocalApp\Mozilla\Firefox\Profiles") {
    Get-ChildItem "$LocalApp\Mozilla\Firefox\Profiles" -Directory -Force | ForEach-Object {
        $browserCache += (Join-Path $_.FullName 'cache2')
    }
}

$Categories = @(
    @{ Name = 'Your temp files';             Admin = $false; Paths = @($env:TEMP) }
    @{ Name = 'Windows temp files';          Admin = $true;  Paths = @("$WinDir\Temp") }
    @{ Name = 'Browser caches (close browsers first)'; Admin = $false; Paths = $browserCache }
    @{ Name = 'Thumbnail & icon cache';      Admin = $false; Paths = @("$LocalApp\Microsoft\Windows\Explorer") ; Filter = 'thumbcache_*.db','iconcache_*.db' }
    @{ Name = 'Crash dumps & error reports'; Admin = $false; Paths = @("$LocalApp\CrashDumps", "$LocalApp\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue") }
    @{ Name = 'Windows Update downloads';    Admin = $true;  Paths = @("$WinDir\SoftwareDistribution\Download") }
    @{ Name = 'Delivery Optimization cache'; Admin = $true;  Paths = @("$WinDir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
    @{ Name = 'Windows log files';           Admin = $true;  Paths = @("$WinDir\Logs\CBS", "$WinDir\Logs\DISM") }
    @{ Name = 'App caches (npm, pip, VS Code, Discord, Teams)'; Admin = $false; Paths = @(
        "$LocalApp\npm-cache", "$RoamApp\npm-cache", "$LocalApp\pip\Cache", "$LocalApp\Yarn\Cache",
        "$RoamApp\Code\Cache", "$RoamApp\Code\CachedData", "$RoamApp\Code\Code Cache",
        "$RoamApp\discord\Cache", "$RoamApp\discord\Code Cache",
        "$RoamApp\Microsoft\Teams\Cache", "$LocalApp\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache") }
)

function Measure-Category($cat) {
    $size = [int64]0; $count = 0
    foreach ($p in $cat.Paths) {
        if ($cat.Filter) {
            foreach ($f in $cat.Filter) {
                Get-ChildItem -LiteralPath $p -Filter $f -File -Force | ForEach-Object { $size += (Get-DiskSize $_); $count++ }
            }
        } else {
            $r = Measure-Folder $p; $size += $r[0]; $count += $r[1]
        }
    }
    return @($size, $count)
}

function Clear-Category($cat) {
    $freed = [int64]0
    foreach ($p in $cat.Paths) {
        if ($cat.Filter) {
            foreach ($f in $cat.Filter) {
                Get-ChildItem -LiteralPath $p -Filter $f -File -Force | ForEach-Object {
                    $len = Get-DiskSize $_; try { $_.Delete(); $freed += $len } catch { }
                }
            }
        } else { $freed += Clear-Folder $p }
    }
    return $freed
}

function Get-RecycleBinSize {
    $size = [int64]0; $count = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(0xA)
        foreach ($i in $bin.Items()) { $size += [int64]$i.ExtendedProperty('Size'); $count++ }
    } catch { }
    return @($size, $count)
}

# ---------------- Report ----------------
Write-Host ''
Write-Host '==================  PC CLEANER  ==================' -ForegroundColor Cyan
Write-Host ("Mode: {0}   Admin: {1}" -f ($(if ($Clean) { 'CLEAN' } else { 'SCAN ONLY (nothing deleted)' }), $isAdmin))
Write-Host ''
Write-Host 'DRIVES' -ForegroundColor Yellow
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and ($_.Used + $_.Free) -gt 0 } | ForEach-Object {
    $total = $_.Used + $_.Free; $pct = [math]::Round($_.Free / $total * 100)
    $color = if ($pct -lt 10) { 'Red' } elseif ($pct -lt 20) { 'Yellow' } else { 'Green' }
    Write-Host ("  {0}:  {1} free of {2}  ({3}% free)" -f $_.Name, (Format-Size $_.Free), (Format-Size $total), $pct) -ForegroundColor $color
}

Write-Host ''
Write-Host 'CLEANABLE JUNK (files older than' $MinAgeHours 'hours)' -ForegroundColor Yellow
$results = @()
foreach ($cat in $Categories) {
    $r = Measure-Category $cat
    $results += [pscustomobject]@{ Cat = $cat; Size = $r[0]; Count = $r[1] }
    $note = if ($cat.Admin -and -not $isAdmin) { '  (needs Run as administrator to clean)' } else { '' }
    Write-Host ("  {0,-48} {1,10}  {2,7} files{3}" -f $cat.Name, (Format-Size $r[0]), $r[1], $note)
}
$rb = Get-RecycleBinSize
Write-Host ("  {0,-48} {1,10}  {2,7} items" -f 'Recycle Bin', (Format-Size $rb[0]), $rb[1])
$totalJunk = ($results | Measure-Object Size -Sum).Sum + $rb[0]
Write-Host ("  {0,-48} {1,10}" -f 'TOTAL', (Format-Size $totalJunk)) -ForegroundColor Green

# Big things worth a look (report only)
Write-Host ''
Write-Host 'BIG FOLDERS IN YOUR USER PROFILE (report only - you decide)' -ForegroundColor Yellow
foreach ($f in 'Downloads', 'Desktop', 'Documents', 'Videos', 'Pictures', 'Music') {
    $p = Join-Path $env:USERPROFILE $f
    if (Test-Path $p) {
        $r = Measure-Folder $p
        Write-Host ("  {0,-12} {1,10}" -f $f, (Format-Size $r[0]))
    }
}
Write-Host ''
Write-Host 'LARGEST FILES IN DOWNLOADS (report only)' -ForegroundColor Yellow
Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -File -Recurse -Force -Attributes !ReparsePoint |
    Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host ("  {0,10}  {1}" -f (Format-Size $_.Length), $_.Name)
    }

Write-Host ''
Write-Host 'HIBERNATION FILE' -ForegroundColor Yellow
$hib = Get-Item "$env:SystemDrive\hiberfil.sys" -Force
if ($hib) { Write-Host ("  hiberfil.sys is {0}. If you never use Hibernate, 'powercfg /h off' (admin) frees it." -f (Format-Size $hib.Length)) }
else { Write-Host '  Hibernation is off.' }

# ---------------- Speed ----------------
Write-Host ''
Write-Host 'SPEED CHECK' -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
$usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
Write-Host ("  RAM in use: {0}% of {1}" -f $usedPct, (Format-Size ($os.TotalVisibleMemorySize * 1KB)))
$uptime = (Get-Date) - $os.LastBootUpTime
Write-Host ("  Time since last restart: {0} days {1} h{2}" -f $uptime.Days, $uptime.Hours, $(if ($uptime.Days -ge 7) { '  <- restart soon, it helps' } else { '' }))
$plan = (powercfg /getactivescheme) -replace '.*\((.*)\).*', '$1'
Write-Host "  Power plan: $plan"

Write-Host ''
Write-Host '  Top 10 apps using memory right now:'
Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Mem = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum; N = $_.Count }
} | Sort-Object Mem -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Host ("    {0,10}  {1} ({2})" -f (Format-Size $_.Mem), $_.Name, $_.N)
}

Write-Host ''
Write-Host '  Apps that start with Windows (turn off unneeded ones in Task Manager > Startup apps):'
Get-CimInstance Win32_StartupCommand | Sort-Object Name | ForEach-Object {
    Write-Host ("    - {0}" -f $_.Name)
}

# ---------------- Clean ----------------
if (-not $Clean) {
    Write-Host ''
    Write-Host 'Scan finished. Nothing was deleted.' -ForegroundColor Cyan
    Write-Host 'To clean, run:  .\PCCleaner.ps1 -Clean   (Run as administrator to clean Windows folders too)'
    return
}

function Confirm-Step([string]$msg) {
    if ($Yes) { return $true }
    $a = Read-Host "$msg  [y/N]"
    return ($a -match '^(y|yes)$')
}

$before = (Get-PSDrive C).Free
Write-Host ''
Write-Host 'CLEANING' -ForegroundColor Yellow
foreach ($r in $results) {
    if ($r.Size -le 0) { continue }
    if ($r.Cat.Admin -and -not $isAdmin) { Write-Host ("  Skipped {0} (needs administrator)" -f $r.Cat.Name); continue }
    if (Confirm-Step ("  Clean {0} ({1})?" -f $r.Cat.Name, (Format-Size $r.Size))) {
        $cBefore = (Get-PSDrive C).Free
        if ($r.Cat.Name -like 'Delivery Optimization*' -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
            # Windows' own command: clears the cache safely while the service is running.
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
            $freed = [math]::Max(0, (Get-PSDrive C).Free - $cBefore)
        } else {
            if ($r.Cat.Name -like 'Windows Update*') { Stop-Service wuauserv -Force -WarningAction SilentlyContinue }
            $freed = Clear-Category $r.Cat
            if ($r.Cat.Name -like 'Windows Update*') { Start-Service wuauserv -WarningAction SilentlyContinue }
        }
        Write-Host ("    freed {0}" -f (Format-Size $freed)) -ForegroundColor Green
    }
}
if ($rb[1] -gt 0 -and (Confirm-Step ("  Empty the Recycle Bin ({0})? This cannot be undone." -f (Format-Size $rb[0])))) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Host '    Recycle Bin emptied' -ForegroundColor Green
}

$after = (Get-PSDrive C).Free
Write-Host ''
Write-Host ("Done. C: free space went from {0} to {1} (+{2})." -f (Format-Size $before), (Format-Size $after), (Format-Size ([math]::Max(0, $after - $before)))) -ForegroundColor Cyan
