import os
import sys, struct, zlib, subprocess, tempfile, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location("ac", os.path.join(os.path.dirname(os.path.abspath(__file__)), "a3-colour.py"))
ac = importlib.util.module_from_spec(spec); spec.loader.exec_module(ac)

src,boot,out,mapfile = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
img = bytearray(open(src,"rb").read())
base = 0xffff800080000000
pe = ac.sym(mapfile,"primary_entry") - base

CAVE = 0x40
# disable TopRGU watchdog from early asm (MMU off -> plain physical store),
# then continue into the real entry point.
asm_src = """
        movz x8, #0x7000
        movk x8, #0x1000, lsl #16      /* x8 = 0x10007000 (TopRGU) -- use x8/x9 so x0 (DTB) is preserved */
        movz w9, #0x0000
        movk w9, #0x2200, lsl #16      /* w9 = 0x22000000: KEY, WDT_EN=0 */
        str  w9, [x8]                  /* WDT_MODE <- disable */
"""
with tempfile.TemporaryDirectory() as td:
    body = ac.asm(asm_src, td, "wdt")
stub = body + [ac.b_word(CAVE + len(body)*4, pe)]
assert CAVE + len(stub)*4 <= 0x100, "cave overrun"
for i,w in enumerate(stub):
    struct.pack_into("<I", img, CAVE+i*4, w)
struct.pack_into("<I", img, 0, ac.b_word(0, CAVE))
print(f"  entry cave @ {CAVE:#x}: {len(stub)} words -> disable WDT_MODE then b {pe:#x}")

toff,isize,flags = ac.stock_header(boot)
struct.pack_into("<Q",img,8,toff); struct.pack_into("<Q",img,16,isize); struct.pack_into("<Q",img,24,flags)
raw=bytes(img)
co=zlib.compressobj(6,zlib.DEFLATED,-15); b=co.compress(raw)+co.flush()
open(out,"wb").write(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03"+b+struct.pack("<II",zlib.crc32(raw)&0xffffffff,len(raw)&0xffffffff))
print("  output",out,os.path.getsize(out))
