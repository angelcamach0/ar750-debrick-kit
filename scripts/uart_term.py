#!/usr/bin/env python3
"""
Minimal dependency-free UART terminal.

Usage:
  ./uart_term.py /dev/ttyACM0 115200

Exit:
  Ctrl+]
"""

import os
import select
import sys
import termios
import tty
import errno

dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyACM0"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200

baud_map = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
    230400: termios.B230400,
}

if baud not in baud_map:
    print(f"Unsupported baud: {baud}")
    sys.exit(1)

fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
# Configure serial line in raw 8N1 mode.
attrs[0] = 0
attrs[1] = 0
attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = baud_map[baud]
attrs[5] = baud_map[baud]
attrs[6][termios.VMIN] = 1
attrs[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attrs)

stdin_fd = sys.stdin.fileno()
old_stdin = termios.tcgetattr(stdin_fd)
tty.setraw(stdin_fd)

print(f"Connected to {dev} @ {baud}. Exit with Ctrl+]")

def write_all(fd_out, data):
    # Handle partial writes and EAGAIN without dropping bytes.
    view = memoryview(data)
    while view:
        try:
            sent = os.write(fd_out, view)
            if sent <= 0:
                return False
            view = view[sent:]
        except BlockingIOError:
            select.select([], [fd_out], [], 0.2)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                select.select([], [fd_out], [], 0.2)
                continue
            return False
    return True

try:
    while True:
        r, _, _ = select.select([fd, stdin_fd], [], [])
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                data = b""
            except OSError:
                break
            if data:
                if not write_all(sys.stdout.fileno(), data):
                    break
        if stdin_fd in r:
            ch = os.read(stdin_fd, 1)
            if ch == b"\x1d":  # Ctrl+]
                break
            if not write_all(fd, ch):
                break
finally:
    termios.tcsetattr(stdin_fd, termios.TCSANOW, old_stdin)
    os.close(fd)
    print("\nDisconnected.")
