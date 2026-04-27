# 04-26
# Version 1.1
# Author: Jon Carracino
# Windows - User Experience Improvement Tools
<#
.SYNOPSIS
    Meeting Focus Mode — System tray app that auto-detects meetings (Zoom, Teams, Google Meet) and enables
    Windows Focus Assist (Do Not Disturb) to suppress notifications.

.DESCRIPTION
    Detects active meetings in Microsoft Teams, Zoom, and Google Meet (Chrome-based for Meets).
    Toggles Windows Do Not Disturb via registry + WM_SETTINGCHANGE broadcast. Provides a system tray icon
    with manual override and auto-detect toggle.

.NOTES
    No admin privileges required. Works on Windows 10/11.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:FocusActive       = $false
$script:AutoDetect        = $true
$script:ManualOverride    = $false   # true when user manually toggled
$script:MeetingEndTime    = $null    # tracks when meeting was last seen
$script:GracePeriodSec    = 15
$script:PollIntervalMs    = 10000   # 10 seconds
$script:OriginalFocusAssist = $null  # saved on startup to restore on exit
$script:DetectedApp       = ""

# Log file in the same directory as the script
$script:LogFile = Join-Path $PSScriptRoot "MeetingFocusMode.log"

# DND registry path (used to READ current DND state for verification)
$script:DndRegPath  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
$script:DndRegName  = "NOC_GLOBAL_SETTING_TOASTS_ENABLED"

# Keyboard simulation timing (ms) — tune these if the toggle is unreliable
$script:DndOpenDelayMs   = 800   # wait after Win+N for notification panel to open
$script:DndToggleDelayMs = 400   # wait after Space for toggle to register
$script:DndCloseDelayMs  = 300   # wait after Escape for panel to close
$script:DndVerifyDelayMs = 500   # wait before reading registry to verify state

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $entry = "[$ts] [$Level] $Message"
    try { Add-Content -Path $script:LogFile -Value $entry -Force -ErrorAction Stop }
    catch { Write-Host $entry }
}

# ---------------------------------------------------------------------------
# Icon generation — create simple colored circle icons in memory
# ---------------------------------------------------------------------------
function New-CircleIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    # Add a thin border for visibility
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 0, 0, 0), 1)
    $g.DrawEllipse($pen, 1, 1, 14, 14)
    $pen.Dispose()
    $brush.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

$script:IconGreen = New-CircleIcon -Color ([System.Drawing.Color]::FromArgb(255, 46, 204, 64))
$script:IconRed   = New-CircleIcon -Color ([System.Drawing.Color]::FromArgb(255, 220, 50, 50))

