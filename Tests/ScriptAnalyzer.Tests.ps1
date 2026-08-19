<#
    Static analysis gate.

    PSScriptAnalyzer catches a class of defect the rest of this suite cannot: unreachable
    code, unassigned variables, malformed parameter blocks and cmdlet misuse that only
    surfaces at runtime. GitHub's windows-latest runners ship the module, so this gate is
    active in CI.

    The severity is deliberately limited to Error. Warning-level rules encode style
    preferences (aliases, plural nouns, Write-Host usage) that this codebase makes
    different, deliberate choices about, and turning those into build failures would
    produce noise that gets the whole gate disabled. Error-level findings are genuine
    defects.

    When the module is not installed the tests are skipped rather than failed, so a
    contributor without it still gets a clean local run.
#>

BeforeDiscovery {
    $script:AnalyzerAvailable = $null -ne (Get-Module -ListAvailable -Name PSScriptAnalyzer)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -Force

        $script:AnalyzerResults = @(
            Invoke-ScriptAnalyzer -Path $script:RepoRoot -Recurse -Severity Error -ErrorAction SilentlyContinue
        )
    }
    else {
        $script:AnalyzerResults = @()
    }
}

Describe 'PSScriptAnalyzer' -Skip:(-not $script:AnalyzerAvailable) {
    It 'reports no errors anywhere in the repository' {
        $findings = @(
            $script:AnalyzerResults | ForEach-Object {
                "$($_.ScriptName):$($_.Line) $($_.RuleName) - $($_.Message)"
            }
        )

        $findings | Should -BeNullOrEmpty -Because "static analysis found error-level problems:`n$($findings -join "`n")"
    }
}

Describe 'PSScriptAnalyzer availability' {
    It 'notes when static analysis was skipped' -Skip:$script:AnalyzerAvailable {
        # Not a failure: this exists so a skipped gate is visible in the test output
        # rather than silently absent.
        Set-ItResult -Skipped -Because 'PSScriptAnalyzer is not installed. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }
}
