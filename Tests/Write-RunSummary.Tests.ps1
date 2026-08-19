<#
    Tests for the machine-readable run summary.

    The summary exists so a deployment can check the outcome of a run without parsing
    console output, which means its shape is a contract. These tests pin the schema, the
    result classification, and the guarantee that a reporting failure never fails the run.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'Scripts\FileIO\Write-RunSummary.ps1')

    function Reset-RunState {
        $script:Version = '2026.07.11'
        $script:Params = @{}
        $script:RegistryImportFailures = 0
        $script:AppRemovalFailures = 0
        $script:FeatureFailures = 0
        $script:NotInEffectFeatureIds = @()
        $script:CancelRequested = $false
    }
}

Describe 'New-RunSummary' {
    BeforeEach { Reset-RunState }

    It 'declares a schema and version so consumers can detect changes' {
        $summary = New-RunSummary

        $summary.Schema | Should -Be 'win11debloat-run/1.0'
        $summary.Version | Should -Be '2026.07.11'
    }

    It 'reports success when nothing failed' {
        $summary = New-RunSummary -AppliedFeatureIds @('DisableTelemetry')

        $summary.Result | Should -Be 'Success'
        $summary.Applied | Should -Contain 'DisableTelemetry'
        $summary.Failures.RegistryImports | Should -Be 0
    }

    It 'reports failures when a registry import failed' {
        $script:RegistryImportFailures = 2

        $summary = New-RunSummary -AppliedFeatureIds @('DisableTelemetry')

        $summary.Result | Should -Be 'CompletedWithFailures'
        $summary.Failures.RegistryImports | Should -Be 2
    }

    It 'treats a change that did not take effect as a failure' {
        # A setting that was written but is being overridden by policy is a failed
        # outcome from the caller's point of view, even though nothing errored.
        $script:NotInEffectFeatureIds = @('DisableLLMNR')

        $summary = New-RunSummary -AppliedFeatureIds @('DisableLLMNR')

        $summary.Result | Should -Be 'CompletedWithFailures'
        $summary.NotInEffect | Should -Contain 'DisableLLMNR'
        $summary.Failures.NotInEffect | Should -Be 1
    }

    It 'reports cancellation distinctly from failure' {
        $script:CancelRequested = $true

        (New-RunSummary).Result | Should -Be 'Cancelled'
    }

    It 'records the run mode' {
        $script:Params = @{ WhatIf = $true; Sysprep = $true; User = 'Alice' }

        $summary = New-RunSummary

        $summary.Mode.WhatIf | Should -BeTrue
        $summary.Mode.Sysprep | Should -BeTrue
        $summary.Mode.User | Should -Be 'Alice'
        $summary.Mode.Silent | Should -BeFalse
    }

    It 'uses round-trip timestamps' {
        $summary = New-RunSummary -StartedAt ([datetime]'2026-08-19T10:00:00Z')

        { [datetime]::Parse($summary.StartedAt) } | Should -Not -Throw
        { [datetime]::Parse($summary.CompletedAt) } | Should -Not -Throw
    }

    It 'always emits arrays, even when empty' {
        # A consumer indexing into these must not have to special-case null.
        $summary = New-RunSummary

        $summary.Applied -is [array] | Should -BeTrue
        $summary.Undone -is [array] | Should -BeTrue
        $summary.NotInEffect -is [array] | Should -BeTrue
    }
}

Describe 'Write-RunSummary' {
    BeforeEach {
        Reset-RunState
        Mock Write-Host {}
    }

    It 'writes readable JSON' {
        $path = Join-Path $TestDrive 'summary.json'

        Write-RunSummary -Path $path -Summary (New-RunSummary -AppliedFeatureIds @('DisableTelemetry'))

        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $parsed.Schema | Should -Be 'win11debloat-run/1.0'
        $parsed.Applied | Should -Contain 'DisableTelemetry'
    }

    It 'creates the destination directory' {
        $path = Join-Path (Join-Path $TestDrive 'nested\reports') 'summary.json'

        Write-RunSummary -Path $path -Summary (New-RunSummary)

        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'warns instead of throwing when the file cannot be written' {
        # Reporting is not the job; failing the whole run because a log could not be
        # written would be worse than the missing log.
        Mock Set-Content { throw 'access denied' }
        Mock Write-Warning {}

        { Write-RunSummary -Path (Join-Path $TestDrive 'x.json') -Summary (New-RunSummary) } | Should -Not -Throw

        Should -Invoke Write-Warning -Times 1 -Exactly
    }
}
