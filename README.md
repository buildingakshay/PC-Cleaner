# PC Cleaner

A small, safe Windows tool that frees disk space and shows what is slowing the laptop down.

## How to use
Double-click **`Run-PCCleaner.bat`** and pick an option:

1. **Scan only**: shows how much space can be freed. Deletes nothing.
2. **Clean**: asks before cleaning each category.
3. **Clean as Administrator**: also cleans Windows Update, Delivery Optimization, Windows temp and logs.

Or from PowerShell:
```powershell
.\PCCleaner.ps1            # scan only
.\PCCleaner.ps1 -Clean     # clean, asking each time
.\PCCleaner.ps1 -Clean -Yes  # clean everything without asking
```

## What it cleans
Temp files, browser caches (Chrome, Edge, Brave, Firefox), thumbnail cache, crash dumps, Windows Update downloads,
Delivery Optimization cache, Windows logs, app caches (npm, pip, VS Code, Discord, Teams) and the Recycle Bin.

## What it only reports (never deletes)
Downloads / Desktop / Documents sizes, the largest files in Downloads, RAM use, top memory apps,
startup apps, power plan and time since last restart.

## Safety
- Never follows or deletes links/junctions (for example folders that point to another drive).
- Skips files changed in the last 24 hours and files that are in use.
- Never touches personal folders.
