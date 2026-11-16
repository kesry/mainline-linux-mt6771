#!/usr/bin/env python3
"""Framebuffer colour bisect for the MT6771 bring-up.

Why framebuffer: the board has no usable UART (`printk.disable_uart=1` in the
vendor bootargs), /dev/mem is blocked, the pstore ring is overwritten by Android
before it can be read, and LK has no memory-read oem command. The framebuffer is
the only channel that survives all of that: LK leaves the display controller
scanning out of the panel buffer, so a plain `str` shows up on screen at once.

Addresses are taken from the *runtime* device tree (authoritative):

    /memory                reg = <0x00 0x40000000 0x01 0x00>   (memstart)
    mblock-11-framebuffer  reg = <0x00 0x77440000 0x00 0x21c0000>

so the linear-map alias of the framebuffer is
    PAGE_OFFSET + (0x77440000 - 0x40000000) = 0xffff000037440000
with PAGE_OFFSET = -(1 << 48) for CONFIG_ARM64_VA_BITS=48.

Stages (later overwrites earlier, so the colour left on screen is the LAST
point reached):

    RED    entry trampoline             LK jumped to us
    GREEN  __primary_switch entry       __cpu_setup returned
    BLUE   after __pi_early_map_kernel  MMU on + relocate + linear map done
           (painted through the linear map -- the only way to write the
            framebuffer once the MMU is enabled)

Usage: a3-colour.py <Image> <stock boot.img> <out.gz> --symbols <System.map>
"""

import os
import struct
import subprocess
import sys
import tempfile
import zlib

FB = 0x77440000
FB_VA = 0xFFFF000037440000
FB_BYTES = 0x400000

CAVE1 = 0x40
CAVE2 = 0x80
CAVE3 = 0xC0

RED = 0xFFFF0000
GREEN = 0xFF00FF00
BLUE = 0xFF0000FF


def paint_src(colour, nbytes, addr=FB):
    n = nbytes // 8
    lo, hi = colour & 0xFFFF, (colour >> 16) & 0xFFFF
    a = []
    for shift in (0, 16, 32, 48):
        part = (addr >> shift) & 0xFFFF
        if shift == 0:
            a.append(f"        movz x0, #{part}")
        elif part:
            a.append(f"        movk x0, #{part}, lsl #{shift}")
    a.append(f"        movz w1, #{lo}")
    if hi:
        a.append(f"        movk w1, #{hi}, lsl #16")
    a.append("        orr  x1, x1, x1, lsl #32")
    a.append(f"        movz x2, #{n & 0xFFFF}")
    if n >> 16:
        a.append(f"        movk x2, #{((n >> 16) & 0xFFFF)}, lsl #16")
    a += [
        "    1:  str  x1, [x0], #8",
        "        subs x2, x2, #1",
        "        b.ne 1b",
    ]
    return "\n".join(a) + "\n"


def asm(src, workdir, name):
    s = os.path.join(workdir, name + ".S")
    o = os.path.join(workdir, name + ".o")
    b = os.path.join(workdir, name + ".bin")
    with open(s, "w") as f:
        f.write(".text\n.global _start\n_start:\n" + src)
    subprocess.run(["aarch64-linux-gnu-gcc", "-c", "-o", o, s], check=True)
    subprocess.run(["aarch64-linux-gnu-objcopy", "-O", "binary", o, b], check=True)
    d = open(b, "rb").read()
    assert len(d) % 4 == 0
    return [struct.unpack_from("<I", d, i)[0] for i in range(0, len(d), 4)]


def b_word(insn_off, target_off):
    delta = target_off - insn_off
    assert delta % 4 == 0, delta
    imm = delta >> 2
    assert -(1 << 25) <= imm < (1 << 25), f"branch out of range {delta}"
    return 0x14000000 | (imm & 0x03FFFFFF)


def bl_word(insn_off, target_off):
    delta = target_off - insn_off
    assert delta % 4 == 0, delta
    imm = delta >> 2
    assert -(1 << 25) <= imm < (1 << 25), f"bl out of range {delta}"
    return 0x94000000 | (imm & 0x03FFFFFF)


def sym(mapfile, name):
    for line in open(mapfile):
        p = line.split()
        if len(p) >= 3 and p[2] == name:
            return int(p[0], 16)
    raise SystemExit(f"symbol {name} not found")


