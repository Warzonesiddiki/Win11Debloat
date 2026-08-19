#!/usr/bin/env python3
"""
Reference implementation of the Win11Debloat catalogue gates.

The Pester suite (Tests/CatalogParity.Tests.ps1 and friends) enforces these same
contracts, but it cannot run in environments without a PowerShell runtime. This
script is an INDEPENDENT reimplementation of the same logic in Python so the gates
can be run anywhere (CI-free forks, sandboxes, pre-commit hooks). It deliberately
re-parses the .reg corpus from scratch rather than importing the PowerShell
Get-RegFileOperations parser, because a parity check that shares a parser with the
code it checks cannot catch a parser-level mistake.

Gates implemented:
  1. Catalogue integrity      (unique ids, valid categories, file existence)
  2. Apply/undo parity        (every applied value/key is reversed by undo)
  3. Sysprep parity           (every applied value/key mirrored into Sysprep)
  4. Collision check          (no two features write the same registry value,
                               except the known mutually-exclusive option groups)
  5. CLI surface parity       (feature <-> [switch] in both entry points)
   6. Docs parity              (docs/FEATURES.md matches the catalogue)
   7. Preset validation        (presets reference only real, enabled features)
   8. Regfile format           (every .reg is valid UTF-16LE/BOM/CRLF with a header
                                and at least one section)
   9. Switch uniqueness        (no duplicate parameter in either entry point)
  10. No silent no-op          (a feature's apply file sets/deletes a value)


Exit code is non-zero if any gate fails.
"""

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGFILES = os.path.join(REPO_ROOT, "Regfiles")
CONFIG = os.path.join(REPO_ROOT, "Config")
DOCS = os.path.join(REPO_ROOT, "docs", "FEATURES.md")
MAIN_SCRIPT = os.path.join(REPO_ROOT, "Win11Debloat.ps1")
LAUNCHER = os.path.join(REPO_ROOT, "Scripts", "Get.ps1")

# Parameters that exist only on the Get.ps1 launcher.
LAUNCHER_ONLY_PARAMS = {"Dev", "Verbose", "WhatIf"}

HIVE_MAP = {
    "HKEY_CURRENT_USER": "HKCU",
    "HKEY_LOCAL_MACHINE": "HKLM",
    "HKEY_CLASSES_ROOT": "HKCR",
    "HKEY_USERS": "HKU",
    "HKEY_CURRENT_CONFIG": "HKCC",
}


def normalize_key(key_path):
    parts = key_path.split("\\", 1)
    hive = parts[0].strip().upper()
    hive = HIVE_MAP.get(hive, hive)
    sub = parts[1].strip().lower() if len(parts) > 1 else ""
    return hive + "\\" + sub


def sysprep_key(normalized_key):
    if normalized_key.startswith("HKCU\\"):
        return "HKU\\default\\" + normalized_key[5:]
    return normalized_key


def key_is_under(key, ancestor):
    return key == ancestor or key.startswith(ancestor + "\\")


def read_text(path):
    for enc in ("utf-16", "utf-8"):
        try:
            with open(path, encoding=enc) as fh:
                return fh.read()
        except UnicodeError:
            continue
    # Last resort: let open raise if truly unreadable.
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def parse_reg_file(path):
    """Return (set_entries, created_keys, deleted_keys).

    set_entries is a set of 'key::valuename' composites (key and valuename
    lowercased, matching the Pester Get-RegFileTargets normalisation).
    """
    text = read_text(path)
    set_entries = set()
    created_keys = set()
    deleted_keys = set()
    current_key = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("Windows Registry Editor Version"):
            continue
        m = re.match(r"^\[(-)?(.*)\]$", line)
        if m:
            current_key = normalize_key(m.group(2))
            if m.group(1):
                deleted_keys.add(current_key)
            else:
                created_keys.add(current_key)
            continue
        if current_key is None:
            continue
        vm = re.match(r'^(@|"[^"]+")\s*=', line)
        if vm:
            value_name = "" if vm.group(1) == "@" else vm.group(1).strip('"').lower()
            set_entries.add("{}::{}".format(current_key, value_name))
    return set_entries, created_keys, deleted_keys


