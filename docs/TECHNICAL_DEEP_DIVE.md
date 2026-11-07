# Technical Deep Dive: Reverse-Engineering the Windows 11 AMD Adrenalin Desktop Right-Click Bug

This document explains the internal architecture of the **AMD Software: Adrenalin Edition** Windows 11 context menu shell extension (`AdvancedMicroDevicesInc-RSXCM` / `atiacm64.dll` / `LauncherRSXRuntime.exe`), why right-clicking on the desktop or inside File Explorer causes `RadeonSoftware.exe` to unexpectedly launch or freeze with a `"Loading..."` spinner, and how `Fix-AmdRightClick.ps1` resolves the issue without touching AMD graphics drivers or background services.

---

## 1. The MSIX Packaged COM Architecture (`AdvancedMicroDevicesInc-RSXCM`)

Starting in Windows 11 (Build 22000+), Microsoft introduced the modern WinUI 3 context menu (`IExplorerCommand`), which requires shell extensions to be packaged inside an MSIX / Sparse Package identity.

When AMD Software: Adrenalin Edition installs its driver and UI suite under `C:\Program Files\AMD\CNext\CNext\`, it registers a companion MSIX package:
- **Package Full Name:** `AdvancedMicroDevicesInc-RSXCM_22.10.0.0_x64__v2es6h43hjn86`
- **Manifest Location:** `C:\Program Files\AMD\CNext\CNext\RSXPackageResources\AppxManifest.xml` (plus `RSXProPackageResources`, `RSXCreatorPackageResources`, and `RSXVDIPackageResources`)

Inside `AppxManifest.xml`, AMD declares:

```xml
<Applications>
  <Application Id="AMDRadeonSoftwareDesktop"
               Executable="LauncherRSXRuntime.exe"
               uap10:TrustLevel="mediumIL"
               uap10:RuntimeBehavior="win32App">
    <Extensions>
      <desktop4:Extension Category="windows.fileExplorerContextMenus">
        <desktop4:FileExplorerContextMenus>
          <desktop5:ItemType Type="Directory\Background">
            <desktop5:Verb Id="Command1" Clsid="FDADFEE3-02D1-4E7C-A511-380F4C98D73B" />
          </desktop5:ItemType>
        </desktop4:FileExplorerContextMenus>
      </desktop4:Extension>
      <com:Extension Category="windows.comServer">
        <com:ComServer>
          <com:SurrogateServer AppId="FDADFEE3-02D1-4E7C-A511-380F4C98D73B"
                               DisplayName="Catalyst Context Menu extension">
            <com:Class Id="FDADFEE3-02D1-4E7C-A511-380F4C98D73B"
                       Path="atiacm64.dll"
                       ThreadingModel="STA"/>
          </com:SurrogateServer>
        </com:ComServer>
      </com:Extension>
    </Extensions>
  </Application>
