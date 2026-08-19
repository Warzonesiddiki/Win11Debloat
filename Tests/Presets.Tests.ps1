<#
    Tests for the bundled preset configurations.

    Presets are ordinary -Config files, so they go stale silently: rename or remove a
    feature and a preset keeps referencing an id that no longer exists, which
    Import-ConfigToParams skips without complaint. The user then gets a quieter run than
    they asked for and no indication why.

    These tests make that failure loud.
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:PresetFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Config\Presets') -Filter '*.json' -ErrorAction SilentlyContinue |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $catalog = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Config\Features.json') -Raw | ConvertFrom-Json
    $script:FeatureIds = @($catalog.Features | ForEach-Object { $_.FeatureId })
}

Describe 'Bundled presets' {
    It 'ships at least one preset' {
        # Re-query on disk: $script:PresetFiles is populated in BeforeDiscovery and is
        # not guaranteed visible in the run phase under Pester 5's scoping.
        $files = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Config\Presets') -Filter '*.json' -ErrorAction SilentlyContinue
        $files.Count | Should -BeGreaterThan 0
    }

    Context '<Name>' -ForEach $script:PresetFiles {
        BeforeAll {
            $script:Preset = Get-Content -LiteralPath $FullName -Raw | ConvertFrom-Json
            $script:PresetTweakIds = @($script:Preset.Tweaks | ForEach-Object { $_.Name })
        }

        It 'declares the config schema version the importer expects' {
            $script:Preset.Version | Should -Be '1.0'
        }

        It 'explains what it is for' {
            $script:Preset.Description | Should -Not -BeNullOrEmpty
        }

        It 'selects at least one setting' {
            $script:PresetTweakIds.Count | Should -BeGreaterThan 0
        }

        It 'references only settings that exist' {
            $unknown = @($script:PresetTweakIds | Where-Object { $script:FeatureIds -notcontains $_ })

            $unknown | Should -BeNullOrEmpty -Because "Import-ConfigToParams silently skips unknown ids: $($unknown -join ', ')"
        }

        It 'does not list the same setting twice' {
            $duplicates = @($script:PresetTweakIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

            $duplicates | Should -BeNullOrEmpty -Because "duplicated: $($duplicates -join ', ')"
        }

        It 'enables every setting it lists' {
            # A tweak with Value false is ignored by the importer, so it would be a
            # confusing no-op sitting in a curated preset.
            $notEnabled = @($script:Preset.Tweaks | Where-Object { $_.Value -ne $true } | ForEach-Object { $_.Name })

            $notEnabled | Should -BeNullOrEmpty -Because "these would be silently skipped: $($notEnabled -join ', ')"
        }

        It 'asks for a restore point' {
            # Every preset applies a batch of changes at once, so the safety net matters
            # more than it does for a single hand-picked setting.
            $deployment = @{}
            foreach ($setting in @($script:Preset.Deployment)) { $deployment[$setting.Name] = $setting.Value }

            $deployment['CreateRestorePoint'] | Should -BeTrue
        }
    }
}