def resolve_undo_path(file_name):
    undo = os.path.join(REGFILES, "Undo", file_name)
    if os.path.exists(undo):
        return undo
    return os.path.join(REGFILES, file_name)


def load_features():
    with open(os.path.join(CONFIG, "Features.json"), encoding="utf-8-sig") as fh:
        catalog = json.load(fh)
    return catalog


def extract_param_names(path):
    """Return the set of parameter names declared in the script-level param()
    block. Mirrors the Pester Get-ScriptParameterName, which uses the AST
    ParamBlock.Parameters and therefore includes every parameter regardless of
    type ([switch], [string], ...)."""
    text = read_text(path)
    m = re.search(r"param\s*\(", text)
    if not m:
        return set()
    start = m.end() - 1  # index of '('
    depth = 0
    i = start
    end = len(text)
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                end = i
                break
        i += 1
    block = text[start:end]
    return set(re.findall(r"\]\s*\$(\w+)", block))


def extract_control_params(path):
    """Parse the authoritative control-parameter list from the
    '$script:ControlParams = '...'' line in the main script, the same source
    the Pester CLI-parity test uses."""
    text = read_text(path)
    for line in text.splitlines():
        if "$script:ControlParams" in line and "=" in line:
            return set(re.findall(r"'([^']+)'", line))
    return set()


# ---------------------------------------------------------------------------
# Gate runners each return a list of failure strings (empty == pass).
# ---------------------------------------------------------------------------

def gate_catalogue_integrity(catalog):
    failures = []
    features = catalog["Features"]
    ids = [f["FeatureId"] for f in features]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        failures.append("Duplicate FeatureIds: " + ", ".join(sorted(dupes)))

    cat_names = {c["Name"] for c in catalog["Categories"]}
    cat_ids = {c["CategoryId"] for c in catalog["Categories"]}
    for f in features:
        cat = f.get("Category")
        if cat and cat not in cat_names and cat not in cat_ids:
            failures.append("Feature {} maps to unknown category '{}'".format(f["FeatureId"], cat))

    for f in features:
        rk = f.get("RegistryKey")
        if rk and not os.path.exists(os.path.join(REGFILES, rk)):
            failures.append("Feature {} apply file missing: {}".format(f["FeatureId"], rk))
        ruk = f.get("RegistryUndoKey")
        if ruk and not os.path.exists(resolve_undo_path(ruk)):
            failures.append("Feature {} undo file missing: {}".format(f["FeatureId"], ruk))
        if rk and not os.path.exists(os.path.join(REGFILES, "Sysprep", rk)):
            failures.append("Feature {} missing Sysprep variant: {}".format(f["FeatureId"], rk))
        if rk and os.path.exists(os.path.join(REGFILES, rk)):
            s, c, d = parse_reg_file(os.path.join(REGFILES, rk))
            if not s and not c and not d:
                failures.append("Feature {} apply file is a silent no-op (no operations)".format(f["FeatureId"]))
    return failures


def gate_apply_undo_parity(catalog):
    failures = []
    for f in catalog["Features"]:
        rk = f.get("RegistryKey")
        ruk = f.get("RegistryUndoKey")
        if not rk or not ruk:
            continue
        apply_path = os.path.join(REGFILES, rk)
        undo_path = resolve_undo_path(ruk)
        if not os.path.exists(apply_path) or not os.path.exists(undo_path):
            continue
        apply_set, apply_created, apply_deleted = parse_reg_file(apply_path)
        undo_set, undo_created, undo_deleted = parse_reg_file(undo_path)
        uncovered = []
        for entry in apply_set:
            key, _, value = entry.partition("::")
            if entry in undo_set:
                continue
            if any(key_is_under(key, dk) for dk in undo_deleted):
                continue
            uncovered.append(entry)
        for dk in apply_deleted:
            if any(key_is_under(ck, dk) for ck in undo_created):
                continue
            uncovered.append(dk + " (key is never recreated)")
        if uncovered:
            failures.append("{} [{} -> {}]: {}".format(
                f["FeatureId"], rk, ruk, "; ".join(sorted(uncovered))))
    return failures


