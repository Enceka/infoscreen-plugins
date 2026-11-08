#!/usr/bin/env python3
"""Operate and debug the E5 screen over SSH: screenshots, touches, packages and settings.

    tools/device.py [--host root@192.168.9.1] [--TouchDev /dev/input/event1] COMMAND ...

    shot [PATH]                         framebuffer screenshot (default screen.png)
    tap X Y [--wait SEC] [--shot PATH]
    swipe X1 Y1 X2 Y2 [--ms 240] [--steps 16] [--wait SEC] [--shot PATH]
    unlock [--shot PATH]                wake, swipe up, then wait 0.6 s
    key NAME [--wait SEC] [--shot PATH] press a hardware key
    open-apps [--shot PATH]             menu button, then the apps tile
    install TARGET... [--restart]       a package .tar.gz, or a plugin id from dist/packages
    idle SECONDS                        uci e5-infoscreen.main.idle

The host and the device need only Python 3's standard library.  SSH, SCP and the
device's framebuffer/debugfs interfaces are used as they are.
"""
import argparse
import binascii
import glob
import os
import shlex
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, '..', 'dist', 'packages')

# Remote device.py: /dev/dri/card0 ioctls and evdev codes.
REMOTE = r'''
import argparse
import fcntl
import mmap
import os
import re
import struct
import sys
import time

DRM_IOCTL_MODE_GETFB = 0xC01C64AD
DRM_IOCTL_PRIME_HANDLE_TO_FD = 0xC00C642D
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 53, 54, 57
BTN_TOUCH, SYN_REPORT = 330, 0
KEYS = {"power": ("/dev/input/event0", 116), "up": ("/dev/input/event3", 103),
        "down": ("/dev/input/event3", 108), "left": ("/dev/input/event3", 105),
        "right": ("/dev/input/event3", 106), "enter": ("/dev/input/event3", 28),
        "esc": ("/dev/input/event3", 1)}


def framebuffer():
    text = open('/sys/kernel/debug/dri/0/framebuffer').read()
    first = best = None
    for m in re.finditer(r'^framebuffer\[(\d+)\]:(.*?)(?=^framebuffer\[|\Z)', text, re.S | re.M):
        fb = int(m.group(1))
        first = fb if first is None else first
        if 'allocated by = cage' in m.group(2):
            r = re.search(r'refcount\s*=\s*(\d+)', m.group(2))
            refs = int(r.group(1)) if r else 0
            if best is None or refs > best[1]:
                best = (fb, refs)
    if first is None:
        sys.exit('no framebuffer in /sys/kernel/debug/dri/0/framebuffer')
    return (best or (first, 0))[0]


def shot():
    fb = framebuffer()
    drm = os.open('/dev/dri/card0', os.O_RDWR)
    buf = fcntl.ioctl(drm, DRM_IOCTL_MODE_GETFB, struct.pack('7I', fb, 0, 0, 0, 0, 0, 0))
    _, w, h, pitch, _, _, handle = struct.unpack('7I', buf)
    buf = fcntl.ioctl(drm, DRM_IOCTL_PRIME_HANDLE_TO_FD, struct.pack('IIi', handle, 0, -1))
    dmabuf = struct.unpack('IIi', buf)[2]
    view = mmap.mmap(dmabuf, pitch * h, mmap.MAP_SHARED, mmap.PROT_READ)
    out = sys.stdout.buffer
    out.write(struct.pack('<III', w, h, pitch))
    out.write(view)
    out.flush()


def emit(fd, kind, code, value):
    fd.write(struct.pack('@llHHi', 0, 0, kind, code, value))


def sync(fd):
    emit(fd, EV_SYN, SYN_REPORT, 0)


def move(fd, x, y):
    emit(fd, EV_ABS, ABS_MT_POSITION_X, int(x))
    emit(fd, EV_ABS, ABS_MT_POSITION_Y, int(y))
    sync(fd)


def down(fd, x, y):
    emit(fd, EV_ABS, ABS_MT_TRACKING_ID, 1)
    emit(fd, EV_ABS, ABS_MT_POSITION_X, int(x))
    emit(fd, EV_ABS, ABS_MT_POSITION_Y, int(y))
    emit(fd, EV_KEY, BTN_TOUCH, 1)
    sync(fd)


def up(fd):
    emit(fd, EV_ABS, ABS_MT_TRACKING_ID, -1)
    emit(fd, EV_KEY, BTN_TOUCH, 0)
    sync(fd)


def tap(path, x, y):
    with open(path, 'wb', buffering=0) as fd:
        down(fd, x, y)
        time.sleep(0.05)
        up(fd)


def swipe(path, x1, y1, x2, y2, ms, steps):
    with open(path, 'wb', buffering=0) as fd:
        down(fd, x1, y1)
        for i in range(1, steps + 1):
            time.sleep(ms / 1000.0 / steps)
            t = i / steps
            move(fd, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        up(fd)


def press_key(name):
    path, code = KEYS[name]
    with open(path, 'wb', buffering=0) as fd:
        emit(fd, EV_KEY, code, 1)
        sync(fd)
        time.sleep(0.05)
        emit(fd, EV_KEY, code, 0)
        sync(fd)


def wake():
    path = '/sys/class/backlight/sprd_backlight/brightness'
    try:
        brightness = int(open(path).read())
    except (OSError, ValueError):
        return
    if brightness <= 0:
        press_key('power')
        time.sleep(0.4)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--TouchDev', default='/dev/input/event1')
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('shot')
    c = sub.add_parser('tap')
    c.add_argument('x', type=float)
    c.add_argument('y', type=float)
    c.add_argument('--wait', type=float, default=0)
    c.add_argument('--shot', action='store_true')
    c = sub.add_parser('swipe')
    for n in ('x1', 'y1', 'x2', 'y2'):
        c.add_argument(n, type=float)
    c.add_argument('--ms', type=int, default=240)
    c.add_argument('--steps', type=int, default=16)
    c.add_argument('--wait', type=float, default=0)
    c.add_argument('--shot', action='store_true')
    c = sub.add_parser('key')
    c.add_argument('name', choices=sorted(KEYS))
    c.add_argument('--wait', type=float, default=0)
    c.add_argument('--shot', action='store_true')
    c = sub.add_parser('unlock')
    c.add_argument('--shot', action='store_true')
    c = sub.add_parser('open-apps')
    c.add_argument('--shot', action='store_true')
    a = p.parse_args()

    if a.cmd == 'shot':
        shot()
        return
    if a.cmd == 'tap':
        tap(a.TouchDev, a.x, a.y)
        time.sleep(a.wait)
    elif a.cmd == 'swipe':
        swipe(a.TouchDev, a.x1, a.y1, a.x2, a.y2, a.ms, a.steps)
        time.sleep(a.wait)
    elif a.cmd == 'key':
        press_key(a.name)
        time.sleep(a.wait)
    elif a.cmd == 'unlock':
        wake()
        swipe(a.TouchDev, 160, 440, 160, 80, 260, 20)
        time.sleep(0.6)
    elif a.cmd == 'open-apps':
        tap(a.TouchDev, 295, 50)
        time.sleep(0.5)
        tap(a.TouchDev, 260, 340)
        time.sleep(0.5)
    if a.shot:
        shot()


if __name__ == '__main__':
    main()
'''


