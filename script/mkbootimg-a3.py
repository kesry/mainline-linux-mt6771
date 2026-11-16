#!/usr/bin/env python3
"""Assemble an MTK-style Android boot image for the OPPO A3 (PADT00 / MT6771).

The layout is a byte-exact reproduction of the stock boot.img measured on the
device (see linux/docs/mt6771-facts.md section 11):

    offset            content
    ----------------  ------------------------------------------------------
    0x0000            Android boot header v2 (1660 B, padded to page_size)
    0x0800            kernel  (gzip)
    page-aligned      ramdisk (gzip)
    page-aligned      64-byte MTK DTB header (BIG endian) + DTB
    ...               zero padding up to the partition size

Why not just use AOSP mkbootimg: it appends the DTB as a bare blob, but LK on
this board looks for the 64-byte MTK header (magic 0xd7b7ab1e) and uses the
sizes inside it. Header v2's own dtb_size field carries the size of that whole
blob (header + DTB), not just the DTB.

Everything here is parameterised from the measured stock image; if a value is
unknown the script refuses to guess.
"""

import argparse
import hashlib
import struct
import sys

# ---- measured constants (stock boot.img, PADT00) ---------------------------
PAGE_SIZE = 2048
KERNEL_ADDR = 0x40080000
RAMDISK_ADDR = 0x55000000
SECOND_ADDR = 0x40F00000
TAGS_ADDR = 0x54000000
OS_VERSION = 0x14000154
HEADER_VERSION = 2
HEADER_SIZE = 0x67C            # 1660 bytes for v2
MTK_DTB_MAGIC = 0xD7B7AB1E
MTK_DTB_HDR_SIZE = 0x40

# Identify partitions by PARTUUID, never by /dev/mmcblk0pNN (that numbering
# can shift). This is the boot partition's PARTUUID from the device GPT
# (images/pgpt.bin) and matches the vendor bootargs. Add any further root=
# target the same way when the Debian rootfs lands on a device partition.
BOOT_PARTUUID = "c2635e15-61aa-454e-9c40-ebe1bdf19b9b"
DEFAULT_CMDLINE = (
    "bootopt=64S3,32N2,64N2 buildvariant=user "
    "androidboot.vbmeta.device=PARTUUID=" + BOOT_PARTUUID
)


def pad(n, page=PAGE_SIZE):
    return (n + page - 1) // page * page


def mtk_dtb_header(dtb_len):
    """64-byte big-endian MTK appended-DTB header.

    Field layout recovered by diffing the stock boot.img against its DTB:
      0x00 magic, 0x04 total size (header + dtb), 0x18 page size,
      0x20 dtb size, 0x24 header size. Everything else is zero.
    """
    total = MTK_DTB_HDR_SIZE + dtb_len
    words = [0] * 16
    words[0] = MTK_DTB_MAGIC
    words[1] = total
    words[2] = 0x20
    words[3] = 0x20
    words[4] = 0x01
    words[5] = 0x20
    words[6] = PAGE_SIZE
    words[7] = 0x00
    words[8] = dtb_len
    words[9] = MTK_DTB_HDR_SIZE
    return struct.pack(">16I", *words)


def boot_id(kernel, ramdisk, second):
    h = hashlib.sha1()
    for blob in (kernel, ramdisk, second):
        h.update(blob)
        h.update(struct.pack("<I", len(blob)))
    return h.digest()


def build(kernel, ramdisk, dtb, cmdline, image_size, out, kernel_append_dtb=True,
          kernel_addr=None):
    dtb_blob = mtk_dtb_header(len(dtb)) + dtb
    second = b""
    if kernel_addr is None:
        kernel_addr = KERNEL_ADDR

    # The stock image puts the DTB in *two* places: appended to the kernel
    # region (kernel_size counts it) and again after the ramdisk behind the
    # 64-byte MTK header. Reproduce that exactly -- LK is known to work with
    # this layout and we have no way to test the alternatives.
    kernel_region = kernel + dtb if kernel_append_dtb else kernel

    hdr = bytearray(HEADER_SIZE)
    struct.pack_into("<8s", hdr, 0, b"ANDROID!")
    struct.pack_into("<I", hdr, 0x08, len(kernel_region))
    struct.pack_into("<I", hdr, 0x0C, kernel_addr)
    struct.pack_into("<I", hdr, 0x10, len(ramdisk))
    struct.pack_into("<I", hdr, 0x14, RAMDISK_ADDR)
    struct.pack_into("<I", hdr, 0x18, len(second))
    struct.pack_into("<I", hdr, 0x1C, SECOND_ADDR)
    struct.pack_into("<I", hdr, 0x20, TAGS_ADDR)
    struct.pack_into("<I", hdr, 0x24, PAGE_SIZE)
    struct.pack_into("<I", hdr, 0x28, HEADER_VERSION)
    struct.pack_into("<I", hdr, 0x2C, OS_VERSION)
    struct.pack_into("<16s", hdr, 0x30, b"")
    struct.pack_into("<512s", hdr, 0x40, cmdline.encode()[:511])
    struct.pack_into("<32s", hdr, 0x240, boot_id(kernel, ramdisk, second))
    struct.pack_into("<1024s", hdr, 0x260, b"")
    # header v1 fields
    struct.pack_into("<I", hdr, 0x660, 0)            # recovery_dtbo_size
    struct.pack_into("<Q", hdr, 0x664, 0)            # recovery_dtbo_offset
    struct.pack_into("<I", hdr, 0x66C, HEADER_SIZE)  # header_size
    # header v2 fields
    struct.pack_into("<I", hdr, 0x670, len(dtb_blob))
    struct.pack_into("<Q", hdr, 0x674, TAGS_ADDR)

    body = bytearray()
    body += bytes(hdr)
    body += b"\x00" * (pad(len(body)) - len(body))
    body += kernel_region
    body += b"\x00" * (pad(len(body)) - len(body))
    ramdisk_off = len(body)
    body += ramdisk
    body += b"\x00" * (pad(len(body)) - len(body))
    dtb_off = len(body)
    body += dtb_blob
    body += b"\x00" * (pad(len(body)) - len(body))

    if image_size:
        if len(body) > image_size:
            sys.exit(f"ERROR: image needs {len(body)} bytes, partition is {image_size}")
        body += b"\x00" * (image_size - len(body))

    with open(out, "wb") as f:
        f.write(body)

    print(f"  output        : {out} ({len(body)} bytes)")
    print(f"  kernel region : {len(kernel_region)} @ 0x{PAGE_SIZE:x} "
          f"(gzip {len(kernel)} + dtb {len(dtb) if kernel_append_dtb else 0})")
    print(f"  ramdisk       : {len(ramdisk)} @ 0x{ramdisk_off:x}")
    print(f"  dtb blob      : {len(dtb_blob)} @ 0x{dtb_off:x} (dtb {len(dtb)})")
    print(f"  dtb_size field: {len(dtb_blob)}")