# ---------------------------------------------------------------------------
# Do Not Disturb helpers
# Detection: WNF API + COM IQuietHoursSettings (same approach as
#   https://github.com/bitdisaster/windows-focus-assist)
# Toggling: keyboard simulation  Win+N -> Space -> Escape
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class DndKeyboard {
    private const byte VK_LWIN   = 0x5B;
    private const byte VK_N      = 0x4E;
    private const byte VK_SPACE  = 0x20;
    private const byte VK_ESCAPE = 0x1B;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern void keybd_event(
        byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public static void SendWinN() {
        keybd_event(VK_LWIN,  0, 0, UIntPtr.Zero);
        keybd_event(VK_N,     0, 0, UIntPtr.Zero);
        Thread.Sleep(50);
        keybd_event(VK_N,     0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_LWIN,  0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void SendSpace() {
        keybd_event(VK_SPACE, 0, 0, UIntPtr.Zero);
        Thread.Sleep(50);
        keybd_event(VK_SPACE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void SendEscape() {
        keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
        Thread.Sleep(50);
        keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void Wait(int ms) {
        Thread.Sleep(ms);
    }
}

/// <summary>
/// Reads Focus Assist / DND state using WNF + COM, matching the approach from
/// https://github.com/bitdisaster/windows-focus-assist
/// Returns: -2=NotSupported, -1=Failed, 0=Off, 1=PriorityOnly, 2=AlarmsOnly
/// </summary>
public static class FocusAssistStatus {

    // ---------- WNF method ----------
    [DllImport("ntdll.dll")]
    private static extern int NtQueryWnfStateData(
        IntPtr pStateName,
        IntPtr pTypeId,
        IntPtr pExplicitScope,
        out int pnChangeStamp,
        IntPtr pBuffer,
        ref int pnBufferSize);

    public static int GetViaWnf() {
        // WNF_SHEL_QUIETHOURS_ACTIVE_PROFILE_CHANGED  {0xA3BF1C75, 0x0D83063E}
        IntPtr statePtr = Marshal.AllocHGlobal(8);
        try {
            Marshal.WriteInt32(statePtr, 0, unchecked((int)0xA3BF1C75));
            Marshal.WriteInt32(statePtr, 4, 0x0D83063E);

            int changeStamp;
            int bufferSize = 4;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try {
                int status = NtQueryWnfStateData(statePtr, IntPtr.Zero, IntPtr.Zero,
                    out changeStamp, buffer, ref bufferSize);
                if (status >= 0 && bufferSize >= 4) {
                    int val = Marshal.ReadInt32(buffer);
                    if (val >= 0 && val <= 2) return val;
                }
                return -1;
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        } finally {
            Marshal.FreeHGlobal(statePtr);
        }
    }

    // ---------- COM method ----------
    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
        IntPtr pUnkOuter,
        uint dwClsContext,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        out IntPtr ppv);

    [DllImport("ole32.dll")]
    private static extern int CoInitialize(IntPtr pvReserved);

    [DllImport("ole32.dll")]
    private static extern void CoTaskMemFree(IntPtr pv);

    // IUnknown: 0=QueryInterface, 1=AddRef, 2=Release
    // IQuietHoursSettings: 3=get_UserSelectedProfile, 4=put_UserSelectedProfile, 5=GetProfile
    private delegate int GetUserSelectedProfileDelegate(IntPtr pThis, out IntPtr profileId);

    private static readonly Guid CLSID_QuietHoursSettings =
        new Guid("f53321fa-34f8-4b7f-b9a3-361877cb94cf");
    private static readonly Guid IID_IQuietHoursSettings =
        new Guid("6bff4732-81ec-4ffb-ae67-b6c1bc29631f");

    public static int GetViaCom() {
        int hr = CoInitialize(IntPtr.Zero);

        IntPtr pSettings = IntPtr.Zero;
        hr = CoCreateInstance(CLSID_QuietHoursSettings, IntPtr.Zero,
            4 /* CLSCTX_LOCAL_SERVER */, IID_IQuietHoursSettings, out pSettings);
        if (hr < 0 || pSettings == IntPtr.Zero) return -1;

        try {
            // Read vtable pointer, then slot 3 (get_UserSelectedProfile)
            IntPtr vtable = Marshal.ReadIntPtr(pSettings);
            IntPtr fnPtr  = Marshal.ReadIntPtr(vtable, 3 * IntPtr.Size);
            var getProfile = (GetUserSelectedProfileDelegate)
                Marshal.GetDelegateForFunctionPointer(fnPtr, typeof(GetUserSelectedProfileDelegate));

            IntPtr profileIdPtr;
            hr = getProfile(pSettings, out profileIdPtr);
            if (hr < 0 || profileIdPtr == IntPtr.Zero) return -1;

            try {
                string profileId = Marshal.PtrToStringUni(profileIdPtr);
                if (profileId != null) {
                    if (profileId.IndexOf("PriorityOnly", StringComparison.OrdinalIgnoreCase) >= 0)
                        return 1;
                    if (profileId.IndexOf("AlarmsOnly", StringComparison.OrdinalIgnoreCase) >= 0)
                        return 2;
                    if (profileId.IndexOf("Unrestricted", StringComparison.OrdinalIgnoreCase) >= 0)
                        return 0;
                }
                return -1;
            } finally {
                CoTaskMemFree(profileIdPtr);
            }
        } finally {
            // Release COM object
            Marshal.Release(pSettings);
        }
    }

    /// <summary>
    /// Tries WNF first, falls back to COM. Returns 0=Off, 1=Priority, 2=Alarms, -1=Failed.
    /// </summary>
    public static int Get() {
        try {
            int result = GetViaWnf();
            if (result >= 0) return result;
        } catch {}
        try {
            int result = GetViaCom();
            if (result >= 0) return result;
        } catch {}
        return -1;
    }
}
"@

function Get-DndState {
    <# Returns $true if DND/Focus Assist is ON, $false if OFF, $null if detection failed.
       Uses WNF API + COM IQuietHoursSettings (same approach as bitdisaster/windows-focus-assist). #>
    try {
        $status = [FocusAssistStatus]::Get()
        Write-Log "  Get-DndState raw value: $status (0=Off, 1=Priority, 2=Alarms, -1=Failed)"
        if ($status -lt 0) { return $null }
        return ($status -gt 0)  # 1 or 2 = DND/Focus is ON
    } catch {
        Write-Log "  Get-DndState exception: $_" -Level ERROR
        return $null
    }
}

function Invoke-DndToggle {
    <# Performs the Win+N → Space → Escape keystroke sequence to toggle DND. #>
    # Close any panel that might already be open
    Write-Log "  Sending Escape (clear open panels)"
    [DndKeyboard]::SendEscape()
    [DndKeyboard]::Wait(200)

    # Open notification center
    Write-Log "  Sending Win+N (open notification center)"
    [DndKeyboard]::SendWinN()
    [DndKeyboard]::Wait($script:DndOpenDelayMs)

    # Toggle DND
    Write-Log "  Sending Space (toggle DND)"
    [DndKeyboard]::SendSpace()
    [DndKeyboard]::Wait($script:DndToggleDelayMs)

    # Close notification center
    Write-Log "  Sending Escape (close notification center)"
    [DndKeyboard]::SendEscape()
    [DndKeyboard]::Wait($script:DndCloseDelayMs)
}

function Save-OriginalFocusAssist {
    $script:OriginalFocusAssist = Get-DndState
    Write-Log "Saved original DND state: $($script:OriginalFocusAssist) (true=ON, false=OFF)"
}

function Enable-FocusAssist {
    <# Enable DND via keyboard simulation. Verifies via registry and retries once if needed. #>
    Write-Log ">>> Enable DND requested"

    $before = Get-DndState
    Write-Log "DND state before: $before (true=ON, false=OFF)"

    if ($before -eq $true) {
        Write-Log "DND is already ON, no action needed"
        return
    }

    Invoke-DndToggle
    [DndKeyboard]::Wait($script:DndVerifyDelayMs)

    $after = Get-DndState
    Write-Log "DND state after toggle: $after"

    if ($after -eq $true) {
        Write-Log "DND successfully ENABLED"
        return
    }

    # Retry once
    Write-Log "DND not confirmed ON after first attempt, retrying..." -Level WARN
    Invoke-DndToggle
    [DndKeyboard]::Wait($script:DndVerifyDelayMs)

    $retry = Get-DndState
    Write-Log "DND state after retry: $retry"
    if ($retry -eq $true) {
        Write-Log "DND successfully ENABLED on retry"
    } else {
        Write-Log "DND ENABLE FAILED after retry (state: $retry)" -Level ERROR
    }
}

function Disable-FocusAssist {
    <# Disable DND via keyboard simulation. Verifies via registry and retries once if needed. #>
    Write-Log ">>> Disable DND requested"

    $before = Get-DndState
    Write-Log "DND state before: $before (true=ON, false=OFF)"

    if ($before -eq $false) {
        Write-Log "DND is already OFF, no action needed"
        return
    }

    Invoke-DndToggle
    [DndKeyboard]::Wait($script:DndVerifyDelayMs)

    $after = Get-DndState
    Write-Log "DND state after toggle: $after"

    if ($after -eq $false) {
        Write-Log "DND successfully DISABLED"
        return
    }

    # Retry once
    Write-Log "DND not confirmed OFF after first attempt, retrying..." -Level WARN
    Invoke-DndToggle
    [DndKeyboard]::Wait($script:DndVerifyDelayMs)

    $retry = Get-DndState
    Write-Log "DND state after retry: $retry"
    if ($retry -eq $false) {
        Write-Log "DND successfully DISABLED on retry"
    } else {
        Write-Log "DND DISABLE FAILED after retry (state: $retry)" -Level ERROR
    }
}

function Restore-FocusAssist {
    <# Restore DND to the state captured at startup. #>
    Write-Log ">>> Restore original DND state (original was: $($script:OriginalFocusAssist))"
    $current = Get-DndState
    if ($current -eq $script:OriginalFocusAssist) {
        Write-Log "DND already matches original state, no action needed"
        return
    }
    if ($script:OriginalFocusAssist -eq $true) {
        Enable-FocusAssist
    } else {
        Disable-FocusAssist
    }
}

# ---------------------------------------------------------------------------
# Meeting detection
# ---------------------------------------------------------------------------
function Test-MeetingActive {
    <#
    .SYNOPSIS
        Returns $true and sets $script:DetectedApp if an active meeting is found.
    #>
    $script:DetectedApp = ""

    # --- Microsoft Teams ---
    # New Teams (ms-teams.exe) and classic Teams (Teams.exe)
    try {
        $teamsProcs = Get-Process -Name "ms-teams", "Teams" -ErrorAction SilentlyContinue
        foreach ($p in $teamsProcs) {
            if ($p.MainWindowTitle -match "(?i)meeting|call|sharing") {
                $script:DetectedApp = "Teams"
                return $true
            }
        }
        # Also check for the Teams meeting window by looking at all windows
        $teamsWindows = $teamsProcs | Where-Object { $_.MainWindowHandle -ne 0 }
        foreach ($w in $teamsWindows) {
            $title = $w.MainWindowTitle
            if ($title -match "(?i)Microsoft Teams" -and ($title -match "(?i)\|")) {
                # Teams often shows "Name | Microsoft Teams" during a call
                $script:DetectedApp = "Teams"
                return $true
            }
        }
    } catch {}

    # --- Zoom ---
    try {
        $zoomProcs = Get-Process -Name "Zoom" -ErrorAction SilentlyContinue
        foreach ($p in $zoomProcs) {
            $title = $p.MainWindowTitle
            if ($title -match "(?i)zoom meeting|zoom webinar") {
                $script:DetectedApp = "Zoom"
                return $true
            }
        }
        # Zoom also spawns CptHost.exe for meetings
        $zoomMeeting = Get-Process -Name "CptHost" -ErrorAction SilentlyContinue
        if ($zoomMeeting) {
            $script:DetectedApp = "Zoom"
            return $true
        }
    } catch {}

    # --- Google Meet (browser window titles) ---
    try {
        $browsers = Get-Process -Name "chrome", "msedge", "firefox", "brave" -ErrorAction SilentlyContinue
        foreach ($p in $browsers) {
            if ($p.MainWindowTitle -match "(?i)meet\.google\.com|Google Meet") {
                $script:DetectedApp = "Google Meet"
                return $true
            }
        }
    } catch {}

    return $false
}

# ---------------------------------------------------------------------------
# UI State management
# ---------------------------------------------------------------------------
function Set-FocusOn {
    param([string]$Reason = "")
    if ($script:FocusActive) { return }
    $script:FocusActive = $true
    Write-Log "Set-FocusOn called (Reason: $Reason)"
    Enable-FocusAssist

    $label = if ($Reason) { "Focus ON - $Reason" } else { "Focus ON" }
    $script:NotifyIcon.Icon = $script:IconRed
    $script:NotifyIcon.Text = "Meeting Focus Mode: $label"
    $script:StatusMenuItem.Text = "[X] $label"
    $script:ToggleMenuItem.Text = "Disable Focus Mode"
    $script:NotifyIcon.ShowBalloonTip(3000, "Meeting Focus Mode", "$label - Notifications suppressed", [System.Windows.Forms.ToolTipIcon]::Info)
}

function Set-FocusOff {
    if (-not $script:FocusActive) { return }
    $script:FocusActive = $false
    Write-Log "Set-FocusOff called"
    Disable-FocusAssist

    $script:NotifyIcon.Icon = $script:IconGreen
    $script:NotifyIcon.Text = "Meeting Focus Mode: Notifications ON"
    $script:StatusMenuItem.Text = "[O] Notifications ON"
    $script:ToggleMenuItem.Text = "Enable Focus Mode"
    $script:NotifyIcon.ShowBalloonTip(3000, "Meeting Focus Mode", "Focus OFF - Notifications restored", [System.Windows.Forms.ToolTipIcon]::Info)
}

# ---------------------------------------------------------------------------
# Build system tray UI
# ---------------------------------------------------------------------------
$script:AppContext = New-Object System.Windows.Forms.ApplicationContext

# NotifyIcon
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Icon = $script:IconGreen
$script:NotifyIcon.Text = "Meeting Focus Mode: Notifications ON"
$script:NotifyIcon.Visible = $true

# Context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Status item (disabled, just for display)
$script:StatusMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:StatusMenuItem.Text = "[O] Notifications ON"
$script:StatusMenuItem.Enabled = $false
$contextMenu.Items.Add($script:StatusMenuItem) | Out-Null

$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Toggle Focus Mode
$script:ToggleMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:ToggleMenuItem.Text = "Enable Focus Mode"
$script:ToggleMenuItem.Add_Click({
    $script:ManualOverride = $true
    if ($script:FocusActive) {
        Set-FocusOff
    } else {
        Set-FocusOn -Reason "Manual"
    }
})
$contextMenu.Items.Add($script:ToggleMenuItem) | Out-Null

# Auto-Detect toggle
$script:AutoDetectMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:AutoDetectMenuItem.Text = "Auto-Detect: ON"
$script:AutoDetectMenuItem.Checked = $true
$script:AutoDetectMenuItem.Add_Click({
    $script:AutoDetect = -not $script:AutoDetect
    $script:ManualOverride = $false
    if ($script:AutoDetect) {
        $script:AutoDetectMenuItem.Text = "Auto-Detect: ON"
        $script:AutoDetectMenuItem.Checked = $true
    } else {
        $script:AutoDetectMenuItem.Text = "Auto-Detect: OFF"
        $script:AutoDetectMenuItem.Checked = $false
    }
})
$contextMenu.Items.Add($script:AutoDetectMenuItem) | Out-Null

$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Exit
$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitMenuItem.Text = "Exit"
$exitMenuItem.Add_Click({
    Write-Log "Exit requested by user"
    $script:Timer.Stop()
    $script:Timer.Dispose()
    Restore-FocusAssist
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    Write-Log "Application exiting"
    $script:AppContext.ExitThread()
})
$contextMenu.Items.Add($exitMenuItem) | Out-Null

$script:NotifyIcon.ContextMenuStrip = $contextMenu

# Double-click on tray icon toggles focus
$script:NotifyIcon.Add_DoubleClick({
    $script:ManualOverride = $true
    if ($script:FocusActive) {
        Set-FocusOff
    } else {
        Set-FocusOn -Reason "Manual"
    }
})

# ---------------------------------------------------------------------------
# Polling timer
# ---------------------------------------------------------------------------
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:PollIntervalMs
$script:Timer.Add_Tick({
    if (-not $script:AutoDetect) { return }

    $meetingNow = Test-MeetingActive

    if ($meetingNow) {
        $script:MeetingEndTime = $null
        if (-not $script:FocusActive) {
            $script:ManualOverride = $false
            Set-FocusOn -Reason $script:DetectedApp
        } else {
            # Update status if app changed
            if ($script:DetectedApp -and $script:NotifyIcon.Text -notmatch [regex]::Escape($script:DetectedApp)) {
                $label = "Focus ON - $($script:DetectedApp)"
                $script:NotifyIcon.Text = "Meeting Focus Mode: $label"
                $script:StatusMenuItem.Text = "[X] $label"
            }
        }
    } else {
        # No meeting detected
        if ($script:FocusActive -and (-not $script:ManualOverride)) {
            if ($null -eq $script:MeetingEndTime) {
                # Start grace period
                $script:MeetingEndTime = (Get-Date)
            } else {
                $elapsed = ((Get-Date) - $script:MeetingEndTime).TotalSeconds
                if ($elapsed -ge $script:GracePeriodSec) {
                    Set-FocusOff
                    $script:MeetingEndTime = $null
                }
            }
        }
    }
})
$script:Timer.Start()

# ---------------------------------------------------------------------------
# Save original state and run
# ---------------------------------------------------------------------------
Write-Log "========================================"
Write-Log "Meeting Focus Mode starting"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "Log file: $($script:LogFile)"
Save-OriginalFocusAssist

# Show startup balloon
$script:NotifyIcon.ShowBalloonTip(3000, "Meeting Focus Mode", "Running in system tray. Auto-detect is ON.", [System.Windows.Forms.ToolTipIcon]::Info)
Write-Log "Tray icon visible, entering message loop"

# Run the message loop
[System.Windows.Forms.Application]::Run($script:AppContext)
