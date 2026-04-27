# Meeting Focus Mode - User Experience Improvement for Windows Notifications. 

Description: A lightweight PowerShell system-tray application for Windows 10/11 that automatically detects active meetings and suppresses notifications using Windows Focus Assist (Do Not Disturb).

## Features

- **Auto-detection** of active meetings in Microsoft Teams, Zoom, and Google Meet
- **System tray icon** with color indicator (green = normal, red = focus mode)
- **Manual toggle** via right-click menu or double-click the tray icon
- **Grace period** — waits 15 seconds after a meeting ends before restoring notifications
- **Auto-detect toggle** — disable automatic detection when you want full manual control
- **Safe exit** — always restores your original notification settings on quit
- **No admin required** — runs entirely in user space

## Quick Start

### Option 1: Double-click the launcher
Double-click **`Start-MeetingFocusMode.bat`** — this runs the script hidden (no console window).

### Option 2: Run from PowerShell, or conhost.exe to limit cmd windows
```powershell
powershell.exe -NonInteractive -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File .\MeetingFocusMode.ps1

``` 

## Usage

Once running, a **green circle icon** appears in your system tray (notification area).

### Right-click menu

| Menu Item | Description |
|-----------|-------------|
| **Status** | Shows current state (Focus ON/OFF and which app was detected) |
| **Enable/Disable Focus Mode** | Manually toggle focus mode on or off |
| **Auto-Detect: ON/OFF** | Enable or disable automatic meeting detection |
| **Exit** | Restore original notification settings and quit |

### Double-click
Double-click the tray icon to quickly toggle focus mode on/off.

### Icon colors
- **Green circle** — Notifications are normal
- **Red circle** — Focus mode is active, notifications are suppressed

## How It Works

1. Every 10 seconds the script checks for active meeting processes:
   - **Teams** — looks for `ms-teams.exe` or `Teams.exe` with meeting-related window titles
   - **Zoom** — looks for `Zoom.exe` with a "Zoom Meeting" window, or the `CptHost.exe` process
   - **Google Meet** — scans Chrome, Edge, Firefox, and Brave window titles for `meet.google.com` or `Google Meet`
2. When a meeting is detected, Focus Assist is enabled via the WNF (Windows Notification Facility) API — the same native mechanism Windows uses internally — so the change reflects immediately in the Action Center / system tray DND indicator. The tray icon turns red.
3. When the meeting ends, a 15-second grace period prevents flickering if you briefly leave and rejoin.
4. On exit, the original Focus Assist setting is restored.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1+ (included with Windows)
- .NET Framework (included with Windows)

## Troubleshooting

- **Icon not visible?** — Check the system tray overflow area (click the ^ arrow near the clock). You can drag the icon to the visible area.
- **Notifications still coming through?** — Some apps (e.g., Slack) have their own notification systems that bypass Windows Focus Assist. This tool controls the OS-level notification suppression.
- **Execution policy error?** — Use the `.bat` launcher, which sets `-ExecutionPolicy Bypass` automatically.

## Customization

Edit these variables near the top of `MeetingFocusMode.ps1`:

| Variable | Default | Description |
|----------|---------|-------------|
| `$script:GracePeriodSec` | `15` | Seconds to wait after meeting ends before restoring notifications |
| `$script:PollIntervalMs` | `10000` | How often to check for meetings (milliseconds) 
