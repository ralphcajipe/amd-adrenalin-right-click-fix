<#
.SYNOPSIS
    Diagnoses, fixes, and reverts the Windows 11 AMD Software: Adrenalin Edition
    desktop right-click auto-launch and "Loading..." context menu freeze bug.

.DESCRIPTION
    Fix-AmdRightClick.ps1 is a zero-dependency, non-destructive PowerShell tool that
    surgically resolves the Windows 11 desktop/folder right-click bug caused by the
    AMD Radeon Software MSIX context menu handler (AdvancedMicroDevicesInc-RSXCM /
    CLSID {FDADFEE3-02D1-4E7C-A511-380F4C98D73B} / atiacm64.dll).

    SAFETY INVARIANT (Hardware & Software Eligibility Gate):
    This script inspects your OS, GPU adapters, AMD Adrenalin installation, and
    PackagedCom shell extension registrations first. It will NEVER modify the
    registry on non-affected machines unless -Force is explicitly specified.

.PARAMETER Mode
    The operation to perform:
    - Status : (Default) Run a read-only 5-point eligibility & health audit.
    - Fix    : Apply the surgical registry fix (only if the machine is affected).
    - Revert : Restore the default AMD Adrenalin desktop context menu behavior.

.PARAMETER Scope
    Target registry scope when Mode is Fix or Revert:
    - Auto        : (Default) Applies CurrentUser (HKCU) always, and AllUsers (HKLM)
                    automatically if running in an elevated Administrator session.
    - CurrentUser : Applies per-user fix under HKCU (does not require Admin).
    - AllUsers    : Applies PC-wide fix under HKCU and HKLM (requires Admin).

.PARAMETER Json
    Output machine-readable JSON diagnostics instead of formatted console text.

.PARAMETER Force
    Bypass the hardware/software eligibility gate (for testing on non-AMD systems).

.EXAMPLE
    .\Fix-AmdRightClick.ps1
    Runs a read-only diagnostic check to see if this PC is affected and whether the fix is active.

.EXAMPLE
    .\Fix-AmdRightClick.ps1 -Mode Fix
    Applies the surgical fix if the machine is affected (HKCU + HKLM if elevated).

.EXAMPLE
    .\Fix-AmdRightClick.ps1 -Mode Revert
    Re-enables the AMD Software: Adrenalin Edition right-click context menu entry.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Status", "Fix", "Revert")]
    [string]$Mode = "Status",

    [Parameter()]
    [ValidateSet("Auto", "CurrentUser", "AllUsers")]
    [string]$Scope = "Auto",

    [Parameter()]
    [switch]$Json,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure System32 is in PATH for Windows environments where it may be omitted
$sys32 = "C:\Windows\System32"
if (($env:PATH -split ";") -notcontains $sys32) {
    $env:PATH = "$sys32;$env:PATH"
}

