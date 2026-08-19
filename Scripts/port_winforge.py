#!/usr/bin/env python3
"""Harvest a curated, defensible subset of winforge tweaks into Win11Debloat.

Only winforge tweaks whose operations are expressible as registry .reg files
(registry_set_dword / registry_set_string / registry_delete) are ported, because
Win11Debloat's schema v2 for services/tasks/power is not built yet. Each ported
tweak gets the full six-artifact treatment required by the catalogue contract:

  1. Regfiles/<Apply>.reg
  2. Regfiles/Sysprep/<Apply>.reg   (HKCU -> hkey_users\\default)
  3. Regfiles/Undo/<Undo>.reg        (mirrors winforge's revert operations)
  4. Config/Features.json entry
  5. [switch] in Win11Debloat.ps1 and Scripts/Get.ps1
  6. Regenerated docs/FEATURES.md

Triage rules applied before a tweak is eligible:
  - reversible == true (winforge authored a revert)
  - risk in {low, medium}  (high needs benchmark/CVE evidence)
  - not in the explicit reject list (mDNS, NCSI probe, machine-wide camera/mic
    denial, diagnostic-data-viewer, Nagle) and not a security-weakening change
  - not duplicating an existing Win11Debloat feature's intent
The Windows-runtime execution of these is still required before shipping; this
script only guarantees internal catalogue consistency, which verify_catalogue.py
enforces afterwards.
"""

import json
import os
import re

REPO = r'C:\Users\Tahir\Documents\GitHub\Win11Debloat'
WF = r'C:\Users\Tahir\Documents\GitHub\winforge\config\tweaks.json'

wf_tweaks = {t['id']: t for t in json.load(open(WF, encoding='utf-8'))['tweaks']}
cat = json.load(open(os.path.join(REPO, 'Config', 'Features.json'), encoding='utf-8-sig'))
existing_features = cat['Features']
existing_ids = {f['FeatureId'] for f in existing_features}
existing_regfiles = set(os.listdir(os.path.join(REPO, 'Regfiles')))

