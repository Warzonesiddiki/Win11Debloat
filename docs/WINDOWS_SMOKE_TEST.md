# Windows smoke test

Everything in this repository is verified structurally on every change: the Pester suite,
the apply/undo/Sysprep parity gates, the CLI parity gates, and the generated feature
reference. None of that proves a setting behaves correctly against a live Windows
install, and some of the work was authored in an environment with no Windows runtime.

This is the pass that closes the gap. It takes about ten minutes.

## 1. Automated

```powershell
# From the repository root, in Windows PowerShell 5.1, elevated:
.\Scripts\Invoke-SmokeTest.ps1
```

It checks the environment, runs the full Pester suite, then sweeps **every switch
feature** through the real pipeline with `-WhatIf` and reports any that fail to
dispatch, error, or hang. `-WhatIf` short-circuits every mutation, including the
Explorer restart, so nothing on the machine is changed.

Finally it runs `-CheckDrift`, which is read-only by design.

Exit code `0` means everything passed. Anything else prints a numbered list of problems.

To re-check a few features quickly:

```powershell
.\Scripts\Invoke-SmokeTest.ps1 -FeatureId DisableLLMNR, DisableCEIP -SkipPester
```

## 2. Interface checks a script cannot do

Launch the GUI (`.\Win11Debloat.ps1`) and confirm:

- [ ] The **Network & Security** category appears in the settings list with a globe icon
      and contains five settings. This category was added recently; if the icon renders
      as an empty box the glyph needs changing, and if the whole card is missing the
      category was not picked up from `Config/Features.json`.
- [ ] The **Privacy & Suggested Content** category lists the newer entries, including
      *Prevent Windows from reinstalling removed & promoted apps*, *Disable Windows Error
      Reporting* and *Disable syncing of Windows settings to your Microsoft account*.
- [ ] Hovering a new setting shows its tooltip, and the text is not truncated.
- [ ] Selecting one new setting and pressing apply produces a plausible summary in the
      confirmation dialog.

## 3. One real apply/undo round trip

Do this on a VM or a machine you can restore. Pick a setting whose effect is easy to see
by eye, for example *Disable LLMNR name resolution*.

```powershell
# Confirm the value is absent or 0 beforehand
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue

.\Win11Debloat.ps1 -Silent -DisableLLMNR
# EnableMulticast should now be 0

.\Win11Debloat.ps1 -Silent -CheckDrift
# should report the setting as still applied
```

Then revert it through the GUI by unchecking the setting, and confirm the value returns
to its previous state. This exercises the part no static gate can reach: that the undo
file genuinely reverses the apply file on a real hive.

## 4. What to report back

For anything that fails, the useful details are:

- the feature id,
- the exact error text,
- the Windows build (`winver`),
- whether it was elevated,
- and the relevant lines from `Logs\Win11Debloat.log`.

## Coverage note

The automated sweep proves that every feature loads, resolves its registry file and
dispatches without error. It does **not** prove that a given registry value achieves its
described effect on Windows; that is what step 3 samples, and what the wider user base
ultimately validates.