</Applications>
```

And in the Windows Registry under `HKEY_LOCAL_MACHINE\SOFTWARE\Classes\PackagedCom\Package\AdvancedMicroDevicesInc-RSXCM_22.10.0.0_x64__v2es6h43hjn86`:
- `Class\{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}` -> `DllPath = atiacm64.dll`, `ServerId = 0`
- `Server\0` -> `ApplicationId = AMDRadeonSoftwareDesktop`, `Executable = radeonsoftware.exe`, `Arguments = -ToastActivated`, `SurrogateAppId = {FDADFEE3-02D1-4E7C-A511-380F4C98D73B}`

---

## 2. What Happens When You Right-Click the Desktop (`Directory\Background`)

Every time a user right-clicks on an empty area of the Windows 11 Desktop or any File Explorer folder background (`Directory\Background`):

1. `explorer.exe` queries all registered `windows.fileExplorerContextMenus` verbs for `Directory\Background` BEFORE rendering the right-click menu.
2. Windows DCOM / PackagedCom activates `{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}` inside `dllhost.exe` (or activates the package application `AMDRadeonSoftwareDesktop` -> `LauncherRSXRuntime.exe` / `radeonsoftware.exe`).
3. Inside `C:\Program Files\AMD\CNext\CNext\atiacm64.dll`, four C++ classes implement `IExplorerCommand`:
   - `RSXContextMenuCommandBase`
   - `RSXContextMenuCommandBase_ATIACE` (CLSID `{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}`)
   - `AIContextMenuCommandBase_ATIACE`
   - `RSXContextMenuCommandBase_ATIACE_UWP`
4. To answer `IExplorerCommand::GetState`, `IExplorerCommand::GetTitle`, and `IExplorerCommand::GetIcon`, `atiacm64.dll` executes heavy synchronous initialization on the context menu thread:
   - Loads `atiadlxx.dll` from the Windows DriverStore (`ADL2_Main_ControlX2_Create`, `ADL2_Adapter_NumberOfAdapters_Get`, `ADL2_Adapter_AdapterInfoX4_Get`, `ADL2_Graphics_VersionsX3_Get`).
   - On **hybrid-GPU laptops** (AMD Ryzen APU with `AMD Radeon(TM) Graphics` iGPU + `NVIDIA GeForce RTX` dGPU), querying ADL wakes or probes the display adapter state.
   - Furthermore, when the packaged application runtime (`LauncherRSXRuntime.exe`) or fallback handler runs, it checks for the `AMDRSDelayInitE` event / `CNEventWindowClass` window and executes:
     `ShellExecuteW(NULL, L"open", L"Radeonsoftware.exe", L"atlogon rebootstartup", ...)` (or activates `!AMDRadeonsoftwareUWP` / `Radeonsoftware.exe`), causing the **AMD Software: Adrenalin Edition** window to pop up right on top of the user's desktop!

---

## 3. Why Standard Forum Workarounds Are Flawed

| Common Forum Advice | Why It Fails or Degrades the System |
| :--- | :--- |
| **"Use DDU and install Driver Only"** | Strips away the entire AMD Software: Adrenalin Edition control panel, removing FreeSync controls, HYPR-RX, Radeon Chill, Anti-Lag, Integer Scaling, and color profiles. |
| **`Remove-AppxPackage AdvancedMicroDevicesInc-RSXCM`** | Fails for non-admin accounts, breaks package integrity checks in `AMDInstallManager`, and gets silently re-registered on every driver update or Windows Update driver push. |
| **"Delete `atiacm64.dll`"** | Modifying files inside `C:\Program Files\AMD\CNext\CNext` violates Authenticode/MSI state and causes repair loops. |

---

## 4. The Multi-Layered Surgical Fix

By inspecting the binary strings and control flow of `C:\Program Files\AMD\CNext\CNext\atiacm64.dll`, we identified two clean, non-destructive operating system and vendor-native switches that stop the bug with zero driver disruption:

### Layer 1: Windows Shell Extension Blocklist (`HKCU` & `HKLM`)
Windows Explorer (`shell32.dll` / `windows.storage.dll`) consults `Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` in both `HKEY_CURRENT_USER` and `HKEY_LOCAL_MACHINE` before instantiating any `IExplorerCommand` or `IContextMenu` CLSID.
- Adding `{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}` to `HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`:
  - **Requires zero Administrator privileges.**
  - Takes effect **immediately** on the very next right-click without restarting `explorer.exe` or rebooting.
  - Prevents `explorer.exe` from even loading `atiacm64.dll` or activating `AdvancedMicroDevicesInc-RSXCM`, eliminating both the Adrenalin auto-launch bug and the 1-3 second `"Loading..."` right-click lag.

### Layer 2: AMD's Internal `HideContextMenu` Registry Switch (`HKLM`)
Inside `atiacm64.dll` (at RVA `0x2115D`, referencing `.rdata` offset `0x1396D8`), AMD's own context menu code queries:
- **Key:** `HKEY_LOCAL_MACHINE\SOFTWARE\AMD\CN`
- **Value:** `HideContextMenu` (`REG_SZ`)
- **Comparison:** `"true"`

Setting `HKLM\SOFTWARE\AMD\CN\HideContextMenu = "true"` instructs `atiacm64.dll` across **all user accounts on the PC** to suppress the context menu entry natively.