# (winforge id, FeatureId, Win11Debloat category Name, Label, ApplyText, UndoText,
#  apply reg base, undo reg base)
CURATED = [
    ('atlas-disable-nvidia-telemetry', 'DisableNvidiaTelemetry', 'Privacy & Suggested Content',
     'Disable NVIDIA telemetry', 'Disabling NVIDIA telemetry', 'Enabling NVIDIA telemetry',
     'Disable_Nvidia_Telemetry', 'Enable_Nvidia_Telemetry'),
    ('atlas-config-app-permissions', 'DenyAppPermissions', 'Privacy & Suggested Content',
     'Deny app access to diagnostics, location and account info', 'Denying app permissions',
     'Allowing app permissions', 'Deny_App_Permissions', 'Allow_App_Permissions'),
    ('atlas-disable-device-monitoring', 'DisableDeviceMonitoring', 'Privacy & Suggested Content',
     'Disable device monitoring', 'Disabling device monitoring', 'Enabling device monitoring',
     'Disable_Device_Monitoring', 'Enable_Device_Monitoring'),
    ('atlas-disable-pca', 'DisableProgramCompatibilityAssistant', 'Privacy & Suggested Content',
     'Disable Program Compatibility Assistant telemetry', 'Disabling PCA telemetry',
     'Enabling PCA telemetry', 'Disable_PCA', 'Enable_PCA'),
    ('atlas-disable-perf-track', 'DisableCustomerExperienceImprovement', 'Privacy & Suggested Content',
     'Disable Customer Experience Improvement tracking', 'Disabling CEIP tracking',
     'Enabling CEIP tracking', 'Disable_CEIP_Tracking', 'Enable_CEIP_Tracking'),
    ('atlas-disable-privacy-experience', 'DisablePrivacyExperience', 'Privacy & Suggested Content',
     'Disable the Windows privacy experience', 'Disabling privacy experience',
     'Enabling privacy experience', 'Disable_Privacy_Experience', 'Enable_Privacy_Experience'),
    ('atlas-disable-rsop-logging', 'DisableRsopLogging', 'Privacy & Suggested Content',
     'Disable Resultant Set of Policy logging', 'Disabling RSOP logging',
     'Enabling RSOP logging', 'Disable_RSOP_Logging', 'Enable_RSOP_Logging'),
    ('atlas-disable-user-tracking', 'DisableUserTracking', 'Privacy & Suggested Content',
     'Disable user activity tracking', 'Disabling user tracking', 'Enabling user tracking',
     'Disable_User_Tracking', 'Enable_User_Tracking'),
    ('atlas-disallow-ms-accounts', 'DisallowMicrosoftAccounts', 'Privacy & Suggested Content',
     'Disallow Microsoft account sign-in', 'Disallowing Microsoft accounts',
     'Allowing Microsoft accounts', 'Disallow_Microsoft_Accounts', 'Allow_Microsoft_Accounts'),
    ('atlas-disable-activation-telemetry', 'DisableActivationTelemetry', 'Privacy & Suggested Content',
     'Disable Windows activation telemetry', 'Disabling activation telemetry',
     'Enabling activation telemetry', 'Disable_Activation_Telemetry', 'Enable_Activation_Telemetry'),
    ('atlas-disable-diagnostic-tracing', 'DisableDiagnosticTracing', 'Privacy & Suggested Content',
     'Disable diagnostic tracing (DiagTrack)', 'Disabling diagnostic tracing',
     'Enabling diagnostic tracing', 'Disable_Diagnostic_Tracing', 'Enable_Diagnostic_Tracing'),

    ('net-doh', 'EnableDnsOverHttps', 'Network & Security',
     'Enable DNS over HTTPS (DoH)', 'Enabling DNS over HTTPS', 'Disabling DNS over HTTPS',
     'Enable_DNS_Over_HTTPS', 'Disable_DNS_Over_HTTPS'),
    ('atlas-disable-smb-bandwidth-throttling', 'DisableSmbBandwidthThrottling', 'Network & Security',
     'Disable SMB bandwidth throttling', 'Disabling SMB throttling',
     'Enabling SMB throttling', 'Disable_SMB_Throttling', 'Enable_SMB_Throttling'),

    ('exp-hide-recent', 'HideRecentFiles', 'File Explorer',
     'Hide recent files in Quick Access', 'Hiding recent files', 'Showing recent files',
     'Hide_Recent_Files', 'Show_Recent_Files'),
    ('exp-thumbnail-cache', 'SetThumbnailCacheSize', 'File Explorer',
     'Optimise the thumbnail cache size', 'Configuring thumbnail cache',
     'Restoring default thumbnail cache', 'Set_Thumbnail_Cache_Size', 'Default_Thumbnail_Cache_Size'),

    ('atlas-disable-dynamic-lighting', 'DisableDynamicLighting', 'Appearance',
     'Disable Dynamic Lighting (HID lighting)', 'Disabling Dynamic Lighting',
     'Enabling Dynamic Lighting', 'Disable_Dynamic_Lighting', 'Enable_Dynamic_Lighting'),
    ('atlas-visual-effects', 'DisableVisualEffects', 'Appearance',
     'Disable visual effects for best performance', 'Disabling visual effects',
     'Enabling visual effects', 'Disable_Visual_Effects', 'Enable_Visual_Effects'),
    ('atlas-disable-aero-shake', 'DisableAeroShake', 'Appearance',
     'Disable Aero Shake', 'Disabling Aero Shake', 'Enabling Aero Shake',
     'Disable_Aero_Shake', 'Enable_Aero_Shake'),
    ('atlas-disable-desktop-peek', 'DisableDesktopPeek', 'Appearance',
     'Disable desktop peek (Aero Peek)', 'Disabling desktop peek', 'Enabling desktop peek',
     'Disable_Desktop_Peek', 'Enable_Desktop_Peek'),
    ('atlas-use-compact-mode', 'UseCompactModeExplorer', 'Appearance',
     'Use compact mode in File Explorer', 'Enabling compact mode', 'Disabling compact mode',
     'Use_Compact_Mode', 'Use_Ribbon_Mode'),

    ('atlas-disable-resume', 'DisableCrossDeviceResume', 'Other',
     'Disable Cross-Device Resume', 'Disabling Cross-Device Resume', 'Enabling Cross-Device Resume',
     'Disable_Cross_Device_Resume', 'Enable_Cross_Device_Resume'),
    ('atlas-disable-settings-tips', 'DisableSettingsTips', 'Other',
     'Disable tips in the Settings app', 'Disabling Settings tips', 'Enabling Settings tips',
     'Disable_Settings_Tips', 'Enable_Settings_Tips'),
    ('atlas-enable-long-paths', 'EnableLongPaths', 'Other',
     'Enable long file paths (NTFS)', 'Enabling long paths', 'Disabling long paths',
     'Enable_Long_Paths', 'Disable_Long_Paths'),
    ('atlas-classic-search', 'UseClassicSearch', 'Other',
     'Use classic search in File Explorer', 'Enabling classic search', 'Disabling classic search',
     'Use_Classic_Search', 'Use_Modern_Search'),
    ('atlas-disable-nearby-sharing', 'DisableNearbySharing', 'Other',
     'Disable Nearby Sharing', 'Disabling Nearby Sharing', 'Enabling Nearby Sharing',
     'Disable_Nearby_Sharing', 'Enable_Nearby_Sharing'),
    ('atlas-disable-news-and-interests', 'DisableNewsAndInterests', 'Other',
     'Disable News and Interests', 'Disabling News and Interests', 'Enabling News and Interests',
     'Disable_News_And_Interests', 'Enable_News_And_Interests'),
    ('atlas-disable-tablet-mode', 'DisableTabletMode', 'Other',
     'Disable Tablet Mode', 'Disabling Tablet Mode', 'Enabling Tablet Mode',
     'Disable_Tablet_Mode', 'Enable_Tablet_Mode'),
    ('atlas-disable-low-disk-warning', 'DisableLowDiskWarning', 'Other',
     'Disable low disk space warnings', 'Disabling low disk warnings', 'Enabling low disk warnings',
     'Disable_Low_Disk_Warning', 'Enable_Low_Disk_Warning'),
    ('atlas-disable-startup-delay', 'DisableStartupDelay', 'Other',
     'Disable startup delay for apps', 'Disabling startup delay', 'Enabling startup delay',
     'Disable_Startup_Delay', 'Enable_Startup_Delay'),
    ('atlas-disable-wpbt', 'DisableWpbt', 'Other',
     'Disable WPBT (firmware-injected binaries)', 'Disabling WPBT', 'Enabling WPBT',
     'Disable_WPBT', 'Enable_WPBT'),
]


