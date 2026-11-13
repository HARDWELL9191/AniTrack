"""Writes AppImage update information into an AppImage's `.upd_info` section (what appimagetool -u
does), so Gear Lever, AppImageUpdate and AppImageLauncher find newer builds on their own.

    python3 tools/appimage_update_info.py JellyReco-x86_64.AppImage "gh-releases-zsync|owner|repo|latest-pre|JellyReco-x86_64.AppImage.zsync"

The type 2 AppImage runtime reserves the section (1024 bytes) for exactly this; only those bytes
change, so the AppImage runs the same. Exits non-zero if the section is missing or too small.
"""
import struct
import sys


def section(data: bytes, wanted: str):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a 64-bit little-endian ELF file")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    def header(i):
        name, _type, _flags, _addr, offset, size = struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize)
        return name, offset, size
    _, strtab_off, _ = header(shstrndx)
    for i in range(shnum):
        name, offset, size = header(i)
        end = data.index(b"\0", strtab_off + name)
        if data[strtab_off + name:end].decode() == wanted:
            return offset, size
    raise SystemExit(f"no {wanted} section (not a type 2 AppImage runtime?)")


def main():
    path, info = sys.argv[1], sys.argv[2].encode()
    with open(path, "rb") as f:
        data = f.read()
    offset, size = section(data, ".upd_info")
    if len(info) >= size:
        raise SystemExit(f"update information ({len(info)} bytes) doesn't fit .upd_info ({size} bytes)")
    with open(path, "r+b") as f:
        f.seek(offset)
        f.write(info + b"\0" * (size - len(info)))
    print(f"wrote {len(info)} bytes of update information at {offset:#x} ({size}-byte .upd_info)")


main()
