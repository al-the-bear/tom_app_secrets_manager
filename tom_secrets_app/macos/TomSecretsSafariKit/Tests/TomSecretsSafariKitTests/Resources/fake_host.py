# Copyright (c) 2026 Peter Nicolai Alexis Kyaw
# SPDX-License-Identifier: BSD-3-Clause
#
# A fake tsm-browser-host for the Safari kit's tests: native messaging's
# framing on standard input and output. It refuses a caller other than the
# demo Safari extension (one id-less error, as the real host does), answers
# `status` with its process id and the runtime directory it was given, and
# ends on `die`. Demo data only.
import json
import os
import struct
import sys

ORIGIN = 'safari-web-extension://com.althebear.tomSecretsApp.safari/'


def write(message):
    body = json.dumps(message).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('=I', len(body)) + body)
    sys.stdout.buffer.flush()


def read():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack('=I', header)
    return json.loads(sys.stdin.buffer.read(length))


if sys.argv[1:] != [ORIGIN]:
    write({'error': {'kind': 'denied', 'message': 'not the product', 'reason': 'origin'}})
    sys.exit(1)

while True:
    request = read()
    if request is None:
        break
    op = request.get('op')
    if op == 'die':
        sys.exit(3)
    if op == 'status':
        write({
            'id': request['id'],
            'status': 'unlocked',
            'pid': os.getpid(),
            'runtime': os.environ.get('TSM_RUNTIME_DIR', ''),
        })
    else:
        write({'id': request['id'], 'error': {'kind': 'malformed', 'message': 'op'}})