def run(argv, data=None):
    p = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        sys.exit(p.stderr.decode('utf-8', 'replace').strip() or f'{argv[0]} failed')
    return p.stdout


def device(args):
    return run(['ssh', HOST, 'python3', '-', *args], REMOTE.encode())


def save(path, data):
    if len(data) < 12:
        sys.exit('short screenshot')
    w, h, pitch = struct.unpack_from('<III', data)
    pixels = data[12:]
    if len(pixels) < pitch * h:
        sys.exit(f'short screenshot: {len(pixels)} < {pitch * h}')
    raw = bytearray()
    for y in range(h):
        row = pixels[y * pitch:y * pitch + w * 4]
        rgb = bytearray(w * 3)
        rgb[0::3] = row[2::4]          # BGRX / XRGB8888 -> RGB
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        raw.append(0)
        raw.extend(rgb)

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body +
                struct.pack('>I', binascii.crc32(kind + body) & 0xffffffff))

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        f.write(chunk(b'IEND', b''))
    print(f'{path}: {w}x{h}')


def capture(args, path):
    save(path, device(args))


def touch_args(cmd, wait, shot, *coords):
    args = [cmd, *(str(c) for c in coords)]
    if wait is not None:
        args += ['--wait', str(wait)]
    if shot:
        args += ['--shot']
    return args