def stock_header(path):
    d = open(path, "rb").read()
    ks = struct.unpack_from("<I", d, 8)[0]
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    ref = dec.decompress(d[2048:2048 + ks])
    return struct.unpack_from("<QQQ", ref, 8)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    src, boot_img, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if "--symbols" not in sys.argv:
        sys.exit("need --symbols <System.map>")
    mapfile = sys.argv[sys.argv.index("--symbols") + 1]

    img = bytearray(open(src, "rb").read())
    if img[56:60] != b"ARMd":
        sys.exit("ERROR: not an arm64 Image")
    base = 0xffff800080000000
    pe = sym(mapfile, "primary_entry") - base
    ps = sym(mapfile, "__primary_switch") - base
    psw = sym(mapfile, "__primary_switched")

    ldr_site = None
    for off in range(ps, ps + 0x40, 4):
        if (struct.unpack_from("<I", img, off)[0] >> 24) == 0x58:
            ldr_site = off
            break
    if ldr_site is None:
        sys.exit("could not locate `ldr x8, =__primary_switched`")
    print(f"  primary_entry                {pe:#x}")
    print(f"  __primary_switch             {ps:#x}")
    print(f"  ldr x8 (=__primary_switched) {ldr_site:#x}")

    with tempfile.TemporaryDirectory() as td:
        s1 = asm(paint_src(RED, FB_BYTES), td, "c1")
        stub1 = s1 + [b_word(CAVE1 + len(s1) * 4, pe)]

        s2 = asm(paint_src(GREEN, FB_BYTES), td, "c2")
        stub2 = s2 + [b_word(CAVE2 + len(s2) * 4, ps + 4)]

        body3 = asm(paint_src(BLUE, FB_BYTES, addr=FB_VA), td, "c3")
        tail_lines = [f"        movz x8, #{psw & 0xFFFF}"]
        for s in (16, 32, 48):
            part = (psw >> s) & 0xFFFF
            if part:
                tail_lines.append(f"        movk x8, #{part}, lsl #{s}")
        tail3 = asm("\n".join(tail_lines) + "\n", td, "c3tail")
        stub3 = body3 + tail3
        stub3.append(b_word(CAVE3 + len(stub3) * 4, ldr_site + 4))

    for name, cave, stub, nxt in (("cave1", CAVE1, stub1, CAVE2),
                                  ("cave2", CAVE2, stub2, CAVE3),
                                  ("cave3", CAVE3, stub3, 0x100)):
        end = cave + len(stub) * 4
        assert end <= nxt, f"{name} overruns: {end:#x} > {nxt:#x}"
        print(f"  {name} @ {cave:#x}: {len(stub)} words, ends {end:#x}")

    struct.pack_into("<I", img, 0, b_word(0, CAVE1))
    for i, wv in enumerate(stub1):
        struct.pack_into("<I", img, CAVE1 + i * 4, wv)
    for i, wv in enumerate(stub2):
        struct.pack_into("<I", img, CAVE2 + i * 4, wv)
    for i, wv in enumerate(stub3):
        struct.pack_into("<I", img, CAVE3 + i * 4, wv)

    struct.pack_into("<I", img, ps, b_word(ps, CAVE2))
    print(f"  {ps:#x}: bti c -> b {CAVE2:#x}   (green)")
    struct.pack_into("<I", img, ldr_site, bl_word(ldr_site, CAVE3))
    print(f"  {ldr_site:#x}: ldr x8 -> bl {CAVE3:#x}  (blue, via linear map)")

    toff, isize, flags = stock_header(boot_img)
    struct.pack_into("<Q", img, 8, toff)
    struct.pack_into("<Q", img, 16, isize)
    struct.pack_into("<Q", img, 24, flags)

    raw = bytes(img)
    co = zlib.compressobj(6, zlib.DEFLATED, -15)
    body = co.compress(raw) + co.flush()
    hdr = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03"
    trl = struct.pack("<II", zlib.crc32(raw) & 0xFFFFFFFF, len(raw) & 0xFFFFFFFF)
    open(out, "wb").write(hdr + body + trl)
    print(f"  fb phys {FB:#x} / linear-map VA {FB_VA:#x}, {FB_BYTES:#x} bytes")
    print(f"  output = {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