def graft_avb(img, stock_vbmeta, image_size):
    """Append a structurally valid AVB footer + a (stale) vbmeta blob.

    LK on this board reads the AVB footer when booting from the partition: an
    image without one crashes it (bootreason=lk_crash). Verification itself is
    NOT enforced while the bootloader is unlocked -- a vbmeta whose digest no
    longer matches still boots, which is exactly how Magisk-patched images
    work on this device.
    """
    import struct as _s
    # Work out where the real content ends from the header, not from len(img)
    # (the image is already padded to the partition size by build()).
    ps = _s.unpack_from("<I", img, 0x24)[0]
    ks = _s.unpack_from("<I", img, 0x08)[0]
    rs = _s.unpack_from("<I", img, 0x10)[0]
    dsz = _s.unpack_from("<I", img, 0x670)[0]
    def _pad(n):
        return (n + ps - 1) // ps * ps
    off = _pad(HEADER_SIZE)
    off = _pad(off + ks)
    off = _pad(off + rs)
    content_end = _pad(off + dsz)
    vb_size = len(stock_vbmeta)
    if content_end + vb_size + 64 > image_size:
        raise SystemExit("ERROR: no room for the AVB block")
    out = bytearray(img[:content_end])
    out += stock_vbmeta
    out += b"\x00" * (image_size - 64 - len(out))
    footer = bytearray(64)
    footer[0:4] = b"AVBf"
    _s.pack_into(">II", footer, 4, 1, 0)
    _s.pack_into(">QQQ", footer, 12, content_end, content_end, vb_size)
    out += footer
    return bytes(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--kernel", required=True)
    p.add_argument("--ramdisk", required=True)
    p.add_argument("--dtb", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--cmdline", default=DEFAULT_CMDLINE)
    p.add_argument("--allow-raw-kernel", action="store_true",
                   help="permit an uncompressed Image (LK may copy instead of inflate)")
    p.add_argument("--no-kernel-dtb", action="store_true",
                   help="do not append the DTB to the kernel region")
    p.add_argument("--stock-vbmeta", help="take the AVB footer/vbmeta from this stock image")
    p.add_argument("--image-size", type=int, default=32 * 1024 * 1024,
                   help="pad the image to this size (0 = no padding)")
    p.add_argument("--kernel-addr", type=lambda x: int(x, 0),
                    help="override boot header kernel_addr, e.g. 0x40000000")
    a = p.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    dtb = open(a.dtb, "rb").read()

    if kernel[:2] != b"\x1f\x8b" and not a.allow_raw_kernel:
        sys.exit("ERROR: kernel is not gzip (use --allow-raw-kernel to test that path)")
    if dtb[:4] != bytes.fromhex("d00dfeed"):
        sys.exit("ERROR: dtb does not start with the FDT magic")

    build(kernel, ramdisk, dtb, a.cmdline, a.image_size, a.output,
          kernel_append_dtb=not a.no_kernel_dtb, kernel_addr=a.kernel_addr)

    if a.stock_vbmeta:
        import struct as _s
        ref = open(a.stock_vbmeta, "rb").read()
        f = ref[-64:]
        _o, vb_off, vb_size = _s.unpack_from(">QQQ", f, 12)
        img = open(a.output, "rb").read()
        img = graft_avb(img, ref[vb_off:vb_off + vb_size], a.image_size)
        open(a.output, "wb").write(img)
        print(f"  avb grafted  : vbmeta {vb_size} B, footer at end")


if __name__ == "__main__":
    main()