def hive_to_reg(hive):
    return {'HKCU': 'HKEY_CURRENT_USER', 'HKLM': 'HKEY_LOCAL_MACHINE',
            'HKCR': 'HKEY_CLASSES_ROOT', 'HKU': 'HKEY_USERS',
            'HKCC': 'HKEY_CURRENT_CONFIG'}.get(hive.upper(), hive.upper())


def op_to_line(op):
    """Translate a winforge operation into a .reg value line."""
    if op['type'] == 'registry_delete':
        name = '@' if not op.get('name') else '"{}"'.format(op['name'])
        return '{}=-'.format(name)
    name = '@' if not op.get('name') else '"{}"'.format(op['name'])
    if op['type'] == 'registry_set_dword':
        return '{}=dword:{:08x}'.format(name, int(op['value']))
    if op['type'] == 'registry_set_string':
        val = str(op['value']).replace('"', '\\"')
        return '{}={}'.format(name, '"' + val + '"')
    raise ValueError('unsupported op type {}'.format(op['type']))


def build_reg(operations, is_sysprep):
    """Return .reg file content (without BOM) for the given operations."""
    sections = {}
    order = []
    for op in operations:
        hive = hive_to_reg(op['hive'])
        key = '{}\\{}'.format(hive, op['path'])
        if is_sysprep and key.upper().startswith('HKEY_CURRENT_USER\\'):
            key = 'hkey_users\\default\\' + key[len('HKEY_CURRENT_USER\\'):]
        if key not in sections:
            sections[key] = []
            order.append(key)
        sections[key].append(op_to_line(op))
    lines = ['Windows Registry Editor Version 5.00', '']
    for key in order:
        lines.append('[{}]'.format(key))
        lines.extend(sections[key])
        lines.append('')
    return '\r\n'.join(lines) + '\r\n'