def gate_sysprep_parity(catalog):
    failures = []
    for f in catalog["Features"]:
        rk = f.get("RegistryKey")
        if not rk:
            continue
        apply_path = os.path.join(REGFILES, rk)
        sysprep_path = os.path.join(REGFILES, "Sysprep", rk)
        if not os.path.exists(apply_path) or not os.path.exists(sysprep_path):
            continue
        apply_set, apply_created, apply_deleted = parse_reg_file(apply_path)
        sysprep_set, sysprep_created, sysprep_deleted = parse_reg_file(sysprep_path)
        missing = []
        for entry in apply_set:
            key, _, value = entry.partition("::")
            expected = "{}::{}".format(sysprep_key(key), value)
            if expected not in sysprep_set:
                missing.append(expected)
        for dk in apply_deleted:
            if sysprep_key(dk) not in sysprep_deleted:
                missing.append(sysprep_key(dk) + " (key deletion)")
        if missing:
            failures.append("{} [Sysprep\\{}]: {}".format(f["FeatureId"], rk, "; ".join(sorted(missing))))
    return failures


def gate_collision(catalog):
    """No two features may write the same registry value, except the known
    mutually-exclusive option groups (baseline discovered below)."""
    # Baseline of allowed collisions: the 9 intentional mutually-exclusive
    # option groups shipped in the catalogue. Every one of these is an option
    # group where exactly one member is applied at a time (taskbar combine mode,
    # multi-monitor taskbar mode, search-box style, Explorer launch target,
    # Alt+Tab tab count, drive-letter position, Start All Apps layout, and the
    # Start "More programs" view). A 10th collision would be a genuine mistake.
    allowed = {
        r"HKCU\software\microsoft\windows\currentversion\explorer::showdrivelettersfirst",
        r"HKCU\software\microsoft\windows\currentversion\explorer\advanced::launchto",
        r"HKCU\software\microsoft\windows\currentversion\explorer\advanced::mmtaskbarglomlevel",
        r"HKCU\software\microsoft\windows\currentversion\explorer\advanced::mmtaskbarmode",
        r"HKCU\software\microsoft\windows\currentversion\explorer\advanced::multitaskingalttabfilter",
        r"HKCU\software\microsoft\windows\currentversion\explorer\advanced::taskbarglomlevel",
        r"HKCU\software\microsoft\windows\currentversion\policies\explorer::nostartmenumoreprograms",
        r"HKCU\software\microsoft\windows\currentversion\search::searchboxtaskbarmode",
        r"HKCU\software\microsoft\windows\currentversion\start::allappsviewmode",
    }
    value_authors = {}
    for f in catalog["Features"]:
        rk = f.get("RegistryKey")
        if not rk:
            continue
        apply_path = os.path.join(REGFILES, rk)
        if not os.path.exists(apply_path):
            continue
        apply_set, _, _ = parse_reg_file(apply_path)
        for entry in apply_set:
            value_authors.setdefault(entry, set()).add(f["FeatureId"])

    failures = []
    for entry, authors in sorted(value_authors.items()):
        if len(authors) > 1 and entry not in allowed:
            failures.append("{} written by: {}".format(entry, ", ".join(sorted(authors))))
    return failures


def gate_cli_parity(catalog):
    failures = []
    features = catalog["Features"]
    ids = {f["FeatureId"] for f in features}
    main_params = extract_param_names(MAIN_SCRIPT)
    launcher_params = extract_param_names(LAUNCHER)
    control_params = extract_control_params(MAIN_SCRIPT)

    for fid in ids:
        if fid not in main_params:
            failures.append("Feature {} has no parameter in Win11Debloat.ps1".format(fid))
        if fid not in launcher_params:
            failures.append("Feature {} has no parameter in Get.ps1".format(fid))

    for p in main_params:
        if p not in ids and p not in control_params:
            failures.append("Parameter -{} in Win11Debloat.ps1 maps to no feature".format(p))

    missing_from_launcher = sorted(s for s in main_params if s not in launcher_params)
    extra_on_launcher = sorted(
        s for s in launcher_params if s not in main_params and s not in LAUNCHER_ONLY_PARAMS)
    if missing_from_launcher:
        failures.append("Launcher missing parameters: " + ", ".join(missing_from_launcher))
    if extra_on_launcher:
        failures.append("Launcher declares undeclared parameters: " + ", ".join(extra_on_launcher))
    return failures