def package(target):
    if os.path.isfile(target):
        return target
    found = sorted(glob.glob(os.path.join(DIST, f'{target}-*.tar.gz')))
    if not found:
        sys.exit(f'no package for {target} in {DIST}')
    return found[-1]


def install(targets, restart):
    for target in targets:
        path = package(target)
        name = os.path.basename(path)
        run(['scp', '-O', path, f'{HOST}:/tmp/'])
        cmd = (f'/usr/libexec/e5-infoscreen/plugin install {shlex.quote("/tmp/" + name)}; '
               f'status=$?; rm -f /tmp/*.tar.gz; exit $status')
        run(['ssh', HOST, cmd])
    if restart:
        run(['ssh', HOST, '/etc/init.d/e5-infoscreen restart'])


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--host', default=os.environ.get('E5_HOST', 'root@192.168.9.1'))
    p.add_argument('--TouchDev', default='/dev/input/event1')
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('shot', aliases=['screenshot'])
    c.add_argument('path', nargs='?', default='screen.png')
    c = sub.add_parser('tap')
    c.add_argument('x', type=float)
    c.add_argument('y', type=float)
    c.add_argument('--wait', type=float)
    c.add_argument('--shot')
    c = sub.add_parser('swipe')
    for n in ('x1', 'y1', 'x2', 'y2'):
        c.add_argument(n, type=float)
    c.add_argument('--ms', type=int, default=240)
    c.add_argument('--steps', type=int, default=16)
    c.add_argument('--wait', type=float)
    c.add_argument('--shot')
    c = sub.add_parser('key')
    c.add_argument('name', choices=['power', 'up', 'down', 'left', 'right', 'enter', 'esc'])
    c.add_argument('--wait', type=float)
    c.add_argument('--shot')
    c = sub.add_parser('unlock')
    c.add_argument('--shot')
    c = sub.add_parser('open-apps')
    c.add_argument('--shot')
    c = sub.add_parser('install')
    c.add_argument('targets', nargs='+')
    c.add_argument('--restart', action='store_true')
    c = sub.add_parser('idle')
    c.add_argument('seconds', type=int)
    a = p.parse_args()

    global HOST
    HOST = a.host
    touch = ['--TouchDev', a.TouchDev]

    if a.cmd in ('shot', 'screenshot'):
        capture(['shot'], a.path)
    elif a.cmd == 'tap':
        args = touch + touch_args('tap', a.wait, a.shot, a.x, a.y)
        if a.shot:
            capture(args, a.shot)
        else:
            device(args)
    elif a.cmd == 'swipe':
        args = touch + touch_args('swipe', a.wait, a.shot, a.x1, a.y1, a.x2, a.y2)
        if a.ms != 240:
            args += ['--ms', str(a.ms)]
        if a.steps != 16:
            args += ['--steps', str(a.steps)]
        if a.shot:
            capture(args, a.shot)
        else:
            device(args)
    elif a.cmd == 'key':
        args = ['key', a.name]
        if a.wait is not None:
            args += ['--wait', str(a.wait)]
        if a.shot:
            args += ['--shot']
        if a.shot:
            capture(args, a.shot)
        else:
            device(args)
    elif a.cmd == 'unlock':
        args = touch + ['unlock'] + (['--shot'] if a.shot else [])
        if a.shot:
            capture(args, a.shot)
        else:
            device(args)
    elif a.cmd == 'open-apps':
        args = touch + ['open-apps'] + (['--shot'] if a.shot else [])
        if a.shot:
            capture(args, a.shot)
        else:
            device(args)
    elif a.cmd == 'install':
        install(a.targets, a.restart)
    elif a.cmd == 'idle':
        run(['ssh', HOST, f'uci set e5-infoscreen.main.idle={a.seconds} && uci commit e5-infoscreen'])


if __name__ == '__main__':
    main()