def write_reg(path, content):
    with open(path, 'wb') as fh:
        fh.write(b'\xff\xfe')  # UTF-16LE BOM
        fh.write(content.encode('utf-16-le'))


def insert_into_param_block(path, new_lines):
    text = open(path, encoding='utf-8').read()
    eol = '\r\n' if '\r\n' in text else '\n'
    m = re.search(r'param\s*\(', text)
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    # i points at the closing ')'. Match the file's line ending and keep the
    # comma-separated style used by the existing parameters.
    prefix = text[:i].rstrip('\r\n')
    body = eol.join(
        '    ' + l + (',' if k < len(new_lines) - 1 else '')
        for k, l in enumerate(new_lines))
    insert = ',' + eol + body + eol
    new_text = prefix + insert + text[i:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(new_text)


def feature_json_entry(fid, label, category, apply_text, undo_text, reg_base, undo_base):
    return (
        '    {{\n'
        '      "FeatureId": "{}",\n'
        '      "Label": "{}",\n'
        '      "Category": "{}",\n'
        '      "RegistryKey": "{}.reg",\n'
        '      "ApplyText": "{}",\n'
        '      "UndoLabel": "{}",\n'
        '      "ApplyUndoText": "{}",\n'
        '      "RegistryUndoKey": "{}.reg",\n'
        '      "MinVersion": null,\n'
        '      "MaxVersion": null\n'
        '    }}'
    ).format(fid, label, category, reg_base, apply_text, undo_text, apply_text, undo_base)


def append_features_json(new_entries):
    path = os.path.join(REPO, 'Config', 'Features.json')
    content = open(path, encoding='utf-8-sig').read()
    marker = '\n  ]\n}'
    idx = content.rfind(marker)
    if idx == -1:
        raise RuntimeError('could not find Features array close')
    block = ',\n' + ',\n'.join(new_entries)
    new_content = content[:idx] + block + content[idx:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(new_content)


# --- docs regeneration (mirror of Scripts/Build-FeatureDocs.ps1) ---
def documented_ops(path):
    try:
        text = open(path, encoding='utf-16').read()
    except Exception:
        text = open(path, encoding='utf-8').read()
    ops = []
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(';') or line.startswith('Windows Registry Editor Version'):
            continue
        m = re.match(r'^\[(-)?(.*)\]$', line)
        if m:
            cur = m.group(2).strip()
            continue
        if cur is None:
            continue
        vm = re.match(r'^(@|"[^"]+")\s*=\s*(.+)$', line)
        if vm:
            vn = '(Default)' if vm.group(1) == '@' else vm.group(1).strip('"')
            data = vm.group(2).strip()
            if data == '-':
                data = 'the value is deleted'
            elif re.match(r'^dword:[0-9a-fA-F]+$', data):
                data = str(int(data.split(':', 1)[1], 16))
            ops.append((cur, vn, data))
    return ops


def anchor(heading):
    a = heading.lower()
    a = re.sub(r'[^a-z0-9 -]', '', a)
    a = a.replace(' ', '-')
    return a


def generate_docs():
    features = json.load(open(os.path.join(REPO, 'Config', 'Features.json'), encoding='utf-8-sig'))['Features']
    categories = json.load(open(os.path.join(REPO, 'Config', 'Features.json'), encoding='utf-8-sig'))['Categories']
    cat_names = [c['Name'] for c in categories]
    used = [f['Category'] for f in features if f.get('Category')]
    ordered = [c for c in cat_names if c in used] + [c for c in used if c not in cat_names]
    uncatted = [f for f in features if not f.get('Category')]

    L = []
    L.append('# Win11Debloat feature reference')
    L.append('')
    L.append('> Generated by `Scripts/Build-FeatureDocs.ps1` from `Config/Features.json` and the')
    L.append('> `Regfiles/` corpus. Do not edit by hand - rerun the script after changing a feature.')
    L.append('')
    L.append('This reference lists every setting Win11Debloat can apply, the command-line switch that')
    L.append('selects it, and the exact registry values it writes, so you can see precisely what a')
    L.append('setting does before you run it.')
    L.append('')
    L.append('{} settings across {} categories.'.format(len(features), len(ordered)))
    L.append('')
    L.append('## Contents')
    L.append('')
    for c in ordered:
        n = len([f for f in features if f.get('Category') == c])
        L.append('- [{}](#{}) ({})'.format(c, anchor(c), n))
    if uncatted:
        L.append('- [Other settings](#other-settings) ({})'.format(len(uncatted)))
    L.append('')

    def section(f):
        L.append('### {}'.format(f['Label']))
        L.append('')
        L.append('`-{}`'.format(f['FeatureId']))
        L.append('')
        if f.get('MinVersion') or f.get('MaxVersion'):
            L.append('*Version-gated setting.*')
            L.append('')
        if not f.get('RegistryKey'):
            L.append('This setting is applied by dedicated logic in the script rather than by a registry file.')
            L.append('')
            return
        ap = os.path.join(REPO, 'Regfiles', f['RegistryKey'])
        if not os.path.exists(ap):
            L.append('Registry file `{}` is missing from the repository.'.format(f['RegistryKey']))
            L.append('')
            return
        L.append('Registry changes (`{}`):'.format(f['RegistryKey']))
        L.append('')
        L.append('| Key | Value | Set to |')
        L.append('| --- | --- | --- |')
        for key, vn, data in documented_ops(ap):
            vc = '`{}`'.format(vn) if vn else ''
            L.append('| `{}` | {} | {} |'.format(key, vc, data))
        L.append('')
        if f.get('RegistryUndoKey'):
            L.append('Reverting: unchecking this setting applies `{}`.'.format(f['RegistryUndoKey']))
        else:
            L.append('Reverting: this setting has no undo file and cannot be reverted by the script.')
        sp = os.path.join(REPO, 'Regfiles', 'Sysprep', f['RegistryKey'])
        if os.path.exists(sp):
            L.append('')
            L.append('New user profiles: covered when running in Sysprep mode.')
        L.append('')

    for c in ordered:
        L.append('## {}'.format(c))
        L.append('')
        for f in [x for x in features if x.get('Category') == c]:
            section(f)
    if uncatted:
        L.append('## Other settings')
        L.append('')
        L.append('These are selected through dedicated command-line switches rather than the settings list.')
        L.append('')
        for f in uncatted:
            section(f)

    out = os.path.join(REPO, 'docs', 'FEATURES.md')
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(L) + '\n')


def main():
    new_feature_entries = []
    new_switches = []
    for (wf_id, fid, cat_name, label, apply_text, undo_text, reg_base, undo_base) in CURATED:
        assert fid not in existing_ids, 'FeatureId collision: ' + fid
        assert reg_base + '.reg' not in existing_regfiles, 'regfile collision: ' + reg_base
        t = wf_tweaks[wf_id]
        apply_content = build_reg(t['operations'], is_sysprep=False)
        undo_content = build_reg(t.get('revert', []), is_sysprep=False)
        sysprep_content = build_reg(t['operations'], is_sysprep=True)
        write_reg(os.path.join(REPO, 'Regfiles', reg_base + '.reg'), apply_content)
        write_reg(os.path.join(REPO, 'Regfiles', 'Undo', undo_base + '.reg'), undo_content)
        write_reg(os.path.join(REPO, 'Regfiles', 'Sysprep', reg_base + '.reg'), sysprep_content)
        new_feature_entries.append(
            feature_json_entry(fid, label, cat_name, apply_text, undo_text, reg_base, undo_base))
        new_switches.append('[switch]${}'.format(fid))

    append_features_json(new_feature_entries)
    insert_into_param_block(os.path.join(REPO, 'Win11Debloat.ps1'), new_switches)
    insert_into_param_block(os.path.join(REPO, 'Scripts', 'Get.ps1'), new_switches)
    generate_docs()
    print('Ported {} features. Run Scripts/verify_catalogue.py to confirm gates.'.format(len(CURATED)))


if __name__ == '__main__':
    main()
