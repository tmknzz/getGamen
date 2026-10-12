#!/usr/bin/env python3
"""Interactive regression: keep MCP alive while launching/reopening a built GUI.

Run with the GUI closed and no old-version MCP process running. Leaves the GUI
open. Uses NSRunningApplication to check the actual registered process identity.
"""
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
binary = app / 'Contents/MacOS/getGamen'
with tempfile.TemporaryDirectory(prefix='getgamen-launch-') as directory:
    root = Path(directory)
    source = root / 'identity.swift'
    probe = root / 'identity'
    source.write_text('''import AppKit
import Foundation
let args = CommandLine.arguments
let apps: [NSRunningApplication]
if args.count > 1, let pid = Int32(args[1]) {
    apps = NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
} else {
    apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.tmknzz.getGamen" }
}
let result = apps.map { ["pid": $0.processIdentifier, "bundle": $0.bundleIdentifier ?? "", "path": $0.bundleURL?.path ?? "", "finished": $0.isFinishedLaunching, "policy": $0.activationPolicy.rawValue] as [String: Any] }
print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''')
    subprocess.run(['swiftc', str(source), '-o', str(probe)], check=True)

    def identities(*args):
        return json.loads(subprocess.check_output([str(probe), *map(str, args)], text=True))

    assert not identities(), 'Close the GUI and stop old GUI-identity MCP processes before testing'
    server = subprocess.Popen([str(binary), 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def request(i, method, params):
        server.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}) + '\n').encode())
        server.stdin.flush()
        assert select.select([server.stdout], [], [], 15)[0], 'MCP timed out'
        response = json.loads(server.stdout.readline())
        assert response['id'] == i and 'result' in response, response
        return response['result']

    try:
        request(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'launch-regression', 'version': '1'}})
        server.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        server.stdin.flush()
        assert not request(2, 'tools/call', {'name': 'status'})['isError']
        helper = identities(server.pid)
        assert len(helper) == 1 and helper[0]['bundle'] == 'com.tmknzz.getGamen.automation', helper
        assert helper[0]['policy'] == 2, helper  # prohibited; no Dock app
        assert not identities(), 'MCP registered under the GUI identity'
        subprocess.run(['open', '-a', str(app)], check=True)
        deadline = time.monotonic() + 15
        while True:
            gui = identities()
            if gui and all(item['finished'] for item in gui):
                break
            assert time.monotonic() < deadline, gui
            time.sleep(0.2)
        assert len(gui) == 1 and gui[0]['path'] == str(app), gui
        assert gui[0]['pid'] != server.pid, gui
        subprocess.run(['open', '-a', str(app)], check=True)
        assert [x['pid'] for x in identities()] == [gui[0]['pid']], 'Reopen started a duplicate GUI'
        assert not request(3, 'tools/call', {'name': 'status'})['isError']
        server.stdin.close()
        assert server.wait(timeout=10) == 0
        assert identities()[0]['pid'] == gui[0]['pid'], 'MCP exit closed the GUI'
        print('PASS: distinct helper identity; GUI cold launch/reopen during MCP; MCP EOF leaves GUI alive')
    finally:
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=10)
