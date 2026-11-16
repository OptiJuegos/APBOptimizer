#===========================================================================
# Tests - AppX Management
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Remove-WinUtilAPPX.ps1")
    . (Join-Path $script:repoRoot "functions\private\Remove-WinUtilProvisionedAPPX.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFButton.ps1")

    $tokens = $null
    $parseErrors = $null
    $provisionedSourcePath = Join-Path $script:repoRoot "functions\private\Remove-WinUtilProvisionedAPPX.ps1"
    $provisionedSourceAst = [System.Management.Automation.Language.Parser]::ParseFile($provisionedSourcePath, [ref]$tokens, [ref]$parseErrors)
    $ps5CommandAssignment = $provisionedSourceAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq "ps5Command"
    }, $true)
    $script:provisionedRemovalScriptBlock = $ps5CommandAssignment.Right.Expression.ScriptBlock.GetScriptBlock()

    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }
    function Start-WinUtilJob {
        param([string]$Name, [scriptblock]$ScriptBlock, [hashtable]$Parameters, [string]$Description, [switch]$DisableAppList)
    }
    function Step-WinUtilJob {
        param([string]$Status, [int]$Percent, [string]$State, [string]$Overlay)
    }
    function Show-WinUtilMessage {
        param($Message, $Title, $Button, $Icon)
    }
    function Invoke-WPFRunspace {
        param($ArgumentList, $ParameterList, [scriptblock]$ScriptBlock)
    }
    function Invoke-WPFUIThread {
        param([scriptblock]$ScriptBlock, [hashtable]$Parameters, [switch]$Async)
    }
    function powershell.exe { }
    function Get-AppxPackage {
        param($Name, [switch]$AllUsers, $ErrorAction)
    }
    function Add-AppxPackage {
        param($Register, [switch]$DisableDevelopmentMode, $ErrorAction)
    }
    function Install-WinUtilWinget { }
    function Install-WinUtilProgramWinget {
        param($Action, $Programs)
    }
    function Remove-AppxPackage {
        param(
            [Parameter(ValueFromPipeline = $true)]
            $InputObject,
            $Package,
            [switch]$AllUsers,
            $ErrorAction
        )
        process { }
    }
    function Remove-WinUtilProvisionedAPPX {
        param($PackageList)
    }
    function Get-AppxProvisionedPackage {
        param([switch]$Online, $ErrorAction)
    }
    function Remove-AppxProvisionedPackage {
        param(
            [Parameter(ValueFromPipeline = $true)]
            $InputObject,
            [switch]$Online,
            $PackageName,
            $ErrorAction
        )
        process { }
    }
    function Get-Package {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification='Test shim is intentionally mocked by Pester.')]
        param($Name, $ErrorAction)
    }
    function Uninstall-Package {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification='Test shim is intentionally mocked by Pester.')]
        param(
            [Parameter(ValueFromPipeline = $true)]
            $InputObject,
            [switch]$Force
        )
        process { }
    }
}







Describe "Remove-WinUtilAPPX" {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WinUtilLog { }
        Mock Get-AppxPackage {
            @(
                [pscustomobject]@{
                    Name = $Name
                    PackageFullName = "$Name.FullName"
                }
                [pscustomobject]@{
                    Name = $Name
                    PackageFullName = "$Name.FullName"
                }
            )
        }
        Mock Remove-AppxPackage { }
    }

    It "removes matching installed AppX packages" {
        Remove-WinUtilAPPX -Name "Microsoft.Xbox*"

        Should -Invoke -CommandName Get-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $Name -eq "*Microsoft.Xbox**" -and $AllUsers -eq $true
        }
        Should -Invoke -CommandName Remove-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $Package -eq "*Microsoft.Xbox**.FullName" -and
                $AllUsers -eq $true -and
                $ErrorAction -eq "Stop"
        }
    }

    It "logs installed AppX removal failures" {
        Mock Remove-AppxPackage { throw "Removal failed" }

        { Remove-WinUtilAPPX -Name "Example.Package" } | Should -Not -Throw

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and
                $Component -eq "AppX" -and
                $Message -eq "Failed to remove AppX package *Example.Package*.FullName: Removal failed"
        }
    }
}

Describe "Remove-WinUtilProvisionedAPPX" {
    BeforeEach {
        Mock Get-AppxProvisionedPackage {
            @(
                [pscustomobject]@{ DisplayName = "Example.One"; PackageName = "Example.One_1.0" }
                [pscustomobject]@{ DisplayName = "Example.Two"; PackageName = "Example.Two_1.0" }
            )
        }
        Mock Remove-AppxProvisionedPackage { }
    }

    It "queries provisioned packages once for all selected package names" {
        & $script:provisionedRemovalScriptBlock "Example.One" "Example.Two"

        Should -Invoke -CommandName Get-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
            $Online -eq $true
        }
        Should -Invoke -CommandName Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
            $PackageName -eq "Example.One_1.0" -and $Online -eq $true
        }
        Should -Invoke -CommandName Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
            $PackageName -eq "Example.Two_1.0" -and $Online -eq $true
        }
    }

    It "surfaces provisioned package removal failures from the child process" {
        Mock Remove-AppxProvisionedPackage { throw "DISM failed" }

        { & $script:provisionedRemovalScriptBlock "Example.One" } |
            Should -Throw "*Failed to remove provisioned AppX package Example.One_1.0: DISM failed*"
        Should -Invoke -CommandName Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
            $PackageName -eq "Example.One_1.0" -and
                $Online -eq $true -and
                $ErrorAction -eq "Stop"
        }
    }

    It "throws after logging child process failures" {
        $source = Get-Content -Path $provisionedSourcePath -Raw

        $source | Should -Match '\$removalOutput = powershell\.exe .* 2>&1'
        $source | Should -Match 'Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message \$errorMessage'
        $source | Should -Match '(?s)AppX provisioned package removal failed:.*WinUtilErrorReported.*throw \$exception.*AppX provisioned package removal completed\.'
    }
}
