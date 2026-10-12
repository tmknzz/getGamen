#!/usr/bin/env python3
"""Embed a separately identified, background-only automation host before signing."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys

binary, app, metadata = map(Path, sys.argv[1:4])
helper = app / 'Contents/Helpers/GetGamenAutomation.app'
macos = helper / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, macos / 'getGamenAutomation')
with metadata.open('rb') as stream:
    parent = plistlib.load(stream)
info = {
    'CFBundleIdentifier': 'com.tmknzz.getGamen.automation',
    'CFBundleName': 'GetGamen Automation',
    'CFBundleExecutable': 'getGamenAutomation',
    'CFBundlePackageType': 'APPL',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleShortVersionString': parent['CFBundleShortVersionString'],
    'CFBundleVersion': parent['CFBundleVersion'],
    'LSMinimumSystemVersion': '14.0',
    'LSBackgroundOnly': True,
    'NSPrincipalClass': 'NSApplication',
}
with (helper / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
identity = os.environ.get('GETGAMEN_SIGN_IDENTITY') or os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
args = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
if identity != '-':
    args.append('--timestamp')
subprocess.run([*args, str(helper)], check=True)