$TargetClsid = "{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}"
$TargetClsidRaw = "FDADFEE3-02D1-4E7C-A511-380F4C98D73B"
$BlockDescription = "AMD Radeon Software Context Menu"
$HkcuBlockedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
$HklmBlockedPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
$HklmAmdCnPath   = "HKLM:\SOFTWARE\AMD\CN"
$DisplayClassKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return $false
        }
        # Verify actual write access to HKLM:\SOFTWARE\AMD\CN or Shell Extensions\Blocked
        $testKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            "SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked",
            $true
        )
        if ($null -ne $testKey) {
            $testKey.Close()
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Get-SystemAudit {
    $osBuild = [System.Environment]::OSVersion.Version.Build
    $isWin11OrNewer = ($osBuild -ge 22000)

    # 1. Inspect Display Adapters from Registry Class {4d36e968-e325-11ce-bfc1-08002be10318}
    $gpus = [System.Collections.Generic.List[string]]::new()
    $hasAmdGpu = $false
    $hasNvidiaOrIntelDgpu = $false
    $amdContextGuidFlag = $null

    if (Test-Path -LiteralPath $DisplayClassKey) {
        $subKeys = Get-ChildItem -LiteralPath $DisplayClassKey -ErrorAction SilentlyContinue
        foreach ($sk in $subKeys) {
            if ($sk.PSChildName -match "^\d{4}$") {
                $props = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                if ($null -ne $props -and $props.PSObject.Properties.Name -contains "DriverDesc") {
                    $desc = [string]$props.DriverDesc
                    if (-not [string]::IsNullOrWhiteSpace($desc)) {
                        $gpus.Add($desc)
                        if ($desc -match "AMD|Radeon") {
                            $hasAmdGpu = $true
                            if ($props.PSObject.Properties.Name -contains "575236dd-2453-4518-87eb-7052389c57e1") {
                                $amdContextGuidFlag = [int]$props."575236dd-2453-4518-87eb-7052389c57e1"
                            }
                        }
                        if ($desc -match "NVIDIA|GeForce|RTX|GTX|Arc") {
                            $hasNvidiaOrIntelDgpu = $true
                        }
                    }
                }
            }
        }
    }

    # 2. Inspect AMD CN Registry Installation
    $amdInstallDir = $null
    $cnVersion = $null
    $driverVersion = $null
    $hklmHideContextMenu = $null

    if (Test-Path -LiteralPath $HklmAmdCnPath) {
        $cnProps = Get-ItemProperty -LiteralPath $HklmAmdCnPath -ErrorAction SilentlyContinue
        if ($null -ne $cnProps) {
            if ($cnProps.PSObject.Properties.Name -contains "InstallDir") {
                $amdInstallDir = [string]$cnProps.InstallDir
            }
            if ($cnProps.PSObject.Properties.Name -contains "CNVersion") {
                $cnVersion = [string]$cnProps.CNVersion
            }
            if ($cnProps.PSObject.Properties.Name -contains "DriverVersion") {
                $driverVersion = [string]$cnProps.DriverVersion
            }
            if ($cnProps.PSObject.Properties.Name -contains "HideContextMenu") {
                $hklmHideContextMenu = [string]$cnProps.HideContextMenu
            }
        }
    }

    # 3. Inspect AMD Context Menu Binaries & AppxManifest
    $defaultCNext = if ($amdInstallDir) { $amdInstallDir.TrimEnd('\') } else { "C:\Program Files\AMD\CNext\CNext" }
    $atiacmDllPath = Join-Path $defaultCNext "atiacm64.dll"
    $launcherExePath = Join-Path $defaultCNext "LauncherRSXRuntime.exe"
    $radeonExePath = Join-Path $defaultCNext "RadeonSoftware.exe"
    $manifestPath = Join-Path $defaultCNext "RSXPackageResources\AppxManifest.xml"

    $hasAtiacmDll = Test-Path -LiteralPath $atiacmDllPath
    $hasLauncherExe = Test-Path -LiteralPath $launcherExePath
    $hasRadeonExe = Test-Path -LiteralPath $radeonExePath
    $hasManifestClsid = $false

    if (Test-Path -LiteralPath $manifestPath) {
        $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction SilentlyContinue
        if ($manifestRaw -match $TargetClsidRaw) {
            $hasManifestClsid = $true
        }
    }

    # 4. Inspect PackagedCom registration for AdvancedMicroDevicesInc-RSXCM
    $packagedComPkg = $null
    $packagedComRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package"
    if (Test-Path -LiteralPath $packagedComRoot) {
        $pkgKeys = Get-ChildItem -LiteralPath $packagedComRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "AdvancedMicroDevicesInc-RSXCM*" }
        foreach ($pk in $pkgKeys) {
            $clsidPath = Join-Path $pk.PSPath "Class\$TargetClsid"
            if (Test-Path -LiteralPath $clsidPath) {
                $packagedComPkg = $pk.PSChildName
                break
            }
        }
    }

    # 5. Check Current Remediation State
    $hkcuBlocked = $false
    if (Test-Path -LiteralPath $HkcuBlockedPath) {
        $p = Get-ItemProperty -LiteralPath $HkcuBlockedPath -ErrorAction SilentlyContinue
        if ($null -ne $p -and ($p.PSObject.Properties.Name -contains $TargetClsid)) {
            $hkcuBlocked = $true
        }
    }

    $hklmBlocked = $false
    if (Test-Path -LiteralPath $HklmBlockedPath) {
        $p = Get-ItemProperty -LiteralPath $HklmBlockedPath -ErrorAction SilentlyContinue
        if ($null -ne $p -and ($p.PSObject.Properties.Name -contains $TargetClsid)) {
            $hklmBlocked = $true
        }
    }

    $isHideContextMenuTrue = ($hklmHideContextMenu -eq "true" -or $hklmHideContextMenu -eq "True")

    # Eligibility Gate: Is this machine genuinely affected by the AMD RSXCM right-click bug?
    $isAffectedHardwareAndSoftware = (
        $hasAmdGpu -and
        ($hasAtiacmDll -or ($null -ne $packagedComPkg) -or $hasManifestClsid)
    )

    $isRemediatedCurrentUser = ($hkcuBlocked -or $isHideContextMenuTrue -or $hklmBlocked)
    $isRemediatedMachineWide = ($isHideContextMenuTrue -or $hklmBlocked)

    return [PSCustomObject]@{
        ComputerName                  = $env:COMPUTERNAME
        OSBuild                       = $osBuild
        IsWindows11OrNewer            = $isWin11OrNewer
        IsElevated                    = (Test-IsElevated)
        DetectedGPUs                  = $gpus.ToArray()
        IsHybridGpuSystem             = ($hasAmdGpu -and $hasNvidiaOrIntelDgpu)
        HasAmdGpu                     = $hasAmdGpu
        AmdCNVersion                  = $cnVersion
        AmdDriverVersion              = $driverVersion
        AmdInstallDir                 = $defaultCNext
        PackagedComPackage            = $packagedComPkg
        TargetClsid                   = $TargetClsid
        HasAtiacm64Dll                = $hasAtiacmDll
        HasLauncherRSXRuntime         = $hasLauncherExe
        HasRadeonSoftwareExe          = $hasRadeonExe
        HasManifestClsid              = $hasManifestClsid
        AmdDisplayClassGuid5752       = $amdContextGuidFlag
        IsAffectedSystem              = $isAffectedHardwareAndSoftware
        HKCU_ShellExtensionBlocked    = $hkcuBlocked
        HKLM_ShellExtensionBlocked    = $hklmBlocked
        HKLM_HideContextMenu          = $isHideContextMenuTrue
        IsRemediatedCurrentUser       = $isRemediatedCurrentUser
        IsRemediatedMachineWide       = $isRemediatedMachineWide
    }
}

function Write-AuditReport {
    param([Parameter(Mandatory)][PSCustomObject]$Audit)

    Write-Host ""
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " AMD Adrenalin Desktop Right-Click Bug Auditor & Surgical Fix" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host (" Host Machine       : {0} (Windows Build {1})" -f $Audit.ComputerName, $Audit.OSBuild)
    Write-Host (" Detected GPUs      : {0}" -f ($Audit.DetectedGPUs -join " + "))
    Write-Host (" Hybrid GPU Topology: {0}" -f $(if ($Audit.IsHybridGpuSystem) { "Yes (AMD iGPU + Discrete GPU)" } else { "No (Single GPU Vendor)" }))
    Write-Host (" AMD Driver / CN    : Driver {0} | CN {1}" -f $(if ($Audit.AmdDriverVersion) { $Audit.AmdDriverVersion } else { "N/A" }), $(if ($Audit.AmdCNVersion) { $Audit.AmdCNVersion } else { "N/A" }))
    Write-Host (" MSIX Package       : {0}" -f $(if ($Audit.PackagedComPackage) { $Audit.PackagedComPackage } else { "Not Registered" }))
    Write-Host (" Shell Handler DLL  : {0} ({1})" -f (Join-Path $Audit.AmdInstallDir "atiacm64.dll"), $Audit.TargetClsid)
    Write-Host "---------------------------------------------------------------------" -ForegroundColor DarkGray

    if ($Audit.IsAffectedSystem) {
        Write-Host " [ELIGIBILITY GATE] : MATCHED - This PC has the affected AMD RSXCM" -ForegroundColor Yellow
        Write-Host "                      packaged context menu architecture." -ForegroundColor Yellow
    } else {
        Write-Host " [ELIGIBILITY GATE] : NOT AFFECTED - This PC does not have the AMD" -ForegroundColor Green
        Write-Host "                      RSXCM context menu extension installed." -ForegroundColor Green
    }

    Write-Host "---------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host (" Layer 1 (HKCU Shell Blocked) : {0}" -f $(if ($Audit.HKCU_ShellExtensionBlocked) { "ACTIVE (Protected)" } else { "Not Set" })) -ForegroundColor $(if ($Audit.HKCU_ShellExtensionBlocked) { "Green" } else { "Yellow" })
    Write-Host (" Layer 2 (HKLM HideContextMenu): {0}" -f $(if ($Audit.HKLM_HideContextMenu) { "ACTIVE (Protected PC-Wide)" } else { "Not Set" })) -ForegroundColor $(if ($Audit.HKLM_HideContextMenu) { "Green" } else { "Yellow" })
    Write-Host (" Layer 3 (HKLM Shell Blocked) : {0}" -f $(if ($Audit.HKLM_ShellExtensionBlocked) { "ACTIVE (Protected PC-Wide)" } else { "Optional / Not Set" })) -ForegroundColor $(if ($Audit.HKLM_ShellExtensionBlocked) { "Green" } else { "DarkGray" })
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host ""
}

$audit = Get-SystemAudit

if ($Mode -eq "Status") {
    if ($Json) {
        $audit | ConvertTo-Json -Depth 4
    } else {
        Write-AuditReport -Audit $audit
    }
    exit 0
}

if ($Mode -eq "Fix") {
    if (-not $audit.IsAffectedSystem -and -not $Force) {
        if ($Json) {
            [PSCustomObject]@{
                Action  = "Fix"
                Applied = $false
                Reason  = "Eligibility gate blocked execution: machine does not have the affected AMD RSXCM hardware/software stack. Use -Force to override."
                Audit   = $audit
            } | ConvertTo-Json -Depth 4
        } else {
            Write-AuditReport -Audit $audit
            Write-Warning "Aborted: This machine does not match the affected AMD Adrenalin RSXCM hardware/software profile. No changes were made."
        }
        exit 0
    }

    $wantHkcu = ($Scope -in @("Auto", "CurrentUser", "AllUsers"))
    $wantHklm = ($Scope -eq "AllUsers") -or ($Scope -eq "Auto" -and $audit.IsElevated)

    if ($Scope -eq "AllUsers" -and -not $audit.IsElevated) {
        throw "Scope 'AllUsers' requires an elevated Administrator PowerShell session to write to HKEY_LOCAL_MACHINE."
    }

    if ($wantHkcu) {
        if ($PSCmdlet.ShouldProcess($HkcuBlockedPath, "Block CLSID $TargetClsid for CurrentUser")) {
            & "$sys32\reg.exe" add "HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" /v $TargetClsid /t REG_SZ /d $BlockDescription /f | Out-Null
        }
    }

    if ($wantHklm) {
        if ($PSCmdlet.ShouldProcess($HklmAmdCnPath, "Set HideContextMenu=true for AllUsers")) {
            & "$sys32\reg.exe" add "HKLM\SOFTWARE\AMD\CN" /v "HideContextMenu" /t REG_SZ /d "true" /f | Out-Null
        }
        # Attempt optional Layer 3 HKLM Shell Extensions\Blocked if ACL permits
        try {
            if ($PSCmdlet.ShouldProcess($HklmBlockedPath, "Block CLSID $TargetClsid in HKLM")) {
                & "$sys32\reg.exe" add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" /v $TargetClsid /t REG_SZ /d $BlockDescription /f 2>$null | Out-Null
            }
        } catch {
            # Ignore if HKLM\...\Shell Extensions\Blocked is owned by SYSTEM/TrustedInstaller
        }
    }

    $postAudit = Get-SystemAudit
    if ($Json) {
        [PSCustomObject]@{
            Action  = "Fix"
            Applied = $true
            Audit   = $postAudit
        } | ConvertTo-Json -Depth 4
    } else {
        Write-AuditReport -Audit $postAudit
        Write-Host "[SUCCESS] Surgical fix applied. AMD Adrenalin drivers and background services remain 100% intact." -ForegroundColor Green
        if (-not $postAudit.IsRemediatedMachineWide -and $Scope -eq "Auto") {
            Write-Host "[TIP] Run this command in an Administrator PowerShell prompt to also lock in the PC-wide (HKLM) layer:" -ForegroundColor Yellow
            Write-Host '      C:\Windows\System32\reg.exe add "HKLM\SOFTWARE\AMD\CN" /v "HideContextMenu" /t REG_SZ /d "true" /f' -ForegroundColor White
        }
    }
    exit 0
}

if ($Mode -eq "Revert") {
    $wantHkcu = ($Scope -in @("Auto", "CurrentUser", "AllUsers"))
    $wantHklm = ($Scope -eq "AllUsers") -or ($Scope -eq "Auto" -and $audit.IsElevated)

    if ($wantHkcu -and $audit.HKCU_ShellExtensionBlocked) {
        if ($PSCmdlet.ShouldProcess($HkcuBlockedPath, "Remove CLSID $TargetClsid block from CurrentUser")) {
            & "$sys32\reg.exe" delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" /v $TargetClsid /f 2>$null | Out-Null
        }
    }

    if ($wantHklm) {
        if ($audit.HKLM_HideContextMenu) {
            if ($PSCmdlet.ShouldProcess($HklmAmdCnPath, "Remove HideContextMenu from HKLM\SOFTWARE\AMD\CN")) {
                & "$sys32\reg.exe" delete "HKLM\SOFTWARE\AMD\CN" /v "HideContextMenu" /f 2>$null | Out-Null
            }
        }
        if ($audit.HKLM_ShellExtensionBlocked) {
            if ($PSCmdlet.ShouldProcess($HklmBlockedPath, "Remove CLSID $TargetClsid block from HKLM")) {
                & "$sys32\reg.exe" delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" /v $TargetClsid /f 2>$null | Out-Null
            }
        }
    }

    $postAudit = Get-SystemAudit
    if ($Json) {
        [PSCustomObject]@{
            Action   = "Revert"
            Reverted = $true
            Audit    = $postAudit
        } | ConvertTo-Json -Depth 4
    } else {
        Write-AuditReport -Audit $postAudit
        Write-Host "[REVERTED] Restored default AMD Adrenalin desktop context menu settings." -ForegroundColor Green
    }
    exit 0
}