def gate_docs_parity(catalog):
    failures = []
    features = catalog["Features"]
    if not os.path.exists(DOCS):
        return ["docs/FEATURES.md does not exist"]
    doc = read_text(DOCS)
    documented = set(re.findall(r"(?m)^`-(\w+)`\s*$", doc))

    for f in features:
        if f["FeatureId"] not in documented:
            failures.append("Feature {} not documented in FEATURES.md".format(f["FeatureId"]))
    for d in documented:
        if d not in {f["FeatureId"] for f in features}:
            failures.append("FEATURES.md documents stale feature {}".format(d))
    dupes = {d for d in documented if list(documented).count(d) > 1}
    if dupes:
        failures.append("FEATURES.md documents duplicates: " + ", ".join(sorted(dupes)))

    for f in features:
        if not f.get("Category"):
            continue
        if "## {}".format(f["Category"]) not in doc:
            failures.append("FEATURES.md missing category heading '{}'".format(f["Category"]))

    if "{} settings across".format(len(features)) not in doc:
        failures.append("FEATURES.md summary count is stale (expected {} settings)".format(len(features)))

    for f in features:
        rk = f.get("RegistryKey")
        if rk and rk not in doc:
            failures.append("FEATURES.md does not name reg file for {}".format(f["FeatureId"]))
    return failures


def gate_preset_validation(catalog):
    failures = []
    ids = {f["FeatureId"] for f in catalog["Features"]}
    preset_dir = os.path.join(CONFIG, "Presets")
    if not os.path.isdir(preset_dir):
        return ["Config/Presets directory missing"]
    presets = [p for p in os.listdir(preset_dir) if p.endswith(".json")]
    if not presets:
        failures.append("No presets shipped")
    for name in presets:
        with open(os.path.join(preset_dir, name), encoding="utf-8-sig") as fh:
            preset = json.load(fh)
        if preset.get("Version") != "1.0":
            failures.append("{}: Version is not 1.0".format(name))
        if not preset.get("Description"):
            failures.append("{}: missing Description".format(name))
        tweaks = preset.get("Tweaks", [])
        if not tweaks:
            failures.append("{}: selects no settings".format(name))
        tweak_ids = [t["Name"] for t in tweaks]
        for tid in tweak_ids:
            if tid not in ids:
                failures.append("{}: references unknown feature {}".format(name, tid))
        dupes = {t for t in tweak_ids if tweak_ids.count(t) > 1}
        if dupes:
            failures.append("{}: duplicate tweaks: {}".format(name, ", ".join(sorted(dupes))))
        for t in tweaks:
            if t.get("Value") is not True:
                failures.append("{}: tweak {} is not enabled (Value!=true)".format(name, t.get("Name")))
        deployment = {d["Name"]: d.get("Value") for d in preset.get("Deployment", [])}
        if deployment.get("CreateRestorePoint") is not True:
            failures.append("{}: does not request a restore point".format(name))
    return failures


def gate_app_catalogue_integrity():
    failures = []
    path = os.path.join(CONFIG, "Apps.json")
    if not os.path.exists(path):
        return ["Config/Apps.json does not exist"]
    with open(path, encoding="utf-8-sig") as fh:
        app_catalog = json.load(fh)
    apps = app_catalog.get("Apps", [])

    seen = {}
    duplicates = []
    for app in apps:
        raw = app.get("AppId", [])
        app_ids = [raw] if isinstance(raw, str) else list(raw)
        for app_id in app_ids:
            if app_id in seen:
                duplicates.append(app_id)
            else:
                seen[app_id] = True
    if duplicates:
        failures.append("Duplicate AppIds: " + ", ".join(sorted(set(duplicates))))

    for app in apps:
        raw = app.get("AppId", [])
        app_ids = [raw] if isinstance(raw, str) else list(raw)
        if not app.get("FriendlyName") or not app_ids or not app_ids[0]:
            failures.append("App missing name or AppId: {}".format(app.get("FriendlyName")))

    valid_rec = {"safe", "optional", "unsafe"}
    for app in apps:
        if app.get("Recommendation") not in valid_rec:
            failures.append("App {} has invalid recommendation '{}'".format(
                app.get("FriendlyName"), app.get("Recommendation")))

    valid_method = {"Appx", "WinGet"}
    for app in apps:
        if app.get("RemovalMethod") not in valid_method:
            failures.append("App {} has invalid removal method '{}'".format(
                app.get("FriendlyName"), app.get("RemovalMethod")))

    for preset in app_catalog.get("Presets", []):
        for app_id in preset.get("AppIds", []):
            if app_id not in seen:
                failures.append("App preset {} references unknown AppId {}".format(
                    preset.get("Name"), app_id))
    return failures


