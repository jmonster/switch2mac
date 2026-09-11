"""Real Apple Network.framework listener, synthetic clients, no browser/radio."""
import base64
import contextlib
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time

ORIGIN = 'chrome-extension://' + 'a' * 32


def line(proc):
    ready, _, _ = select.select([proc.stdout], [], [], 8)
    assert ready, 'Native listener response timed out'
    data = proc.stdout.readline().decode().strip()
    assert data, 'Native listener exited unexpectedly'
    return data


@contextlib.contextmanager
def server():
    # select() must observe the same bytes readline() consumes. A buffered
    # reader can prefetch APPLIED after RUMBLE and hide it from the next select.
    proc = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    try:
        assert line(proc) == 'READY'
        yield proc
    finally:
        if proc.poll() is None:
            proc.stdin.write(b'quit\n'); proc.stdin.flush()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=3)
        proc.stdin.close(); proc.stdout.close()


def connect(origin=ORIGIN, duplicate=False):
    sock = socket.create_connection(('127.0.0.1', 24810), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode()
    request = f'GET / HTTP/1.1\r\nHost: 127.0.0.1:24810\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n'
    if origin is not None:
        request += f'Origin: {origin}\r\n'
    if duplicate:
        request += f'Origin: {ORIGIN}\r\n'
    sock.sendall((request+'\r\n').encode())
    response = bytearray()
    try:
        while not response.endswith(b'\r\n\r\n'):
            b = sock.recv(1)
            if not b:
                break
            response.extend(b)
    except (OSError, TimeoutError):
        pass
    return sock, b' 101 ' in response.split(b'\r\n')[0]


def exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size-len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def frame(sock):
    a, b = exact(sock, 2)
    n = b & 127
    if n == 126:
        n = struct.unpack('!H', exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack('!Q', exact(sock, 8))[0]
    mask = exact(sock, 4) if b & 128 else None
    data = exact(sock, n)
    if mask:
        data = bytes(x ^ mask[i % 4] for i, x in enumerate(data))
    return a & 15, data


def send(sock, message):
    data = message if isinstance(message, bytes) else json.dumps(message).encode()
    mask = b'\x12\x34\x56\x78'
    if len(data) < 126:
        prefix = bytes([0x81, 0x80 | len(data)])
    elif len(data) < 65536:
        prefix = b'\x81\xfe' + struct.pack('!H', len(data))
    else:
        prefix = b'\x81\xff' + struct.pack('!Q', len(data))
    sock.sendall(prefix + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


with server() as proc:
    for origin, duplicate in [(None, False), ('https://example.com', False), (ORIGIN+'evil', False), (ORIGIN, True)]:
        s, accepted = connect(origin, duplicate)
        s.close()
        assert not accepted, f'Unapproved origin accepted: {origin}'
    a, accepted = connect(); assert accepted
    messages = [json.loads(frame(a)[1]) for _ in range(3)]
    assert [m['t'] for m in messages] == ['hello', 'connected', 'state']
    assert messages[1]['name'] == 'test pad' and messages[2]['b'] == 8
    # Malformed/unknown/out-of-range input must not produce a rumble callback.
    for bad in [b'invalid', {'t':'rumble','slot':9,'strong':1,'weak':0}, {'t':'other'}]:
        send(a, bad)
    send(a, {'t':'rumble','slot':0,'strong':1,'weak':0})
    assert line(proc) == 'RUMBLE 0 1.0 0.0'
    b, accepted = connect(); assert accepted
    for _ in range(3): frame(b)
    send(b, {'t':'rumble','slot':0,'strong':0.5,'weak':0})
    assert line(proc) == 'RUMBLE 0 0.5 0.0'
    a.close(); time.sleep(0.1)
    send(b, {'t':'rumble','slot':0,'strong':0.25,'weak':0})
    assert line(proc) == 'RUMBLE 0 0.25 0.0', 'Departing observer stopped another client effect'
    b.close()
    assert line(proc) == 'RUMBLE 0 0.0 0.0'
    print('PASS origin checks, replay, framing and rumble ownership')

with server() as proc:
    sockets = []
    try:
        for _ in range(8):
            s, accepted = connect(); sockets.append(s); assert accepted
            for _ in range(3): frame(s)
        extra, accepted = connect(); extra.close()
        assert not accepted, 'Connection cap not enforced'
    finally:
        for s in sockets: s.close()
    print('PASS native connection capacity')

with server() as proc:
    s, accepted = connect(); assert accepted
    for _ in range(3): frame(s)
    send(s, b'x' * 65537)
    try:
        opcode, _ = frame(s)
        assert opcode == 8, 'Oversized message was not rejected'
    except (EOFError, ConnectionResetError):
        pass
    finally:
        s.close()
    print('PASS native message size bound')

with server() as proc:
    active, accepted = connect(); assert accepted
    for _ in range(3): frame(active)
    send(active, {'t':'rumble','slot':0,'strong':1,'weak':0})
    assert line(proc) == 'RUMBLE 0 1.0 0.0'
    proc.stdin.write(b'disable\n'); proc.stdin.flush()
    assert line(proc) == 'RUMBLE 0 0.0 0.0'
    assert line(proc) == 'APPLIED'
    try:
        opcode, _ = frame(active)
        assert opcode == 8
    except (EOFError, ConnectionResetError):
        pass
    active.close()
    proc.stdin.write(b'replace\n'); proc.stdin.flush()
    events = {line(proc), line(proc)}
    assert events == {'APPLIED', 'READY'}
    denied, accepted = connect(); denied.close()
    assert not accepted, 'Revoked Origin still accepted'
    active, accepted = connect('chrome-extension://' + 'b' * 32); assert accepted
    messages = [json.loads(frame(active)[1]) for _ in range(3)]
    assert [m['t'] for m in messages] == ['hello', 'connected', 'state']
    assert messages[1]['name'] == 'test pad' and messages[2]['b'] == 4
    active.close()
    print('PASS live disable, rumble stop, Origin revocation and reconnect without controller re-pairing')
