#!/usr/bin/env python3
"""Make a mainline arm64 Image acceptable to this board's LK, then gzip it.

Two fields in the arm64 Image header decide whether LK jumps at all; both were
found empirically by black-box bisection (see linux/docs/worklog.md):

  * image_size must equal the value the stock kernel declares (0x257f000).
    Declaring the honest size -- 29.5 MB or 30.0 MB -- makes LK hang until the
    watchdog resets the board, and the kernel is never entered.
  * code0 must be a branch instruction. Modern arm64 kernels put a `nop` there
    and branch from the next word; LK does not accept that. Rewriting code0 to
    `b +4` keeps the execution path identical (it just skips the nop) while
    giving LK the branch it wants.

text_offset is taken from the stock image as well (0x80000).

Usage:
    a3-prep-kernel.py <Image> <stock boot.img> <out Image.gz> [--probe]

--probe additionally rewrites the entry to run a few instructions that reset
the board through TopRGU before the MMU is on, which is the only reliable way
to tell "LK jumped" from "LK did not" on this UART-less board.
"""

import gzip
import os
import struct
import sys
import zlib

PROBE_STUB = [
    0xD28E0000,  # movz x0, #0x7000
    0xF2A20000,  # movk x0, #0x1000, lsl #16   -> x0 = 0x10007000
    0x52800602,  # movz w2, #0x30
    0x72A44002,  # movk w2, #0x2200, lsl #16   -> w2 = 0x22000030
    0xB9000002,  # str  w2, [x0]                -> WDT_MODE
    0x52824121,  # movz w1, #0x1209
    0xB9001401,  # str  w1, [x0, #0x14]         -> WDT_SWRST
    0x14000000,  # b .
]


def stock_image(boot_img_path):
    """Return the raw Image the stock boot.img carries."""
    d = open(boot_img_path, "rb").read()
    ks = struct.unpack_from("<I", d, 8)[0]
    blob = d[2048:2048 + ks]
    if blob[:2] != b"\x1f\x8b":
        return blob
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    return dec.decompress(blob)          # unused_data holds the appended DTB


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    probe = "--probe" in sys.argv
    if len(args) < 3:
        sys.exit(__doc__)

    src, boot_img, out = args[0], args[1], args[2]

    img = bytearray(open(src, "rb").read())
    if img[56:60] != b"ARMd":
        sys.exit("ERROR: not an arm64 Image")

    ref = stock_image(boot_img)
    if ref[56:60] != b"ARMd":
        sys.exit("ERROR: stock kernel is not an arm64 Image")

    text_offset = struct.unpack_from("<Q", ref, 8)[0]
    image_size = struct.unpack_from("<Q", ref, 16)[0]
    flags = struct.unpack_from("<Q", ref, 24)[0]

    orig_code0 = struct.unpack_from("<I", img, 0)[0]
    orig_size = struct.unpack_from("<Q", img, 16)[0]

    struct.pack_into("<Q", img, 8, text_offset)
    struct.pack_into("<Q", img, 16, image_size)
    struct.pack_into("<Q", img, 24, flags)

    if probe:
        struct.pack_into("<I", img, 0, 0x14000010)      # b +64
        for i, ins in enumerate(PROBE_STUB):
            struct.pack_into("<I", img, 64 + i * 4, ins)
        code0_note = "b +64 with reset probe"
    elif (orig_code0 & 0xFC000000) == 0x14000000:
        code0_note = f"already a branch ({orig_code0:#010x}), left alone"
    else:
        struct.pack_into("<I", img, 0, 0x14000001)      # b +4, skips the nop
        code0_note = f"{orig_code0:#010x} -> 0x14000001 (b +4)"

    raw = bytes(img)
    co = zlib.compressobj(1, zlib.DEFLATED, -15, 1)
    body = co.compress(raw) + co.flush()
    hdr = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03"
    trl = struct.pack("<II", zlib.crc32(raw) & 0xFFFFFFFF, len(raw) & 0xFFFFFFFF)
    open(out, "wb").write(hdr + body + trl)

    print(f"  source       : {src} ({len(raw)} bytes)")
    print(f"  stock ref    : {boot_img}")
    print(f"  text_offset  : {text_offset:#x}")
    print(f"  image_size   : {orig_size:#x} -> {image_size:#x}  (LK needs the stock value)")
    print(f"  flags        : {flags:#x}")
    print(f"  code0        : {code0_note}")
    print(f"  output       : {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
