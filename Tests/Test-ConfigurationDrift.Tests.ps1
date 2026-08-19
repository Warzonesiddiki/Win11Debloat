BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    function Import-JsonFile { param($filePath, $expectedVersion, [switch]$optionalFile) }
    function Test-FeatureApplied { param($FeatureId) }
    function Invoke-FeatureApply { param($FeatureId) }

    . (Join-Path $script:RepoRoot 'Scripts\Features\Get-CurrentTweakState.ps1')
    . (Join-Path $script:RepoRoot 'Scripts\Features\Test-ConfigurationDrift.ps1')
}

Describe 'Test-FeatureSupportsStateDetection' {
    BeforeEach {
        $script:Features = @{
            RegistryBacked = [PSCustomObject]@{ Label = 'Registry backed'; RegistryKey = 'Something.reg' }
            NoState        = [PSCustomObject]@{ Label = 'No state'; RegistryKey = $null }
            DisableWidgets = [PSCustomObject]@{ Label = 'Widgets'; RegistryKey = $null }
        }
    }

    It 'supports a registry-backed feature' {
        Test-FeatureSupportsStateDetection -FeatureId 'RegistryBacked' | Should -BeTrue
    }

    It 'supports a custom-detection feature even without a registry file' {
        Test-FeatureSupportsStateDetection -FeatureId 'DisableWidgets' | Should -BeTrue
    }

    It 'does not support a feature with neither registry data nor custom detection' {
        Test-FeatureSupportsStateDetection -FeatureId 'NoState' | Should -BeFalse
    }

    It 'does not support an unknown feature' {
        Test-FeatureSupportsStateDetection -FeatureId 'Missing' | Should -BeFalse
    }

    It 'lists only features that Test-FeatureApplied actually special-cases' {
        # Guards the duplication between $script:StateDetectionCustomFeatures and the
        # switch inside Test-FeatureApplied: a feature listed as custom-detected but not
        # handled there would silently be treated as "not applied".
        $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Scripts\Features\Get-CurrentTweakState.ps1') -Raw
        $unhandled = @($script:StateDetectionCustomFeatures | Where-Object { $source -notmatch [regex]::Escape("'$_' {") })

        $unhandled | Should -BeNullOrEmpty -Because "each custom-detected feature needs a switch case: $($unhandled -join ', ')"
    }
}

Describe 'Get-IntendedFeatureId' {
    BeforeEach {
        $script:SavedSettingsFilePath = 'TestDrive:\LastUsedSettings.json'
        $script:Features = @{
            DisableTelemetry = [PSCustomObject]@{ Label = 'Disable telemetry'; RegistryKey = 'Disable_Telemetry.reg' }
            DisableBing      = [PSCustomObject]@{ Label = 'Disable Bing'; RegistryKey = 'Disable_Bing.reg' }
        }
    }

    It 'returns nothing when no settings have been saved' {
        Mock Import-JsonFile { $null }

        @(Get-IntendedFeatureId) | Should -HaveCount 0
    }

    It 'returns only the settings that were enabled' {
        Mock Import-JsonFile {
            [PSCustomObject]@{
                Version  = '1.0'
                Settings = @(
                    [PSCustomObject]@{ Name = 'DisableTelemetry'; Value = $true }
                    [PSCustomObject]@{ Name = 'DisableBing'; Value = $false }
                )
            }
        }

        $result = @(Get-IntendedFeatureId)

        $result | Should -HaveCount 1
        $result[0] | Should -Be 'DisableTelemetry'
    }

    It 'skips settings that are no longer in the feature catalogue' {
        Mock Import-JsonFile {
            [PSCustomObject]@{
                Version  = '1.0'
                Settings = @(
                    [PSCustomObject]@{ Name = 'DisableTelemetry'; Value = $true }
                    [PSCustomObject]@{ Name = 'RetiredFeature'; Value = $true }
                )
            }
        }

        @(Get-IntendedFeatureId) | Should -HaveCount 1
    }
}

