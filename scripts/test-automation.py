#!/usr/bin/env python3
"""Black-box CLI/MCP regression checks, using only a generated local fixture.

Run against a debug build: only debug builds honour GETGAMEN_LICENSE_DIR,
which keeps these checks away from the user's real license record.
"""
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import zlib

binary = str(Path(sys.argv[1]).resolve())
def cli(*args, code=0):
    p = subprocess.run([binary, *args], capture_output=True, text=True, timeout=15)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

with tempfile.TemporaryDirectory(prefix='getgamen-automation-') as directory:
    root = Path(directory)
    # Each run starts a fresh trial in its own license record.
    license_dir = root / 'license'
    os.environ['GETGAMEN_LICENSE_DIR'] = str(license_dir)
    source = root / 'source.png'
    source.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 6, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 8) * 6)) + chunk(b'IEND', b''))
    assert 'capture-window' in cli('--help').stdout
    # A shell may supply only a name as argv[0], from an unrelated directory.
    named = subprocess.run(['getGamen', '--help'], executable=binary, cwd=root,
                           capture_output=True, text=True, timeout=15)
    assert named.returncode == 0 and 'capture-window' in named.stdout, named.stderr
    status = json.loads(cli('status').stdout)
    assert 'screen_recording' in status, status
    assert (license_dir / 'license.json').exists(), 'Use a debug build; a release build reads the real license record.'
    assert status['license']['state'] == 'trial', status
    assert len(json.loads(cli('tools').stdout)['tools']) == 7
    invalid = cli('convert', '--input', str(source), '--output', str(root/'bad.jpg'), '--format', 'jpeg', '--quality', '2', code=2)
    assert json.loads(invalid.stderr)['error']['code'] == 'invalid_arguments'
    cli('edit', '--edits', '{', code=2)
    for fmt in ['png', 'png8', 'jpeg']:
        out = root / ('converted.' + fmt)
        result = json.loads(cli('convert', '--input', str(source), '--output', str(out), '--format', fmt).stdout)
        assert (result['width'], result['height']) == (8, 6)
        assert out.stat().st_size == result['bytes']
        cli('convert', '--input', str(source), '--output', str(out), code=1)
    edits = {'crop': {'x': 1, 'y': 1, 'width': 4, 'height': 3},
             'border': {'width': 2, 'color': {'red': 0, 'green': 0, 'blue': 1}}}
    edited = json.loads(cli('edit', '--input', str(source), '--output', str(root/'edited.png'), '--edits', json.dumps(edits)).stdout)
    assert (edited['width'], edited['height']) == (4, 3)
    p = subprocess.Popen([binary, 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    def send(value):
        p.stdin.write(json.dumps(value).encode() + b'\n')
    def receive():
        data = bytearray()
        while True:
            assert select.select([p.stdout], [], [], 10)[0], 'MCP response timed out'
            byte = os.read(p.stdout.fileno(), 1)
            assert byte, ('MCP closed unexpectedly', p.poll())
            if byte == b'\n':
                return json.loads(data)
            data.extend(byte)
    def request(i, method, params=None):
        send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params or {}})
        answer = receive()
        assert answer['id'] == i
        return answer
    try:
        init = request(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'regression', 'version': '1'}})
        assert init['result']['capabilities']['tools'] == {'listChanged': False}
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        assert len(request(2, 'tools/list')['result']['tools']) == 7
        assert request(3, 'tools/call', {'name': 'status'})['result']['isError'] is False
        assert request(4, 'tools/call', {'name': 'missing'})['error']['code'] == -32602
        assert request(5, 'tools/call', {'name': 'convert', 'arguments': {'input': str(source), 'output': str(source)}})['result']['isError'] is True
        result = request(6, 'tools/call', {'name': 'convert', 'arguments': {'input': str(source), 'output': str(root/'mcp.png')}})['result']
        assert not result['isError']
        assert json.loads(result['content'][0]['text'])['width'] == 8
        p.stdin.write(b'not json\n')
        assert receive()['error']['code'] == -32700
        assert request(7, 'ping')['result'] == {}
        # Oversized and split frames must not corrupt the next request.
        p.stdin.write(b'x' * (1_048_576 + 1) + b'\n')
        assert receive()['error']['code'] == -32700
        p.stdin.write(b'{"jsonrpc":"2.0","id":8,')
        p.stdin.write(b'"method":"ping"}\n')
        assert receive() == {'jsonrpc': '2.0', 'id': 8, 'result': {}}
        p.stdin.close()
        assert p.wait(timeout=10) == 0
        assert p.stdout.read() == b''
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
    # After the trial, tools are refused with license_required while status still answers.
    (license_dir / 'license.json').write_text(json.dumps({'trialStartedAt': 0}))
    refused = cli('convert', '--input', str(source), '--output', str(root/'refused.png'), code=1)
    assert json.loads(refused.stderr)['error']['code'] == 'license_required', refused.stderr
    assert not (root/'refused.png').exists()
    assert json.loads(cli('status').stdout)['license']['state'] == 'free'
print('CLI JSON, edit/convert, no-overwrite and live MCP handshake/calls/EOF and license gate passed.')
