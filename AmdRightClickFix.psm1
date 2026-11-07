# PowerShell Module Wrapper for Fix-AmdRightClick
$scriptPath = Join-Path $PSScriptRoot "Fix-AmdRightClick.ps1"

function Test-AmdRightClickBug {
    [CmdletBinding()]
    param([switch]$Json)
    & $scriptPath -Mode Status -Json:$Json
}

function Repair-AmdRightClickBug {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet("Auto", "CurrentUser", "AllUsers")]
        [string]$Scope = "Auto",
        [switch]$Force,
        [switch]$Json
    )
    & $scriptPath -Mode Fix -Scope $Scope -Force:$Force -Json:$Json
}

function Restore-AmdRightClickMenu {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet("Auto", "CurrentUser", "AllUsers")]
        [string]$Scope = "Auto",
        [switch]$Json
    )
    & $scriptPath -Mode Revert -Scope $Scope -Json:$Json
}

Export-ModuleMember -Function Test-AmdRightClickBug, Repair-AmdRightClickBug, Restore-AmdRightClickMenu
