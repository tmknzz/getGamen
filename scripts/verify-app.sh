#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s APP_BUNDLE NEW_EVIDENCE_DIRECTORY\n' "$0" >&2
    exit 2
fi
bundle_dir="$1"
evidence_dir="$2"
if [[ ! -f "$bundle_dir/Contents/MacOS/getGamen" || -e "$evidence_dir" ]]; then
    printf 'Expected a built getGamen.app and an evidence directory that does not exist.\n' >&2
    exit 2
fi
bundle_dir="$(cd "$bundle_dir" && pwd)"
mkdir -p "$evidence_dir"
evidence_dir="$(cd "$evidence_dir" && pwd)"
plutil -lint "$bundle_dir/Contents/Info.plist"
codesign --verify --strict "$bundle_dir"
xcrun vtool -show-build "$bundle_dir/Contents/MacOS/getGamen" > "$evidence_dir/macho.txt"

python3 -E - "$bundle_dir" "$evidence_dir" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
from pathlib import Path
import json, plistlib, re, sys
bundle, evidence, repo = map(Path, sys.argv[1:])
with (bundle/'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert info['CFBundleExecutable'] == 'getGamen'
assert info['CFBundlePackageType'] == 'APPL'
assert info['CFBundleIdentifier'] == 'com.tmknzz.getGamen'
assert info['LSMinimumSystemVersion'] == '14.0'
assert not info.get('LSUIElement', False), 'Dock presence is required'
assert info['CFBundleShortVersionString'] and info['CFBundleVersion']
versions = re.findall(r'^\s*minos\s+(\S+)', (evidence/'macho.txt').read_text(), re.M)
assert versions and all(v in ('14.0', '14.0.0') for v in versions), versions
intents = json.loads((bundle/'Contents/Resources/Metadata.appintents/extract.actionsdata').read_text())
actions = intents['actions']
def declared(path):
    return set(re.findall(r'^struct (\w+): AppIntent\b', path.read_text(), re.M))
image_actions = declared(repo/'Sources/GetGamen/ImageIntents.swift')
expected = set().union(*(declared(p) for p in (repo/'Sources/GetGamen').glob('*.swift')))
assert image_actions and set(actions) == expected, (sorted(actions), sorted(expected))
def metadata(action, name):
    return json.dumps(next(p for p in actions[action]['parameters'] if p['name'] == name)['typeSpecificMetadata'])
for action in image_actions:
    assert '"public.image"' in metadata(action, 'image'), action
for action, name in (('ConvertImageIntent', 'quality'), ('BorderImageIntent', 'lineWidth'),
                     ('BorderImageIntent', 'cornerRadius'), ('MosaicImageIntent', 'blockSize')):
    assert 'LNValueTypeMetadataKeyNumberUpperBound' in metadata(action, name), (action, name)
print('Bundle metadata, App Intents actions, signature and actual binary minimum OS verified.')
PY

# Launch through the public LaunchServices API and retain only this new instance.
# The helper never searches by app name or terminates other running instances.
swift -warnings-as-errors - "$bundle_dir" "$evidence_dir" <<'SWIFT'
import AppKit
import Foundation

@MainActor
final class LaunchState {
    var application: NSRunningApplication?
    var error: String?
    var completed = false
}

MainActor.assumeIsolated {
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
    let evidence = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let state = LaunchState()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = ["--smoke-output", evidence.path]
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, error in
        let errorDescription = error?.localizedDescription
        DispatchQueue.main.async {
            state.completed = true
            guard let application else {
                state.error = errorDescription ?? "LaunchServices returned no application"
                return
            }
            guard application.bundleURL?.resolvingSymlinksInPath() == bundle else {
                state.error = "LaunchServices returned an unexpected application; it was not terminated"
                return
            }
            state.application = application
        }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(35))
    while clock.now < deadline {
        if state.completed && (state.error != nil || state.application?.isTerminated == true) { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if let application = state.application, !application.isTerminated {
        _ = application.terminate()
        let cleanupDeadline = clock.now.advanced(by: .seconds(2))
        while !application.isTerminated && clock.now < cleanupDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !application.isTerminated { _ = application.forceTerminate() }
        state.error = "Diagnostic launch exceeded its deadline; termination was requested only for its own instance"
    }
    guard state.completed, let application = state.application, state.error == nil else {
        FileHandle.standardError.write(Data(((state.error ?? "LaunchServices completion deadline exceeded") + "\n").utf8))
        exit(1)
    }
    let evidenceObject: [String: Any] = [
        "pid": application.processIdentifier,
        "bundle": bundle.path,
        "terminated": application.isTerminated,
        "launchMethod": "NSWorkspace.openApplication"
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: evidenceObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidence.appendingPathComponent("launch.json"), options: .withoutOverwriting)
    } catch {
        FileHandle.standardError.write(Data("Cannot write launch evidence: \(error)\n".utf8))
        exit(1)
    }
}
SWIFT

python3 -E - "$bundle_dir" "$evidence_dir" <<'PY'
from pathlib import Path
import json, math, plistlib, struct, sys
bundle, evidence = map(Path, sys.argv[1:])
with (bundle/'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
report = json.loads((evidence/'result.json').read_text())
assert report['schemaVersion'] == 1
assert report['passed'] is True and report['errors'] == [], report
assert report['renderingKind'] == 'native-app-view-rendering'
for report_key, plist_key in [('bundleIdentifier','CFBundleIdentifier'), ('minimumOS','LSMinimumSystemVersion'),
                              ('version','CFBundleShortVersionString'), ('build','CFBundleVersion')]:
    assert report[report_key] == info[plist_key], (report_key, report)
assert len(report['windows']) == 2
assert {w['role'] for w in report['windows']} == {'main', 'settings'}
for window in report['windows']:
    assert window['visible'] is True
    assert all(math.isfinite(window[k]) and window[k] > 0 for k in ('width','height'))
    assert window['image'] == window['role'] + '.png'
    data = (evidence/window['image']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR'
    width, height = struct.unpack('>II', data[16:24])
    assert width > 0 and height > 0
launch = json.loads((evidence/'launch.json').read_text())
assert launch['terminated'] is True and launch['pid'] > 0
print(json.dumps(report, ensure_ascii=False, indent=2))
print('Native app launch and both real windows verified; renderings still require visual inspection.')
PY