Describe 'Get-ConfigurationDrift' {
    BeforeEach {
        $script:Features = @{
            StillApplied = [PSCustomObject]@{ Label = 'Still applied'; RegistryKey = 'A.reg' }
            WasReverted  = [PSCustomObject]@{ Label = 'Was reverted'; RegistryKey = 'B.reg' }
            NoState      = [PSCustomObject]@{ Label = 'No detectable state'; RegistryKey = $null }
        }

        Mock Test-FeatureApplied { $true } -ParameterFilter { $FeatureId -eq 'StillApplied' }
        Mock Test-FeatureApplied { $false } -ParameterFilter { $FeatureId -eq 'WasReverted' }
    }

    It 'reports a setting that is still in effect as applied' {
        $result = @(Get-ConfigurationDrift -FeatureIds @('StillApplied'))

        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'Applied'
        $result[0].Label | Should -Be 'Still applied'
    }

    It 'reports a setting Windows has changed back as reverted' {
        $result = @(Get-ConfigurationDrift -FeatureIds @('WasReverted'))

        $result[0].Status | Should -Be 'Reverted'
    }

    It 'does not report an undetectable setting as reverted' {
        # Test-FeatureApplied returns $false for these, so treating its result as drift
        # would wrongly claim that every app-removal setting had been undone.
        $result = @(Get-ConfigurationDrift -FeatureIds @('NoState'))

        $result[0].Status | Should -Be 'NotCheckable'
        Should -Invoke Test-FeatureApplied -Times 0 -Exactly -ParameterFilter { $FeatureId -eq 'NoState' }
    }

    It 'reports a setting that left the catalogue as unknown' {
        $result = @(Get-ConfigurationDrift -FeatureIds @('Retired'))

        $result[0].Status | Should -Be 'Unknown'
    }

    It 'reports a failed state check as unknown rather than reverted' {
        Mock Test-FeatureApplied { throw 'registry unavailable' } -ParameterFilter { $FeatureId -eq 'StillApplied' }

        $result = @(Get-ConfigurationDrift -FeatureIds @('StillApplied'))

        $result[0].Status | Should -Be 'Unknown'
        $result[0].Detail | Should -BeLike '*registry unavailable*'
    }

    It 'checks every requested setting and never writes to the system' {
        $result = @(Get-ConfigurationDrift -FeatureIds @('StillApplied', 'WasReverted', 'NoState'))

        $result | Should -HaveCount 3
        Should -Invoke Invoke-FeatureApply -Times 0 -Exactly
    }

    It 'falls back to the last applied configuration when no features are given' {
        Mock Import-JsonFile {
            [PSCustomObject]@{
                Version  = '1.0'
                Settings = @([PSCustomObject]@{ Name = 'WasReverted'; Value = $true })
            }
        }

        $result = @(Get-ConfigurationDrift)

        $result | Should -HaveCount 1
        $result[0].FeatureId | Should -Be 'WasReverted'
    }
}

Describe 'Repair-ConfigurationDrift' {
    BeforeEach {
        Mock Invoke-FeatureApply {}
        Mock Write-Warning {}
    }

    It 're-applies only the settings that drifted' {
        $results = @(
            [PSCustomObject]@{ FeatureId = 'A'; Label = 'A'; Status = 'Reverted'; Detail = '' }
            [PSCustomObject]@{ FeatureId = 'B'; Label = 'B'; Status = 'Applied'; Detail = '' }
            [PSCustomObject]@{ FeatureId = 'C'; Label = 'C'; Status = 'NotCheckable'; Detail = '' }
        )

        $repaired = Repair-ConfigurationDrift -Results $results

        $repaired | Should -Be 1
        Should -Invoke Invoke-FeatureApply -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 'A' }
        Should -Invoke Invoke-FeatureApply -Times 0 -Exactly -ParameterFilter { $FeatureId -eq 'B' }
    }

    It 'does nothing when there is no drift' {
        $results = @([PSCustomObject]@{ FeatureId = 'A'; Label = 'A'; Status = 'Applied'; Detail = '' })

        Repair-ConfigurationDrift -Results $results | Should -Be 0
        Should -Invoke Invoke-FeatureApply -Times 0 -Exactly
    }

    It 'continues past a feature that fails to re-apply' {
        Mock Invoke-FeatureApply { throw 'access denied' } -ParameterFilter { $FeatureId -eq 'A' }
        $results = @(
            [PSCustomObject]@{ FeatureId = 'A'; Label = 'A'; Status = 'Reverted'; Detail = '' }
            [PSCustomObject]@{ FeatureId = 'B'; Label = 'B'; Status = 'Reverted'; Detail = '' }
        )

        $repaired = Repair-ConfigurationDrift -Results $results

        $repaired | Should -Be 1
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Invoke-FeatureApply -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 'B' }
    }
}

Describe 'Write-ConfigurationDriftReport' {
    BeforeEach {
        Mock Write-Host {}
    }

    It 'explains that there is nothing to compare when no settings were applied' {
        Write-ConfigurationDriftReport -Results @()

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*nothing to compare*' }
    }

    It 'confirms an intact configuration when nothing drifted' {
        Write-ConfigurationDriftReport -Results @(
            [PSCustomObject]@{ FeatureId = 'A'; Label = 'A'; Status = 'Applied'; Detail = '' }
        )

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*configuration is intact*' }
    }

    It 'lists each reverted setting by its label' {
        Write-ConfigurationDriftReport -Results @(
            [PSCustomObject]@{ FeatureId = 'A'; Label = 'Disable telemetry'; Status = 'Reverted'; Detail = '' }
        )

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Disable telemetry*' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Re-apply the reverted settings*' }
    }
}
