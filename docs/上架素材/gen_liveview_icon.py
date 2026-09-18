# -*- coding: utf-8 -*-
"""生成番茄钟实况窗胶囊图标 PNG（透明底 + 白色前景，适配靛蓝 #5B8DEF 胶囊底色）
纯标准库实现（struct + zlib），不依赖 Pillow。
96x96 RGBA：圆环 + 12 点方向指针 + 中心圆点（时钟语义）
"""
import io
import math
import os
import struct
import zlib

PROJ = r'D:\harmony\Project\s\Application'
DST = os.path.join(PROJ, 'entry', 'src', 'main', 'resources', 'rawfile', 'pomo_capsule_icon.png')

W = 96
H = 96
TRANSPARENT = (0, 0, 0, 0)
WHITE = (255, 255, 255, 255)

CX = (W - 1) / 2.0
CY = (H - 1) / 2.0
R_OUTER = 36.0
R_INNER = 29.0
R_DOT = 5.0
HAND_HALF_W = 2.0
HAND_TOP = CY - 25.0
HAND_BOTTOM = CY - 4.0


def pixel(x, y):
    d = math.hypot(x - CX, y - CY)
    if R_INNER <= d <= R_OUTER:
        return WHITE
    if abs(x - CX) <= HAND_HALF_W and HAND_TOP <= y <= HAND_BOTTOM:
        return WHITE
    if d <= R_DOT:
        return WHITE
    return TRANSPARENT


raw = bytearray()
for yy in range(H):
    raw.append(0)
    for xx in range(W):
        raw.extend(pixel(xx, yy))


def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data +
            struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))


png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
png += chunk(b'IEND', b'')
io.open(DST, 'wb').write(png)
print('written %s size=%d' % (DST, os.path.getsize(DST)))
