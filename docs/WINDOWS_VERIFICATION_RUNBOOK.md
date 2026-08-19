# Windows verification runbook

This fork was developed in a sandbox **without a PowerShell runtime, without
GitHub Actions, and without egress to a Windows machine**. Static consistency is
enforced here by `Scripts/verify_catalogue.py` (11 gates, all green), but that
script only proves the *catalogue is internally consistent*. It cannot prove
that a registry path, when applied to a live Windows system, does what the label
says. That final proof must happen on Windows before a release is tagged.

This document is the executable specification for that step. Treat it as a
release gate, not a nice-to-have.

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
from the winforge catalogue; they have **not** been executed on Windows here.
For each feature in `Config/Features.json`, apply it and confirm the live
registry matches the expected value in its `Regfiles/<Name>.reg`.

Recommended approach:

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
- [ ] Pester `Invoke-Pester Tests` — all green.
- [ ] Every feature applied; live registry matches its `.reg` (drift check clean).
- [ ] WPF GUI loads all categories, including Network & Security; toggles wired.
- [ ] Sysprep / new-profile parity confirmed.
- [ ] Every feature reversible via its `Undo` regfile.
- [ ] Drift-check scheduled task runs and reports cleanly on Windows.
