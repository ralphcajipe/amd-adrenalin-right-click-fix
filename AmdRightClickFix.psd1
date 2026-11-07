@{
    RootModule        = 'AmdRightClickFix.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a94c51e2-83d1-4a7b-9c82-fdadfee302d1'
    Author            = 'Ralph Cajipe'
    CompanyName       = 'Open Source'
    Copyright         = '(c) 2026 Ralph Cajipe. Licensed under MIT OR Apache-2.0.'
    Description       = 'Surgical, zero-dependency diagnostic and fix for the Windows 11 AMD Software: Adrenalin Edition desktop right-click auto-launch and context menu freeze bug (AdvancedMicroDevicesInc-RSXCM / atiacm64.dll / CLSID {FDADFEE3-02D1-4E7C-A511-380F4C98D73B}).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Test-AmdRightClickBug', 'Repair-AmdRightClickBug', 'Restore-AmdRightClickMenu')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('AMD', 'Adrenalin', 'RadeonSoftware', 'Windows11', 'ContextMenu', 'RightClick', 'atiacm64', 'RSXCM', 'HybridGPU')
            LicenseUri = 'https://github.com/ralphcajipe/amd-adrenalin-right-click-fix/blob/main/LICENSE-MIT'
            ProjectUri = 'https://github.com/ralphcajipe/amd-adrenalin-right-click-fix'
        }
    }
}
