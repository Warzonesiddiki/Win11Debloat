<#
    Tests for the catalogue-gap discovery helper.

    The script is read-only, so these tests focus on the matching logic: a package must
    only be reported as unlisted when no catalogue entry covers it, and the matching has
    to behave the same way Remove-AppxApp does, which treats a catalogue identifier as a
    substring of the package name.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Scripts\Find-UnlistedApps.ps1'

    # The script runs top to bottom, so dot-sourcing it would query the live system.
    # Extract just the two functions under test instead.
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionDefinition in $ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($functionDefinition.Extent.Text))
    }
}

Describe 'Find-UnlistedApps' {
    It 'is a valid script with no parse errors' {
        $parseErrors = $null
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$parseErrors)

        $parseErrors | Should -BeNullOrEmpty
    }

    It 'never uninstalls anything' {
        $content = Get-Content -LiteralPath $script:ScriptPath -Raw

        $content | Should -Not -Match 'Remove-AppxPackage'
        $content | Should -Not -Match 'Remove-AppxProvisionedPackage'
        $content | Should -Not -Match 'winget\s+uninstall'
    }
}

Describe 'Get-CatalogAppId' {
    It 'flattens entries that declare several identifiers' {
        $catalogFile = Join-Path $TestDrive 'Apps.json'
        @'
{
  "Version": "1.0",
  "Apps": [
    { "FriendlyName": "One", "AppId": "Contoso.One" },
    { "FriendlyName": "Two", "AppId": ["Contoso.Two", "XP123"] }
  ],
  "Presets": []
}
'@ | Set-Content -LiteralPath $catalogFile -Encoding UTF8

        $ids = @(Get-CatalogAppId -Path $catalogFile)

        $ids | Should -HaveCount 3
        $ids | Should -Contain 'Contoso.Two'
        $ids | Should -Contain 'XP123'
    }

    It 'ignores blank identifiers' {
        $catalogFile = Join-Path $TestDrive 'Blank.json'
        @'
{
  "Version": "1.0",
  "Apps": [
    { "FriendlyName": "One", "AppId": "Contoso.One" },
    { "FriendlyName": "Blank", "AppId": "   " }
  ],
  "Presets": []
}
'@ | Set-Content -LiteralPath $catalogFile -Encoding UTF8

        @(Get-CatalogAppId -Path $catalogFile) | Should -HaveCount 1
    }
}

Describe 'Test-PackageIsListed' {
    BeforeEach {
        $script:Ids = @('Microsoft.BingNews', 'king.com.CandyCrushSaga')
    }

    It 'matches a package whose name equals a catalogue entry' {
        Test-PackageIsListed -PackageName 'Microsoft.BingNews' -CatalogIds $script:Ids | Should -BeTrue
    }

    It 'matches a package whose name merely contains a catalogue entry' {
        # Mirrors Remove-AppxApp, which searches with a *AppId* wildcard.
        Test-PackageIsListed -PackageName 'Microsoft.BingNewsExtra' -CatalogIds $script:Ids | Should -BeTrue
    }

    It 'reports an unrelated package as unlisted' {
        Test-PackageIsListed -PackageName 'AcerIncorporated.AcerCollection' -CatalogIds $script:Ids | Should -BeFalse
    }

    It 'reports everything as unlisted when the catalogue is empty' {
        Test-PackageIsListed -PackageName 'Microsoft.BingNews' -CatalogIds @() | Should -BeFalse
    }
}

Describe 'App catalogue coverage of this repository' {
    It 'covers the known preinstalled McAfee trial' {
        $catalogPath = Join-Path $script:RepoRoot 'Config\Apps.json'
        $ids = @(Get-CatalogAppId -Path $catalogPath)

        $ids | Should -Contain '5A894077.McAfeeSecurity'
    }
}
