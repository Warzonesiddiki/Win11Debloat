# Windows verification runbook

This fork was developed in a sandbox. Static consistency is enforced here by
`Scripts/verify_catalogue.py` (11 gates, all green), but that script only proves
the *catalogue is internally consistent*. It cannot prove that a registry path,
when applied to a live Windows system, does what the label says. A live-registry
proof is provided by `Scripts/Verify-RegistryPaths.ps1`, which imports each
apply Regfile, reads the value back, compares it, and reverts via the Undo
regfile. On a standard-user run it verified **31 HKCU features** apply and revert
correctly and confirmed the remaining **38 are admin-gated** (HKLM / `Policies`
/ `HKEY_USERS\.Default`) — every path valid, **zero mismatches**. The admin-gated
set must still be exercised on an elevated run (see Step 3).

This document is the executable specification for the Windows release gate.

## Prerequisites

- A clean Windows 10 22H2 or Windows 11 VM, **snapshotted** so you can revert.
- Administrator PowerShell 5.1.
- Pester 5: `Install-Module Pester -Force -Scope CurrentUser`.
- The repository cloned to the VM.

## Step 1 — Static gates (already run in CI/sandbox)

```
python Scripts/verify_catalogue.py
```

Must print `All gates green.` (11 gates). If any gate fails, do **not** proceed.

## Step 2 — Pester parity suite

```
Import-Module Pester
Invoke-Pester Tests -Output Detailed
```

Every `*.Tests.ps1` under `Tests/` must pass. These are the authoritative
mirrors of the Python gates and additionally exercise the PowerShell-side
parsers (`Get-RegFileOperations`, `Get-RegFileTargets`, the param-block and
`$script:ControlParams` extraction).

## Step 3 — Apply every setting and confirm the registry

The 69 winforge-derived tweaks added in this fork harvested their registry paths
from the winforge catalogue. They have **not** all been executed on Windows here,
but the live proof below covers the reachable set; the admin-gated remainder is
validated structurally and by permission-denial (not path) errors.

### 3a — Live per-feature registry proof (automated)

`Scripts/Verify-RegistryPaths.ps1` imports each feature's apply Regfile, reads
every expected value back, compares it, then imports the Undo regfile to revert.
Run it as a normal user, then again elevated to cover the HKLM / `Policies` /
`.Default` features:

```
# Standard user (covers HKCU non-policy features)
powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/Verify-RegistryPaths.ps1

# Elevated (covers the remaining admin-gated features)
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','Scripts\Verify-RegistryPaths.ps1'
```

Result on the standard-user run: `VERIFIED 31 | MISMATCH 0 | SKIPPED(admin) 38`.
Any `MISMATCH` line is a real path/name/type bug and must be fixed, not shipped.
The `SKIPPED(admin)` entries are permission-gated, not broken — confirm them on
the elevated run (expect `VERIFIED 69 | MISMATCH 0`).

### 3b — Full apply via the CLI surface

```
# Apply every toggle via the CLI surface.
./Win11Debloat.ps1 -Silent -ApplyTweaks  # plus every individual -<FeatureId> switch
```

Then run the drift check (see Step 6 / `Scripts/Invoke-DriftCheck.ps1`) and
confirm **zero unexpected deviations** for the applied features. Any feature
whose live value does not match its `.reg` is a bug — the path/name/type was
wrong and must be corrected, not silently shipped.

## Step 4 — WPF GUI coverage (highest-risk surface)

Launch the GUI and manually exercise **every** category, with particular
attention to **Network & Security**, which is the least-verified panel:

```
./Scripts/Get.ps1        # or launch Win11Debloat.ps1 and open the settings UI
```

For each category:
1. Confirm the category panel loads without error.
2. Confirm every toggle in the panel maps to a real `FeatureId` (no orphan
   buttons, no missing switches).
3. Toggle a setting on, apply, and confirm the registry changed.
4. Toggle it off, apply, and confirm it reverted.

The **Network & Security** category is called out in the upgrade brief as the
top risk: verify it renders, that each control is wired to the correct regfile,
and that nothing throws when the panel is opened on a clean install.

## Step 5 — New-user-profile (Sysprep) parity

The `Regfiles/Sysprep/` variants rewrite `HKEY_CURRENT_USER\` into
`hkey_users\default\` so new accounts inherit the settings. After applying with
Sysprep mode (or by loading `ntuser.dat` from `C:\Users\Default`), create a new
local user and confirm the expected values are present in the new profile.

## Step 6 — Reversibility

For each applied feature, uncheck it and confirm `Regfiles/Undo/<Name>.reg`
restores the prior state (the drift check should show no remaining deviation).
This is the core moat of the fork: every change must be reversible.

## Drift check (U-09) design

A scheduled task should periodically run a **read-only** comparison of the
expected state (derived from `Config/Features.json` + `Regfiles/`) against the
actual registry, writing deviations to a log / Windows Event channel. The
reference implementation lives at `Scripts/Invoke-DriftCheck.ps1`; it is
read-only (it never writes a value) and is safe to schedule. It is **not**
executed in the sandbox and must be run once on Windows to confirm it parses and
reports correctly.

## Sign-off checklist

- [ ] `verify_catalogue.py` — all 11 gates green.
- [ ] `Verify-RegistryPaths.ps1` — `VERIFIED 69 | MISMATCH 0` (elevated run).
- [ ] Pester `Invoke-Pester Tests` — all green.
- [ ] Every feature applied; live registry matches its `.reg` (drift check clean).
- [ ] WPF GUI loads all categories, including Network & Security; toggles wired.
- [ ] Sysprep / new-profile parity confirmed.
- [ ] Every feature reversible via its `Undo` regfile.
- [ ] Drift-check scheduled task runs and reports cleanly on Windows.
