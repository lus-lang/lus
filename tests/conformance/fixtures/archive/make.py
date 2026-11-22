"""Writes the archive fixtures of archive_test.lus.

The well-formed archives come from Python's zipfile and tarfile, which are
independent writers of the same formats. The hostile archives are built by
hand to try path traversal, symbolic link escapes, overlapping ZIP entries,
and headers that lie about sizes and checksums. Run it from this directory
with python3. The output is deterministic.
"""

import io
import struct
import tarfile
import zipfile

MTIME = 1700000000


def zinfo(name, mode=0o644, method=zipfile.ZIP_DEFLATED):
    zi = zipfile.ZipInfo(name, date_time=(2023, 11, 14, 22, 13, 20))
    zi.create_system = 3
    zi.external_attr = mode << 16
    zi.compress_type = method
    return zi


def write_zip(path, entries, force_zip64=False):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for zi, data in entries:
            with z.open(zi, "w", force_zip64=force_zip64) as f:
                f.write(data)
    open(path, "wb").write(buf.getvalue())
    return buf.getvalue()


def tinfo(name, kind=tarfile.REGTYPE, size=0, mode=0o644, link=""):
    ti = tarfile.TarInfo(name)
    ti.type = kind
    ti.size = size
    ti.mode = mode
    ti.mtime = MTIME
    ti.linkname = link
    return ti


def write_tar(path, entries, fmt=tarfile.PAX_FORMAT):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=fmt) as t:
        for ti, data in entries:
            t.addfile(ti, io.BytesIO(data) if data is not None else None)
    open(path, "wb").write(buf.getvalue())


TEXT = b"The quick brown fox jumps over the lazy dog.\n" * 40
LONG = "long/" + "x" * 120 + "/name.txt"

# Well-formed ZIP archives.
write_zip("python.zip", [
    (zinfo("dir/", 0o40755, zipfile.ZIP_STORED), b""),
    (zinfo("dir/text.txt"), TEXT),
    (zinfo("dir/run.sh", 0o100755), b"#!/bin/sh\necho hi\n"),
    (zinfo("stored.bin", 0o100644, zipfile.ZIP_STORED), bytes(range(256))),
    (zinfo("café.txt"), "café\n".encode()),
])
write_zip("zip64.zip", [(zinfo("big.txt"), TEXT), (zinfo("small.txt", method=zipfile.ZIP_STORED), b"small\n")], force_zip64=True)

# Well-formed tar archives in the three layouts.
for fmt, path in ((tarfile.USTAR_FORMAT, "ustar.tar"), (tarfile.GNU_FORMAT, "gnu.tar"), (tarfile.PAX_FORMAT, "pax.tar")):
    entries = [
        (tinfo("dir/", tarfile.DIRTYPE, mode=0o755), None),
        (tinfo("dir/text.txt", size=len(TEXT)), TEXT),
        (tinfo("dir/run.sh", size=18, mode=0o755), b"#!/bin/sh\necho hi\n"),
        (tinfo("link", tarfile.SYMTYPE, mode=0o777, link="dir/text.txt"), None),
    ]
    if fmt != tarfile.USTAR_FORMAT:
        entries.append((tinfo(LONG, size=5), b"long\n"))
        entries.append((tinfo("café.txt", size=6), "café\n".encode()))
    write_tar(path, entries, fmt)

# Hostile tar archives.
write_tar("traversal.tar", [(tinfo("../evil.txt", size=5), b"evil\n")])
write_tar("absolute.tar", [(tinfo("/tmp/lus-evil.txt", size=5), b"evil\n")])
write_tar("link-escape.tar", [(tinfo("sub/esc", tarfile.SYMTYPE, link="../../outside"), None)])
write_tar("link-absolute.tar", [(tinfo("esc", tarfile.SYMTYPE, link="/etc"), None)])
write_tar("link-chain.tar", [
    (tinfo("d1/", tarfile.DIRTYPE, mode=0o755), None),
    (tinfo("d1/up", tarfile.SYMTYPE, link=".."), None),
    (tinfo("esc", tarfile.SYMTYPE, link="d1/up/.."), None),
])
write_tar("link-write.tar", [
    (tinfo("sub/", tarfile.DIRTYPE, mode=0o755), None),
    (tinfo("l", tarfile.SYMTYPE, link="sub"), None),
    (tinfo("l/x.txt", size=5), b"evil\n"),
])
write_tar("hardlink.tar", [(tinfo("a.txt", size=2), b"a\n"), (tinfo("b.txt", tarfile.LNKTYPE, link="a.txt"), None)])
write_tar("device.tar", [(tinfo("null", tarfile.CHRTYPE), None)])

# Hostile ZIP archives.
write_zip("traversal.zip", [(zinfo("../evil.txt"), b"evil\n")])
write_zip("absolute.zip", [(zinfo("/tmp/lus-evil.txt"), b"evil\n")])
write_zip("backslash.zip", [(zinfo("..\\evil.txt"), b"evil\n")])
write_zip("link-escape.zip", [(zinfo("esc", 0o120777, zipfile.ZIP_STORED), b"../outside")])

good = write_zip("crc.zip", [(zinfo("a.txt", method=zipfile.ZIP_STORED), b"hello\n")])
bad = bytearray(good)
bad[bad.index(b"hello")] ^= 0x20
open("crc.zip", "wb").write(bytes(bad))

# Two central directory records that point at the same local header.
one = write_zip("overlap.zip", [(zinfo("a.txt"), TEXT)])
end = one.rindex(b"PK\x05\x06")
cd_off = struct.unpack_from("<I", one, end + 16)[0]
cd = one[cd_off:end]
eocd = bytearray(one[end:])
struct.pack_into("<HHII", eocd, 8, 2, 2, len(cd) * 2, cd_off)
open("overlap.zip", "wb").write(one[:cd_off] + cd + cd + bytes(eocd))

# A central directory that claims fewer bytes than the data holds.
lie = bytearray(write_zip("sizelie.zip", [(zinfo("a.txt"), TEXT)]))
end = lie.rindex(b"PK\x05\x06")
cd_off = struct.unpack_from("<I", lie, end + 16)[0]
struct.pack_into("<I", lie, cd_off + 24, 100)
open("sizelie.zip", "wb").write(bytes(lie))

# An entry marked as encrypted.
enc = bytearray(write_zip("encrypted.zip", [(zinfo("a.txt", method=zipfile.ZIP_STORED), b"hello\n")]))
struct.pack_into("<H", enc, 6, 1)
end = enc.rindex(b"PK\x05\x06")
cd_off = struct.unpack_from("<I", enc, end + 16)[0]
struct.pack_into("<H", enc, cd_off + 8, 1)
open("encrypted.zip", "wb").write(bytes(enc))
