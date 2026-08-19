<#
    Feature reference staleness checks.

    docs/FEATURES.md is generated from Config/Features.json and the .reg corpus by
    Scripts/Build-FeatureDocs.ps1. A generated reference is only useful if it is kept in
    step with the catalogue, so these tests fail when a feature is added, removed or
    renamed without regenerating it.

    They compare content rather than regenerating and diffing, so harmless formatting
    differences do not produce false failures while a genuinely missing or stale entry
    still does.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:DocsPath = Join-Path $script:RepoRoot 'docs\FEATURES.md'
    $script:GeneratorPath = Join-Path $script:RepoRoot 'Scripts\Build-FeatureDocs.ps1'

    $catalogPath = Join-Path $script:RepoRoot 'Config\Features.json'
    $script:Catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $script:Features = @($script:Catalog.Features)

    $script:DocsContent = if (Test-Path -LiteralPath $script:DocsPath) {
        Get-Content -LiteralPath $script:DocsPath -Raw
    }
    else {
        ''
    }

    # Every feature is documented with its switch on its own line, as `-FeatureId`.
    $script:DocumentedSwitches = @(
        [regex]::Matches($script:DocsContent, '(?m)^`-(?<id>\w+)`\s*$') |
            ForEach-Object { $_.Groups['id'].Value }
    )
}

Describe 'Generated feature reference' {
    It 'exists' {
        Test-Path -LiteralPath $script:DocsPath | Should -BeTrue -Because 'run Scripts\Build-FeatureDocs.ps1 to generate it'
    }

    It 'ships the generator that produces it' {
        Test-Path -LiteralPath $script:GeneratorPath | Should -BeTrue
    }

    It 'documents every feature in the catalogue' {
        $undocumented = @(
            $script:Features |
                Where-Object { $script:DocumentedSwitches -notcontains $_.FeatureId } |
                ForEach-Object { $_.FeatureId }
        )

        $undocumented | Should -BeNullOrEmpty -Because "regenerate docs\FEATURES.md; missing: $($undocumented -join ', ')"
    }

    It 'does not document features that no longer exist' {
        $featureIds = @($script:Features | ForEach-Object { $_.FeatureId })
        $stale = @($script:DocumentedSwitches | Where-Object { $featureIds -notcontains $_ })

        $stale | Should -BeNullOrEmpty -Because "regenerate docs\FEATURES.md; stale: $($stale -join ', ')"
    }

    It 'documents each feature exactly once' {
        $duplicates = @(
            $script:DocumentedSwitches | Group-Object | Where-Object { $_.Count -gt 1 } |
                ForEach-Object { $_.Name }
        )

        $duplicates | Should -BeNullOrEmpty -Because "a feature appears more than once: $($duplicates -join ', ')"
    }

    It 'includes a heading for every category that has features' {
        $missing = @(
            $script:Features |
                Where-Object { $_.Category } |
                ForEach-Object { $_.Category } |
                Select-Object -Unique |
                Where-Object { $script:DocsContent -notmatch [regex]::Escape("## $_") }
        )

        $missing | Should -BeNullOrEmpty -Because "regenerate docs\FEATURES.md; missing categories: $($missing -join ', ')"
    }

    It 'states the current number of settings' {
        $script:DocsContent | Should -Match "$($script:Features.Count) settings across" -Because 'the summary line is stale, regenerate the reference'
    }

    It 'names the registry file for every registry-backed feature' {
        $missing = @(
            $script:Features |
                Where-Object { $_.RegistryKey -and $script:DocsContent -notmatch [regex]::Escape($_.RegistryKey) } |
                ForEach-Object { $_.FeatureId }
        )

        $missing | Should -BeNullOrEmpty -Because "the reference must show which .reg file a setting applies: $($missing -join ', ')"
    }
}
