# Win11Debloat — Upgrade Analysis & Roadmap

**Date:** 2026-08-19
**Scope:** Strategic analysis of `Warzonesiddiki/Win11Debloat` (fork of `Raphire/Win11Debloat`),
incorporating assets from `Warzonesiddiki/winforge`, plus research into the 2026 Windows landscape.

> **How to read this doc.** Section 1–4 is analysis (what is true today). Section 5 is the
> upgrade catalogue (everything we *could* do). Section 6 is the recommended sequencing.
> Section 7 is what we should deliberately *not* do. Section 8 lists the decisions that need
> a human call before execution.
>
> Numbers labelled **[measured]** were computed by parsing the repositories in this workspace.
> Numbers labelled **[reported]** come from third-party sources and are cited but unverified.

---

## 1. Where the project actually stands

### 1.1 Win11Debloat (this repo) — [measured]

| Dimension | Value |
|---|---|
| PowerShell files | 115 (`.ps1`), ~12,450 lines in `Scripts/` |
| Features catalogue | **101** features in `Config/Features.json` |
| — registry-backed | 87 (via 242 `.reg` files in `Regfiles/`) |
| — with a defined undo | 76 |
| — custom logic (no reg) | 14 |
| App catalogue | **141** apps, 142 distinct AppIds, 2 presets |
| — removal method | 138 Appx / 3 WinGet |
| — safety rating | 86 safe / 48 optional / 7 unsafe |
| Feature categories | 13 (File Explorer 20, Taskbar 19, Start/Search 10, Privacy 9, System 8, AI 7, …) |
| Tests | 38 Pester suites, **365** `It` blocks |
| CI | 1 workflow — Pester on `windows-latest`, Windows PowerShell 5.1 |
| CLI surface | ~110 parameters |

**Architectural strengths worth protecting:**

- **Undo is a first-class citizen.** 76/87 registry features ship an inverse `.reg`. Most
  competitors (WinUtil included) have no per-tweak undo — only a restore point.
- **State detection already exists.** `Get-CurrentTweakState.ps1` / `Test-FeatureApplied`
  compares the live registry against the apply `.reg` file, operation by operation. This is
  the foundation for drift detection (see U-01) and it is already built.
- **Registry backup/restore subsystem** with schema validation, allow-listing and normalisation.
- **Multi-target execution**: current user, another user (hive mounting), Sysprep/Default
  profile, SYSTEM account, audit mode.
- **`-WhatIf` support** across the feature pipeline.
- **Version gating** via `MinVersion`/`MaxVersion` per feature.
- **Data-driven catalogue** — features and apps are JSON, not hardcoded.

**Known structural weaknesses:**

