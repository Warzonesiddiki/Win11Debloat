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

# (winforge id, FeatureId, Win11Debloat category Name, Label, apply reg base, undo reg base)
# Apply/undo text is derived from the FeatureId prefix in derive_texts().
CURATED = [
    # Network & Security
    ('net-qos', 'ConfigureQosReservation', 'Network & Security', 'QoS reservation',
     'Configure_QoS_Reservation', 'Default_QoS_Reservation'),
    ('net-throttling', 'DisableNetworkThrottling', 'Network & Security', 'network throttling',
     'Disable_Network_Throttling', 'Enable_Network_Throttling'),

    # Privacy & Suggested Content
    ('atlas-disable-msrt-telemetry', 'DisableMsrtTelemetry', 'Privacy & Suggested Content',
     'MSRT telemetry', 'Disable_MSRT_Telemetry', 'Enable_MSRT_Telemetry'),

    # Appearance
    ('atlas-best-wallpaper-quality', 'SetBestWallpaperQuality', 'Appearance', 'best wallpaper quality',
     'Set_Best_Wallpaper_Quality', 'Set_Balanced_Wallpaper_Quality'),
    ('atlas-disable-warning-sounds', 'DisableWarningSounds', 'Appearance', 'warning sounds',
     'Disable_Warning_Sounds', 'Enable_Warning_Sounds'),
    ('atlas-disable-check-boxes', 'DisableItemCheckboxes', 'Appearance', 'item checkboxes in Explorer',
     'Disable_Item_Checkboxes', 'Enable_Item_Checkboxes'),
    ('atlas-disable-menu-delay', 'DisableMenuDelay', 'Appearance', 'menu open delay',
     'Disable_Menu_Delay', 'Enable_Menu_Delay'),
    ('atlas-hide-disabled-disconnected-sounds', 'HideDisconnectedSounds', 'Appearance',
     'disconnected and invalid sounds', 'Hide_Disconnected_Sounds', 'Show_Disconnected_Sounds'),
    ('atlas-remove-shortcut-text', 'RemoveShortcutSuffix', 'Appearance',
     'the shortcut suffix on new shortcuts', 'Remove_Shortcut_Text', 'Restore_Shortcut_Text'),
    ('atlas-blue-tooltips', 'EnableBlueTooltips', 'Appearance', 'classic blue tooltips',
     'Enable_Blue_Tooltips', 'Disable_Blue_Tooltips'),
    ('winutil-wpftogglescrollbars', 'DisableOverlayScrollbars', 'Appearance', 'overlay scrollbars',
     'Disable_Overlay_Scrollbars', 'Enable_Overlay_Scrollbars'),
    ('winutil-wpftoggleloginblur', 'DisableLoginBlur', 'Appearance', 'login screen blur',
     'Disable_Login_Blur', 'Enable_Login_Blur'),
    ('winutil-wpftogglebatterypercentage', 'ShowBatteryPercentage', 'Appearance',
     'battery percentage on the taskbar', 'Show_Battery_Percentage', 'Hide_Battery_Percentage'),

    # Other (Quality of Life)
    ('atlas-disable-store-auto-updates', 'DisableStoreAutoUpdates', 'Other', 'Store auto-updates',
     'Disable_Store_Auto_Updates', 'Enable_Store_Auto_Updates'),
    ('atlas-disable-usb-issues-notifications', 'DisableUsbNotifications', 'Other', 'USB issue notifications',
     'Disable_USB_Notifications', 'Enable_USB_Notifications'),
    ('atlas-disable-win11-settings-banner', 'DisableSettingsBanner', 'Other', 'Settings app banner',
     'Disable_Settings_Banner', 'Enable_Settings_Banner'),
    ('atlas-always-more-details-transfer', 'ShowMoreDetailsOnTransfer', 'Other',
     'more details on file transfers', 'Show_More_Details_Transfer', 'Show_Less_Details_Transfer'),
    ('atlas-disable-invalid-shortcuts-search', 'DisableInvalidShortcutSearch', 'Other',
     'searching for broken shortcuts', 'Disable_Invalid_Shortcut_Search', 'Enable_Invalid_Shortcut_Search'),
    ('atlas-dont-show-office-files', 'HideOfficeFilesInQuickAccess', 'Other', 'Office files in Quick Access',
     'Hide_Office_Files', 'Show_Office_Files'),
    ('atlas-full-context-on-more-than-15-items', 'AlwaysFullContextMenu', 'Other', 'the full context menu',
     'Always_Full_Context_Menu', 'Default_Context_Menu'),
    ('atlas-hide-frequently-used-items', 'HideFrequentItems', 'Other', 'frequently used items in Explorer',
     'Hide_Frequent_Items', 'Show_Frequent_Items'),
    ('atlas-minimize-mouse-hover-time', 'MinimizeMouseHoverTime', 'Other', 'mouse hover delay',
     'Minimize_Mouse_Hover_Time', 'Default_Mouse_Hover_Time'),
    ('atlas-no-internet-open-with', 'DisableInternetOpenWith', 'Other', 'web results in Open With',
     'Disable_Internet_Open_With', 'Enable_Internet_Open_With'),
    ('atlas-cast-to-device', 'RemoveCastToDevice', 'Other', 'Cast to Device from the context menu',
     'Remove_Cast_To_Device', 'Add_Cast_To_Device'),
    ('atlas-disable-touch-visual-feedback', 'DisableTouchVisualFeedback', 'Other', 'touch visual feedback',
     'Disable_Touch_Visual_Feedback', 'Enable_Touch_Visual_Feedback'),
    ('atlas-show-more-pins', 'ShowMorePins', 'Other', 'more pins in Start',
     'Show_More_Pins', 'Show_Fewer_Pins'),
    ('atlas-show-all-tasks-control-panel', 'ShowAllControlPanelTasks', 'Other', 'all tasks in Control Panel',
     'Show_All_Control_Panel_Tasks', 'Default_Control_Panel_Tasks'),
    ('atlas-decrease-shutdown-time', 'DecreaseShutdownTime', 'Other', 'shutdown timeout',
     'Decrease_Shutdown_Time', 'Default_Shutdown_Time'),
    ('atlas-enable-verbose-messages', 'EnableVerboseMessages', 'Other',
     'verbose startup and shutdown messages', 'Enable_Verbose_Messages', 'Disable_Verbose_Messages'),
    ('atlas-force-end-shutdown-apps', 'ForceEndShutdownApps', 'Other', 'force apps to close on shutdown',
     'Force_End_Shutdown_Apps', 'Default_End_Shutdown_Apps'),
    ('atlas-crash-control-qol', 'ConfigureCrashControl', 'Other', 'crash dump settings',
     'Configure_Crash_Control', 'Default_Crash_Control'),
    ('atlas-cmd-win-x', 'WinXOpensCommandPrompt', 'Other', 'Command Prompt in the Win+X menu',
     'WinX_Opens_Command_Prompt', 'WinX_Opens_PowerShell'),
    ('atlas-hide-meet-now', 'HideMeetNow', 'Other', 'Meet Now in the taskbar',
     'Hide_Meet_Now', 'Show_Meet_Now'),
    ('atlas-do-not-reduce-sounds', 'DisableSoundReduction', 'Other', 'sound scheme quality reduction',
     'Disable_Sound_Reduction', 'Enable_Sound_Reduction'),
    ('winutil-wpftoggledetailedbsod', 'EnableDetailedBsod', 'Other', 'detailed BSOD information',
     'Enable_Detailed_Bsod', 'Disable_Detailed_Bsod'),
    ('winutil-wpftogglegamemode', 'EnableGameMode', 'Other', 'Game Mode',
     'Enable_Game_Mode', 'Disable_Game_Mode'),
    ('winutil-wpftogglenewoutlook', 'DisableNewOutlook', 'Other', 'new Outlook toggle',
     'Disable_New_Outlook', 'Enable_New_Outlook'),
    ('winutil-wpftogglenumlock', 'EnableNumLockOnBoot', 'Other', 'NumLock on boot',
     'Enable_NumLock_On_Boot', 'Disable_NumLock_On_Boot'),
    ('winutil-wpftoggles3sleep', 'EnableS3Sleep', 'Other', 'S3 sleep support',
     'Enable_S3_Sleep', 'Disable_S3_Sleep'),
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


def derive_texts(fid, label):
    low = label[0].lower() + label[1:] if label else label
    if fid.startswith('Disable'):
        return ('Disabling ' + low, 'Enabling ' + low)
    if fid.startswith('Enable'):
        return ('Enabling ' + low, 'Disabling ' + low)
    if fid.startswith('Hide'):
        return ('Hiding ' + low, 'Showing ' + low)
    if fid.startswith('Show'):
        return ('Showing ' + low, 'Hiding ' + low)
    if fid.startswith('Remove'):
        return ('Removing ' + low, 'Adding ' + low)
    if fid.startswith('Set') or fid.startswith('Use') or fid.startswith('Configure'):
        return ('Configuring ' + low, 'Restoring default ' + low)
    return ('Applying ' + low, 'Reverting ' + low)


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
    for (wf_id, fid, cat_name, label, reg_base, undo_base) in CURATED:
        apply_text, undo_text = derive_texts(fid, label)
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
