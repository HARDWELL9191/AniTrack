#!/usr/bin/env python3
"""Writes a real Blu-ray PGS (.sup) subtitle stream: one white caption bar shown from
0.5 s to 5 s, bottom centre of a 1280x720 picture. Used to test picture subtitles."""
import struct, sys

W, H = 1280, 720
BW, BH = 480, 64            # caption bitmap
X, Y = (W - BW) // 2, H - BH - 60

def seg(pts, kind, payload):
    ticks = int(pts * 90000)
    return b"PG" + struct.pack(">IIBH", ticks, ticks, kind, len(payload)) + payload

def pcs(number, state, objects):
    p = struct.pack(">HHBHBBBB", W, H, 0x10, number, state, 0, 0, len(objects))
    for oid, x, y in objects:
        p += struct.pack(">HBBHH", oid, 0, 0, x, y)
    return p

def wds():
    return struct.pack(">BBHHHH", 1, 0, X, Y, BW, BH)

def pds():
    # id, Y, Cr, Cb, alpha: 0 transparent, 1 white, 2 black outline
    return struct.pack(">BB", 0, 0) + bytes([0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 255])

def rle_line(row):
    out, i = bytearray(), 0
    while i < len(row):
        c = row[i]; n = 1
        while i + n < len(row) and row[i + n] == c and n < 16383: n += 1
        if c == 0:
            out += bytes([0, n]) if n < 64 else bytes([0, 0x40 | (n >> 8), n & 0xFF])
        elif n < 3:
            out += bytes([c]) * n
        else:
            out += bytes([0, 0x80 | n, c]) if n < 64 else bytes([0, 0xC0 | (n >> 8), n & 0xFF, c])
        i += n
    return bytes(out) + b"\x00\x00"

def ods():
    rows = []
    for y in range(BH):
        if y < 4 or y >= BH - 4:
            rows.append([2] * BW)
        else:
            rows.append([2] * 4 + [1] * (BW - 8) + [2] * 4)
    data = b"".join(rle_line(r) for r in rows)
    length = len(data) + 4
    return struct.pack(">HBB", 0, 0, 0xC0) + length.to_bytes(3, "big") + struct.pack(">HH", BW, BH) + data

out = open(sys.argv[1], "wb")
out.write(seg(0.5, 0x16, pcs(0, 0x80, [(0, X, Y)])))
out.write(seg(0.5, 0x17, wds()))
out.write(seg(0.5, 0x14, pds()))
out.write(seg(0.5, 0x15, ods()))
out.write(seg(0.5, 0x80, b""))
out.write(seg(5.0, 0x16, pcs(1, 0x00, [])))
out.write(seg(5.0, 0x17, wds()))
out.write(seg(5.0, 0x80, b""))
out.close()