def gate_regfile_format():
    failures = []
    for root, _, files in os.walk(REGFILES):
        for fn in files:
            if not fn.lower().endswith(".reg"):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO_ROOT)
            b = open(path, "rb").read()
            if b[:2] != b"\xff\xfe":
                failures.append("{}: not UTF-16LE with BOM".format(rel))
                continue
            txt = b[2:].decode("utf-16-le")
            non_empty = [l.strip() for l in txt.split("\n")
                         if l.strip() and not l.strip().startswith(";")]
            if not non_empty or not non_empty[0].startswith("Windows Registry Editor Version"):
                failures.append("{}: missing registry header".format(rel))
                continue
            if "\r" not in txt:
                failures.append("{}: not CRLF line endings".format(rel))
            if not any(l.startswith("[") for l in non_empty):
                failures.append("{}: no registry sections".format(rel))
    return failures


def gate_switch_uniqueness():
    failures = []
    for label, path in (("Win11Debloat.ps1", MAIN_SCRIPT), ("Get.ps1", LAUNCHER)):
        text = read_text(path)
        m = re.search(r"param\s*\(", text)
        if not m:
            continue
        start = m.end() - 1
        depth = 0
        i = start
        end = len(text)
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        block = text[start:end]
        names = re.findall(r"\]\s*\$(\w+)", block)
        dupes = sorted({n for n in names if names.count(n) > 1})
        if dupes:
            failures.append("{}: duplicate parameter(s): {}".format(label, ", ".join(dupes)))
    return failures


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="Verify Win11Debloat catalogue/regfile/CLI/docs consistency "
                    "without a PowerShell runtime. Mirrors the Pester gate suite "
                    "(Tests/CatalogParity.Tests.ps1 and friends).")
    parser.add_argument("--json", action="store_true",
                        help="emit a machine-readable JSON report instead of text")
    parser.add_argument("--gate", help="run only the named gate")
    args = parser.parse_args()

    catalog = load_features()
    all_gates = [
        ("Catalogue integrity", gate_catalogue_integrity(catalog)),
        ("Apply/undo parity", gate_apply_undo_parity(catalog)),
        ("Sysprep parity", gate_sysprep_parity(catalog)),
        ("Collision check", gate_collision(catalog)),
        ("CLI surface parity", gate_cli_parity(catalog)),
        ("Docs parity", gate_docs_parity(catalog)),
        ("Preset validation", gate_preset_validation(catalog)),
        ("App catalogue integrity", gate_app_catalogue_integrity()),
        ("Regfile format", gate_regfile_format()),
        ("Switch uniqueness", gate_switch_uniqueness()),
    ]
    gates = [(t, f) for (t, f) in all_gates if not args.gate or t == args.gate]

    if args.json:
        report = {
            "repoRoot": REPO_ROOT,
            "gates": [
                {"name": t, "passed": not f, "failures": f} for (t, f) in gates
            ],
        }
        report["passed"] = all(g["passed"] for g in report["gates"])
        report["failureCount"] = sum(len(g["failures"]) for g in report["gates"])
        print(json.dumps(report, indent=2))
        sys.exit(0 if report["passed"] else 1)

    total = 0
    for title, failures in gates:
        if failures:
            total += len(failures)
            print("FAIL  {} ({} issue(s))".format(title, len(failures)))
            for f in failures:
                print("        - " + f)
        else:
            print("PASS  {}".format(title))
    print()
    if total:
        print("{} gate failure(s).".format(total))
        sys.exit(1)
    print("All gates green.")
    sys.exit(0)


if __name__ == "__main__":
    main()
