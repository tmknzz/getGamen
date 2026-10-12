#!/usr/bin/env python3
"""Reserve a daily build identifier and stamp an independent bundle plist."""
import argparse
import datetime
import fcntl
import os
from pathlib import Path
import plistlib
import re
import tempfile
from zoneinfo import ZoneInfo


def next_number(previous, day):
    datetime.datetime.strptime(day, '%Y%m%d')
    if previous is None:
        index = 0
    else:
        if not re.fullmatch(r'\d{8}[A-Z]{2}', previous):
            raise ValueError('Invalid previous build number')
        if previous[:8] > day:
            raise ValueError('Build date moved backwards')
        index = ((ord(previous[8]) - 65) * 26 + ord(previous[9]) - 65 + 1) if previous[:8] == day else 0
    if index >= 676:
        raise ValueError('Daily AA–ZZ build sequence exhausted')
    return day + chr(65 + index // 26) + chr(65 + index % 26), index + 1


def atomic_plist(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.build-plist-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            plistlib.dump(data, stream, sort_keys=False)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def stamp(source, output):
    # Keep the lock outside .build so SwiftPM clean cannot break serialization.
    with (source.parent / '.build-number.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        info = plistlib.loads(source.read_bytes())
        day = datetime.datetime.now(ZoneInfo('Asia/Tokyo')).strftime('%Y%m%d')
        number, sequence = next_number(info.get('getGamenBuildNumber'), day)
        info['getGamenBuildNumber'] = number
        # Keep the OS bundle version numeric; the requested display ID is separate.
        info['CFBundleVersion'] = f'{day}.{sequence}'
        atomic_plist(source, info)
        atomic_plist(output, info)
        return number


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        parser.error('Output must be separate from source')
    print(stamp(args.source, args.output))