1. `.reg` files as the operation format cap what a feature can express. Services, scheduled
   tasks, power settings, ACLs and commands each need bespoke PowerShell (`Set-StoreSearch-
   Suggestions`, `Telemetry-ScheduledTasks`, `Windows-OptionalFeatures` are all special cases
   hand-wired into `Invoke-Changes.ps1`'s `switch` statements).
2. **No per-feature error isolation** in `Invoke-FeatureApply` / `Invoke-FeatureUndo` — one
   throwing feature aborts the remaining batch. (The same class of bug was just fixed one
   level down, in the store-suggestions all-user loops.)
3. Dot-sourced script files rather than a PowerShell module — no explicit public API surface,
   no `Export-ModuleMember`, harder to unit-test in isolation.
4. **English only.**
5. Refuses to run under PowerShell 7 by design (`$PSVersionTable.PSEdition -eq 'Core'` → exit).
6. Changes are **fire-and-forget**: nothing re-checks the machine after Windows updates.

### 1.2 WinForge (the other project) — [measured]

| Dimension | Value |
|---|---|
| Engine | Go 1.22, **stdlib-only**, ~20,700 lines, 21 internal packages |
| Binary | ~6.5 MB static `winforge.exe` (PE32+ cross-compiled, verified) |
| Tweak catalogue | **240** tweaks / 390 distinct registry targets |
| Debloat catalogue | **102** app families |
| Install catalogue | **83** apps (winget) |
| Playbooks | 5 (Balanced, Privacy Max, Performance, Gaming Max, Debloat) |
| Locales | 13 |
| Extra subsystems | ISO builder, Windows Update, DNS, maintenance scheduler, Lua/WASM plugins, loopback web dashboard, audit DB |
| Tests | 21 Go packages, race-clean **on Linux** |

**The honest status.** WinForge's own `docs/BLOCKED_ITEMS.md` records **BLK-6: "No Windows
runtime for behavioral tests."** The engine has never executed against a real Windows machine —
it is verified to *compile* and to pass Linux-side logic tests. Its `AUDIT_REPORT.md` carries a
self-correction stating the competitive comparison table contains "unverified third-party
numbers… treat it as aspirational context rather than measured fact."

So the two projects have **complementary and opposite** risk profiles:

|  | Win11Debloat | WinForge |
|---|---|---|
| Catalogue breadth | Narrower (101) | Wider (240) |
| Real-world validation | Millions of runs, 6 years upstream | **Zero Windows executions** |
| Distribution & trust | Established, 39k★ upstream [reported] | None yet |
| Architecture ceiling | Limited by `.reg` format | Typed operations, extensible |
| Undo model | Per-feature inverse `.reg` | JSON undo payloads + audit DB |
| Breadth of ops | Registry + bespoke PS | Registry, services, tasks, power, commands |

**Conclusion: WinForge's value to this project is its *data and design*, not its code.** A Go
binary cannot be merged into a PowerShell script that people run via `irm | iex`. But its
catalogue, its typed-operation schema, its playbooks, its locale files and its Windows smoke
checklist are all directly harvestable.

### 1.3 Catalogue overlap — the core measurement [measured]

Parsing all 240 WinForge tweaks and all 242 Win11Debloat `.reg` files down to
`(hive, path, value-name)` triples:

```
WinForge registry targets       : 390
Win11Debloat registry targets   : 298
Overlap (identical target)      :  73
WinForge-only targets           : 317   <-- porting candidates
Win11Debloat-only targets       : 225
```

**158 of WinForge's 240 tweaks (66%) touch nothing Win11Debloat currently touches.** By category:

| Category | Uncovered tweaks | Notable examples |
|---|---|---|
| Quality of Life | 69 | Dynamic Lighting, Cross-Device Resume, Settings Tips, Ink Workspace, Spell Checking, wallpaper compression |
| Privacy | 36 | Office telemetry, NVIDIA telemetry, Settings Sync, Activity Feed, Experimentation, PCA, lockscreen camera, app permissions |
| Performance | 13 | Background Apps, MMCSS, automatic maintenance, prefetch tuning, foreground priority |
| Customize Preferences | 12 | — |
| Network / Networking | 10 | LLMNR, DoH, Wi-Fi Sense, QoS reservation, SMB throttling, anonymous access restrictions |
| Telemetry | 4 | CEIP, data-collection policy lock |
| Gaming | 4 | HAGS, fullscreen optimisations, MMCSS gaming profile, power throttling |
| Explorer | 3 | Recent files in Quick Access, thumbnail cache size |
| Security | 2 | Anonymous SAM enumeration, Remote Assistance |

**Operation types WinForge uses that Win11Debloat cannot currently express:**

```
27  service_start_mode      8  task_disable       2  power_scheme
22  command                 8  registry_delete    1  netbios
 1  service_start/stop      1  task_enable        1  power_hibernate / processor_state
```

**App catalogue overlap:** 61 shared families, **41 WinForge-only**, 81 Win11Debloat-only.
The 41 include high-value OEM bloat that Win11Debloat lacks: `dell.supportassist`,
`dell.customerconnect`, `hp.jumpstart`, `hp.supportassistant`, `lenovo.vantage`,
`lenovo.utility`, `acer.carecenter`, `asus.giftbox`, `asus.liveupdate`, `mcafee.livesafe`,
`norton.security`, plus consumer junk (`netflix`, `tiktok`, `instagram`, `whatsapp`,
`linkedin`, `twitter`, `disney.magickingdoms`, the Microsoft casual-games set).

> ⚠️ **Safety finding.** WinForge's debloat list also contains **framework and platform
> packages that must never be removed**: `microsoft.vclibs.140.00`, `microsoft.ui.xaml.2.8`
> and `microsoft.desktopappinstaller` (which *is* winget). Removing these breaks other Store
> apps and the package manager itself. Any port must be triaged against Win11Debloat's
> existing `safe / optional / unsafe` rating system rather than bulk-imported. This is
> concrete evidence for **porting data selectively, never wholesale**.

---

## 2. Windows landscape 2026 — what changed and why it matters

### 2.1 The AI surface kept moving, then partly reversed

- Windows 11 **25H2 turned on by default** what 24H2 held behind enterprise feature control:
  **AI actions in File Explorer, Click to Do, and Agent in Settings**
  ([Microsoft update history](https://support.microsoft.com/en-us/topic/windows-11-version-25h2-update-history-99c7f493-df2a-4832-bd2d-6706baa0dec0)).
- In **March 2026 Microsoft publicly reversed course**, cutting "unnecessary Copilot entry
  points" starting with Photos, Notepad, Widgets and Snipping Tool, and shelving Copilot in
  Settings/File Explorer/notifications
  ([TechPowerUp](https://www.techpowerup.com/345893/microsoft-steps-back-from-ai-everywhere-in-windows-11-to-focus-on-core-features),
  [The Outpost](https://theoutpost.ai/news-story/microsoft-scales-back-copilot-in-windows-11-scrapping-features-after-user-pushback-24597/)).
- But new surfaces are still landing: **Ask Copilot in the taskbar** and an advanced
  **Click to Do** are slated for mid-2026
  ([Windows Latest](https://www.windowslatest.com/2026/05/27/microsoft-confirms-ask-copilot-is-coming-to-the-windows-11-taskbar-in-mid-2026/)).
- And **M365 Copilot resumed auto-installing via the Office updater in June 2026** — a channel
  that is *not* Windows Update or the Store, and is opt-out only
  ([Technobezz](https://www.technobezz.com/news/microsoft-quietly-reinstalls-copilot-on-windows-11-through-office-app-updater)).

**Implication:** the target is not static. A debloat tool's catalogue is a *perishable good*.
This argues for (a) faster catalogue iteration, (b) version gating that already exists here,
and (c) treating "did my tweak survive?" as a first-class feature.

### 2.2 The #1 unsolved user problem: **drift**

Every credible source converges on the same complaint — changes do not stick:

- Copilot ships as "an AppX package, a system feature flag, **and** a taskbar pin — three
  separate surfaces refreshed by different parts of the update pipeline"
  ([SageTweaks](https://www.sagetweaks.com/blog/remove-copilot-windows-11)).
- Microsoft's own `RemoveMicrosoftCopilotApp` policy is explicitly a **one-time uninstall, not
  a persistent block**; feature updates, Store restores and tenant provisioning re-introduce it
  ([WindowsForum](https://windowsforum.com/threads/windows-11-copilot-removal-why-one-time-uninstalls-fall-short-and-applocker-wins.396367/)).
- Re-provisioning is driven by **Content Delivery Manager / consumer experiences** and
  `SilentInstalledAppsEnabled`; guides that omit these report apps returning after updates
  ([how2shout](https://www.how2shout.com/how-to/how-to-disable-copilot-windows-11.html),
  [iQon](https://iqondigital.com/learn/pc-optimization/copilot-bloatware)).
- Paul Thurrott, reviewing Win11Debloat specifically: *"I am actively seeking a tool that will
  monitor for these types of changes, but for now, you can always re-run Win11Debloat if you
  notice any unwanted changes."*
  ([Thurrott.com](https://www.thurrott.com/windows/windows-11/332739/de-enshittify-an-existing-install-of-windows-11))

**That is an unmet need, stated in public, about this exact tool, by a major reviewer — and
Win11Debloat is already ~80% of the way to solving it** because `Test-FeatureApplied` can
already tell whether a feature's registry state still matches. See **U-01**, the single
highest-value item in this document.

### 2.3 Removal mechanics have moved on

- **Provisioned packages** (`Remove-AppxProvisionedPackage` / DISM) are what stop an app
  reaching *new* user profiles; per-user removal alone does not
  ([kylereddoch](https://www.kylereddoch.me/blog/remove-preinstalled-microsoft-store-apps-in-windows-11-24h2-and-25h2/)).
  Win11Debloat does call `Get-AppxProvisionedPackage` in `Remove-SelectedApps.ps1` — worth an
  audit that deprovisioning is applied consistently and surfaced in the UI.
- Windows 11 25H2 added a **policy-based removal** path —
  `Remove default Microsoft Store packages from the system` (GPO / Intune / CSP, writing to
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\Appx\RemoveDefaultMicrosoftStorePackages`) — for
  Enterprise/Education
  ([ElevenForum](https://www.elevenforum.com/t/new-policy-based-removal-of-pre-installed-microsoft-store-apps-on-windows-11.41307/)).
  This is a *durable* removal channel Win11Debloat does not use.

### 2.4 Competitive position [reported]

| Tool | Stars | Debloat | Per-tweak undo | App installer | ISO builder | Services | i18n |
|---|---|---|---|---|---|---|---|
| WinUtil (Chris Titus) | ~46.8k | ✅ | ❌ (restore point only) | ✅ winget | ✅ MicroWin | ✅ | ❌ |
| **Win11Debloat** | ~39.1k | ✅ | ✅ **(differentiator)** | ❌ | ❌ | ❌ | ❌ |
| O&O ShutUp10++ | closed | ❌ | ✅ | ❌ | ❌ | ❌ | partial |
| privacy.sexy | open | ✅ | ✅ script | ❌ | ❌ | ✅ | ❌ |

Source: [rain-city.tech comparison](https://rain-city.tech/blog/best-windows-debloat/),
[tech2geek](https://www.tech2geek.net/8-free-tools-to-improve-windows-11-privacy-and-reduce-tracking/).

**Read:** Win11Debloat's moat is *reversibility + focus*, not breadth. WinUtil wins on breadth.
Trying to out-breadth WinUtil (ISO builder, installer, service surgery) plays to its strength.
Doubling down on **"every change is reversible, verifiable, and stays applied"** is a defensible
position no one else occupies.

---

## 3. Fork strategy — a constraint that shapes everything

This repo is a **fork**. Upstream `Raphire/Win11Debloat` shipped at least 12 releases between
Nov 2025 and Jul 2026 (2026.04.05, 2026.04.26, 2026.06.11, 2026.06.24, 2026.07.11, …) and our
HEAD is PR #739. Upstream velocity is roughly weekly.

Consequences:

- **Every line we add that upstream doesn't have is a future merge conflict.** A heavy fork
  becomes unmaintainable within months at this cadence.
- Therefore each upgrade below is tagged with a **track**:
  - `UPSTREAM` — generic improvement; contribute as a PR to Raphire, benefit everyone, zero
    long-term fork burden.
  - `FORK` — differentiating or opinionated; keep local, accept the maintenance cost.
  - `SIDECAR` — ships as a *separate* artifact (module, scheduled task, CLI) that consumes
    Win11Debloat rather than modifying it — near-zero merge risk.

`SIDECAR` is strategically attractive and under-used: it is how we can build big features
(drift guard, reporting, fleet tooling) without forking the core.

---

## 4. Method note on verification

The sandbox has **no PowerShell runtime**, package egress to Microsoft/PSGallery is blocked, and
Actions is disabled on this fork — so nothing in this repo can be executed or Pester-tested
here. A tree-sitter PowerShell grammar was compiled from npm source to give real parse-level
checking (see the previous session's report). **Any roadmap item below must budget for
validation on real Windows**, and Section 5.C exists precisely to close that gap.

---

## 5. The upgrade catalogue

Scoring: **Impact** (user value) / **Effort** / **Risk** — each 1–5. `Score = Impact² / (Effort × Risk)`,
a crude but consistent ranking. Track as defined in §3.

### A. Differentiating features

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| **U-01** | **Drift Guard** — detect & re-apply settings that Windows reverted | 5 | 3 | 2 | **4.2** | SIDECAR |
| U-02 | Durable app removal: provisioned + policy-based (`RemoveDefaultMicrosoftStorePackages`) + `SilentInstalledAppsEnabled` + CDM hardening | 5 | 2 | 3 | 4.2 | UPSTREAM |
| U-03 | OEM bloat pack: +41 app families (Dell/HP/Lenovo/Acer/ASUS/McAfee/Norton/consumer) | 4 | 1 | 2 | 8.0 | UPSTREAM |
| U-04 | Post-run **verification report** — assert each applied feature actually took effect, export HTML/JSON | 4 | 2 | 1 | 8.0 | FORK |
| U-05 | Health / privacy **score** with before-after delta | 3 | 2 | 1 | 4.5 | FORK |
| U-06 | Playbooks/presets (Balanced, Privacy Max, Gaming, Work) harvested from WinForge | 3 | 1 | 2 | 4.5 | UPSTREAM |
| U-07 | **i18n** — externalise strings; seed from WinForge's 13 locales | 4 | 4 | 2 | 2.0 | UPSTREAM |
| U-08 | 2026 AI-surface refresh: Ask Copilot taskbar, AI actions in Explorer, Agent in Settings, M365-Copilot-via-Office-updater opt-out | 4 | 2 | 2 | 4.0 | UPSTREAM |
| U-09 | Scheduled "keep it clean" task (weekly re-assert) — the automation half of U-01 | 4 | 2 | 3 | 2.7 | SIDECAR |

**U-01 — Drift Guard (the flagship).** Snapshot the intended configuration after a run
(`intended-state.json`). Provide `Test-Win11DebloatDrift` which walks each intended feature via
the *existing* `Test-FeatureApplied` plus app-presence checks, and reports three buckets:
`STILL_APPLIED` / `REVERTED_BY_WINDOWS` / `CHANGED_BY_USER`. Optional scheduled task re-asserts
reverted items (U-09). This directly answers the Thurrott gap, reuses machinery that already
exists, and can ship as a sidecar module with near-zero merge risk.

### B. Architecture

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| U-10 | **Catalogue schema v2**: typed operations (`registry_set`, `service_start_mode`, `task_disable`, `power`, `command`) replacing `.reg`-only, with auto-derived undo — modelled on WinForge's schema | 5 | 5 | 4 | 1.25 | UPSTREAM |
| U-11 | Per-feature error isolation in `Invoke-ApplyFeatures`/`Invoke-UndoFeatures` (one failure ≠ aborted batch) | 4 | 1 | 2 | 8.0 | UPSTREAM |
| U-12 | Convert `Scripts/` into a real PowerShell **module** (`.psd1`/`.psm1`, explicit exports) | 3 | 4 | 3 | 0.75 | UPSTREAM |
| U-13 | **Policy-first application** — prefer `HKLM\...\Policies` keys where they exist, since they survive updates better | 4 | 2 | 3 | 2.7 | UPSTREAM |
| U-14 | Services subsystem + protected-service allow-list (harvest WinForge's 14-entry list) | 3 | 3 | 4 | 0.75 | FORK |
| U-15 | Scheduled-task subsystem generalised beyond telemetry tasks | 3 | 2 | 3 | 1.5 | UPSTREAM |
| U-16 | PowerShell 7 support via `Import-Module Appx -UseWindowsPowerShell` instead of hard refusal | 3 | 2 | 3 | 1.5 | UPSTREAM |
| U-17 | Structured JSON run-log alongside the transcript (fleet/automation consumable) | 3 | 1 | 1 | 9.0 | UPSTREAM |
| U-18 | Transactional apply: rollback the batch on mid-run failure | 3 | 4 | 4 | 0.56 | FORK |

### C. Verification & quality  ← *the enabling wave*

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| U-19 | **Catalogue schema validation in CI** (JSON Schema; `Schemas/` dir already exists) | 4 | 1 | 1 | 16.0 | UPSTREAM |
| U-20 | **Apply/undo parity test** — every apply `.reg` has an undo touching the same value set | 5 | 2 | 1 | 12.5 | UPSTREAM |
| U-21 | PSScriptAnalyzer gate in CI, scoped to `-Severity Error` first, then ratchet | 3 | 1 | 1 | 9.0 | UPSTREAM |
| U-22 | **Windows Sandbox / VM E2E smoke suite** — harvest WinForge's `WINDOWS_SMOKE_CHECKLIST.md` | 5 | 4 | 2 | 3.1 | UPSTREAM |
| U-23 | Test matrix across Win10 22H2 / Win11 23H2 / 24H2 / 25H2 images | 4 | 4 | 2 | 2.0 | UPSTREAM |
| U-24 | Feature-catalogue ↔ CLI-parameter ↔ README parity test (all 3 currently hand-synced) | 3 | 1 | 1 | 9.0 | UPSTREAM |
| U-25 | Coverage reporting on the Pester suite | 2 | 2 | 1 | 2.0 | UPSTREAM |

**U-20 is the highest-scoring item in the entire document** and is cheap: 76 of 87 registry
features claim an undo — a test proving each undo actually inverts each apply (same hive, path
and value names) protects the project's single biggest differentiator. Today nothing enforces it.

### D. Security & supply chain

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| U-26 | **Code signing** of released scripts + published checksums | 5 | 3 | 2 | 4.2 | UPSTREAM |
| U-27 | Harden the `irm \| iex` channel: version pinning, integrity check, documented "read before you run" | 4 | 2 | 2 | 4.0 | UPSTREAM |
| U-28 | Build provenance / SLSA attestation on releases | 3 | 3 | 1 | 3.0 | UPSTREAM |
| U-29 | Threat model doc — the tool runs elevated and is a high-value supply-chain target | 3 | 2 | 1 | 4.5 | UPSTREAM |
| U-30 | Secret + dangerous-pattern scanning in CI on the `.reg` corpus | 2 | 1 | 1 | 4.0 | UPSTREAM |

### E. Catalogue expansion (from WinForge) — triaged, never bulk

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| U-31 | Port the **36 uncovered Privacy tweaks** (Office/NVIDIA telemetry, Activity Feed, Settings Sync, Experimentation, PCA, app permissions) | 4 | 3 | 2 | 2.7 | UPSTREAM |
| U-32 | Port the **10 uncovered Network tweaks** (LLMNR, DoH, Wi-Fi Sense, SMB throttling, anonymous-access restrictions) | 3 | 2 | 3 | 1.5 | UPSTREAM |
| U-33 | Port selected **Explorer/QoL** tweaks (Dynamic Lighting, Cross-Device Resume, Settings Tips, Recent Files, Ink Workspace) | 3 | 3 | 2 | 1.5 | UPSTREAM |
| U-34 | Port **Security** tweaks (anonymous SAM enumeration, Remote Assistance) | 3 | 2 | 3 | 1.5 | UPSTREAM |
| U-35 | Port **Gaming** tweaks (HAGS, fullscreen optimisations, power throttling) — *evidence required per tweak* | 2 | 3 | 4 | 0.33 | FORK |
| U-36 | ⛔ Performance folklore (TDR disable, Large System Cache, Nagle, paging tricks) — **reject unless benchmarked** | 1 | 3 | 5 | 0.07 | — |

### F. Distribution & DX

| ID | Upgrade | I | E | R | Score | Track |
|---|---|---|---|---|---|---|
| U-37 | Publish Win11Debloat itself to **winget** | 3 | 2 | 1 | 4.5 | UPSTREAM |
| U-38 | Auto-generate per-feature docs ("exactly what this changes") from the catalogue | 4 | 2 | 1 | 8.0 | UPSTREAM |
| U-39 | `New-Feature` scaffolding generator (reg + undo + sysprep + test + catalogue entry) | 3 | 2 | 1 | 4.5 | UPSTREAM |
| U-40 | Intune / GPO / Autopilot deployment guide + sample configs | 3 | 2 | 1 | 4.5 | UPSTREAM |
| U-41 | `CHANGELOG.md` in Keep-a-Changelog format (none exists) | 2 | 1 | 1 | 4.0 | UPSTREAM |

### G. Scope expansions — *decision required, see §8*

| ID | Upgrade | I | E | R | Score | Verdict |
|---|---|---|---|---|---|---|
| U-42 | App **installer** (winget, 83-app catalogue from WinForge) | 3 | 3 | 2 | 1.5 | Contradicts upstream's stated focus; big WinUtil overlap |
| U-43 | System repair (SFC / DISM / CHKDSK) | 2 | 3 | 3 | 0.44 | Out of character for a debloater |
| U-44 | ISO / image builder (MicroWin-like) | 3 | 5 | 4 | 0.45 | Very large; NTLite & WinUtil own this |
| U-45 | Web dashboard / local HTTP UI | 2 | 4 | 4 | 0.25 | Attack surface on an elevated tool; WPF GUI already exists |
| U-46 | Plugin system (Lua/WASM) | 2 | 5 | 5 | 0.16 | Arbitrary code execution in an elevated context |

---

## 6. Recommended sequencing

### Wave 0 — Make verification real *(prerequisite for everything)*
`U-19` schema validation · `U-20` apply/undo parity · `U-21` PSScriptAnalyzer ·
`U-24` catalogue↔CLI↔README parity · `U-17` structured logging

Cheap, high-scoring, no user-visible risk. Wave 0 is what makes every later wave safe to ship
given that this environment cannot execute PowerShell.

### Wave 1 — Fix and fortify what exists
`U-11` per-feature error isolation · `U-02` durable app removal · `U-03` OEM bloat pack ·
`U-13` policy-first keys · `U-38` generated feature docs

Highest value-per-unit-effort. `U-03` alone measurably improves real-world outcomes on every
OEM laptop.

### Wave 2 — The flagship
`U-01` Drift Guard · `U-04` verification report · `U-09` scheduled re-assert · `U-05` health score

Ships as a sidecar module. This is the differentiator no competitor has and a named reviewer
has publicly asked for.

### Wave 3 — Catalogue growth
`U-31` privacy · `U-32` network · `U-33` QoL · `U-34` security — each triaged, each with an
undo, each with a Pester test, each gated by `MinVersion`/`MaxVersion`.

### Wave 4 — Depth
`U-10` schema v2 · `U-15` tasks · `U-14` services · `U-22`/`U-23` Windows E2E matrix ·
`U-07` i18n · `U-26` signing

Wave 4 is where the big architectural bets live; do not start them before Wave 0 exists.

---

## 7. What we should deliberately NOT do

1. **Do not merge the WinForge Go engine into this repo.** Different language, different
   distribution model, and it has never run on Windows. Harvest its catalogue, schema,
   playbooks, locales and smoke checklist instead.
2. **Do not bulk-import WinForge's debloat list.** It contains `microsoft.vclibs.140.00`,
   `microsoft.ui.xaml.2.8` and `microsoft.desktopappinstaller` (winget itself). Triage against
   the existing safe/optional/unsafe rating.
3. **Do not import AtlasOS-style performance folklore** (U-36). Disabling TDR, forcing Large
   System Cache and Nagle tweaks are cargo-cult; several can destabilise a machine. If a perf
   tweak cannot be defended with a measurement, it does not ship.
4. **Do not chase WinUtil's breadth** (installer, ISO builder, service surgery) as a first
   move. It is their moat, not ours.
5. **Do not fork heavily.** At upstream's ~weekly cadence, prefer `UPSTREAM` and `SIDECAR`
   tracks; reserve `FORK` for genuinely opinionated differentiators.
6. **Do not claim a feature works without executing it on Windows.** The current environment
   cannot run Pester; Wave 0 + U-22 exist to remove that blind spot.

---

## 8. Decisions needed before execution

| # | Decision | Options | Default if unanswered |
|---|---|---|---|
| D1 | **Fork posture** | (a) upstream-first contributor, (b) differentiated downstream product, (c) sidecar toolkit around upstream | (a)+(c): upstream generic fixes, sidecar for Drift Guard |
| D2 | **Scope** | stay a focused debloater, or expand toward an all-in-one suite (U-42…U-46) | Stay focused; revisit after Wave 2 |
| D3 | **WinForge's future** | (a) retire it and harvest, (b) keep as the Go/native track, (c) make it the engine with Win11Debloat as catalogue | (a) harvest — it has never run on Windows |
| D4 | **Windows validation** | Is a real Windows machine / VM / CI runner available for E2E? | Assume no; ship Wave 0 static gates first |
| D5 | **Aggressiveness ceiling** | Does the product accept `high`-risk tweaks at all? | Cap at `medium`; `high` requires benchmark or CVE-grade justification |

---

## Appendix — reproducing the measurements

Catalogue counts, registry-target overlap and app-family overlap in §1 and §1.3 were produced
by parsing `Config/Features.json`, `Config/Apps.json`, `Regfiles/**/*.reg` (UTF-16 and UTF-8
variants) and `/tmp/winforge/config/*.json`. The overlap key is the normalised triple
`(hive, path, value-name)` with hive aliases folded (`HKEY_LOCAL_MACHINE`→`HKLM`, etc.).
