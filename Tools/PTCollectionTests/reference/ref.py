#!/usr/bin/env python3
"""Throwaway reference model of PTC v1 (final editor spec). Design check only."""
import struct, zlib, math, random, sys

SIG = bytes.fromhex("89505443 0d0a1a0a".replace(" ", ""))
SUPPORTED_MINOR = 0
MAX_ARCHIVE = 1 << 36
MIN_ARCHIVE = 67
MAX_CHUNK_PAYLOAD = 335_544_320
MAX_CHUNKS = 1 << 20
MAX_ITEMS = 100_000
MAX_IMAGE = 1 << 28
MAX_NOTES = 1 << 20
MAX_NAME = 1024
MAX_ID = 128
MAX_ICON = 128
MAX_SOFT = 256
MAX_TEXT = 1 << 26
DATE_MIN = -63_114_076_800.0
DATE_MAX = 63_113_904_000.0
W = set(list(range(0x09, 0x0E)) + [0x20, 0x85, 0xA0, 0x1680] + list(range(0x2000, 0x200C)) +
        [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
assert len(W) == 26
TAIL_HDR = b"\x00\x00\x00\x00TAIL"


class FmtError(Exception):
    def __init__(self, code, off=None, detail=None):
        super().__init__(code, off, detail)
        self.code = code


def u16(x): return struct.pack("<H", x)
def u32(x): return struct.pack("<I", x)
def f64(x): return struct.pack("<d", x)
def s(b): return u32(len(b)) + b


def encode(group, exported_at, items, soft=b"PictureTrack/1.0 (1)", minor=0, extra=None):
    """items: list of (id, notes, date, image). extra: {index_after_chunk: [ (type, payload) ]}"""
    gid, name, icon = group
    out = bytearray()
    crc = 0

    def emit(b):
        nonlocal crc
        crc = zlib.crc32(b, crc)
        out.extend(b)

    def emit_crc():
        out.extend(u32(crc))

    def chunk(t, p):
        emit(u32(len(p)) + t + p)
        emit_crc()

    emit(SIG + u16(1) + u16(minor))
    emit_crc()
    ed = 0.0 if exported_at == 0 else exported_at
    chunk(b"HEAD", u32(len(items)) + f64(ed) + s(gid) + s(name) + s(icon))
    n = 1
    if soft is not None:
        chunk(b"sOFT", soft)
    for x in (extra or {}).get("archive", []):
        chunk(*x)
    for i, (iid, notes, d, img) in enumerate(items):
        d = 0.0 if d == 0 else d
        chunk(b"ITEM", f64(d) + s(iid) + s(notes) + img)
        for x in (extra or {}).get(i, []):
            chunk(*x)
    chunk(b"TAIL", b"")
    return bytes(out)


def rd32(d, o): return struct.unpack_from("<I", d, o)[0]
def rd16(d, o): return struct.unpack_from("<H", d, o)[0]


def is_letter(b): return 0x41 <= b <= 0x5A or 0x61 <= b <= 0x7A


def decode(d):
    size = len(d)
    # R1 signature
    if size < 8 or d[:8] != SIG:
        if 1 <= size < 8 and d == SIG[:size]:
            raise FmtError("truncated", 0)
        for k in (1, 2, 3):
            if d[k:k + 3] == b"PTC":
                raise FmtError("textModeDamaged", 0)
        head = d[:64]
        i = 3 if head.startswith(b"\xef\xbb\xbf") else 0
        while i < len(head) and head[i] in (0x09, 0x0A, 0x0D, 0x20):
            i += 1
        if i < len(head) and head[i] == 0x7B:
            raise FmtError("legacyFormat", 0)
        raise FmtError("notAnArchive", 0)
    if size < 16:
        raise FmtError("truncated", 0)
    pcrc = zlib.crc32(d[:12])
    if pcrc != rd32(d, 12):
        raise FmtError("corrupted", 0)
    major, minor = rd16(d, 8), rd16(d, 10)
    if major != 1:
        raise FmtError("unsupportedVersion", 8, (major, minor))
    if size < MIN_ARCHIVE:
        raise FmtError("truncated", 0)
    if size > MAX_ARCHIVE:
        raise FmtError("tooLarge", 0)
    if d[size - 12:size - 4] != TAIL_HDR:
        raise FmtError("truncated", size - 12)
    pos, crc, state, chunks = 16, pcrc, "expectHead", 0
    item_count, items, text_budget, seen_soft = 0, [], MAX_TEXT, False
    group = exported = None

    def lim(field, off):
        return FmtError("limitExceeded", off, (field, minor))

    while True:
        rem = size - pos
        if rem < 12:
            raise FmtError("truncated", pos)
        L = rd32(d, pos)
        T = d[pos + 4:pos + 8]
        if not all(is_letter(b) for b in T):
            raise FmtError("corrupted", pos)
        if L > MAX_CHUNK_PAYLOAD:
            raise FmtError("corrupted", pos)
        if L > rem - 12:
            raise FmtError("truncated", pos)
        chunks += 1
        if chunks > MAX_CHUNKS:
            raise lim("chunkCount", pos)
        c2 = zlib.crc32(d[pos:pos + 8 + L], crc)
        if c2 != rd32(d, pos + 8 + L):
            raise FmtError("corrupted", pos)
        crc = c2
        c, e = pos + 8, pos + 8 + L

        def need(k):
            if k > e - c:
                raise FmtError("malformed", pos, "short payload")

        def getstr(field, mn, mx, allow_nul):
            nonlocal c, text_budget
            need(4)
            n = rd32(d, c); c += 4
            if n > mx:
                raise lim(field, pos)
            if n > e - c:
                raise FmtError("malformed", pos, field + " overruns")
            if n < mn:
                raise FmtError("malformed", pos, field + " empty")
            if field != "software":
                if n > text_budget:
                    raise lim("totalText", pos)
                text_budget -= n
            b = d[c:c + n]; c += n
            if not allow_nul and 0 in b:
                raise FmtError("invalidText", pos, field)
            try:
                return b.decode("utf-8", "strict")  # Python strict == RFC 3629 incl. surrogates
            except UnicodeDecodeError:
                raise FmtError("invalidText", pos, field)

        def getdate(field):
            nonlocal c
            need(8)
            bits = struct.unpack_from("<Q", d, c)[0]; c += 8
            v = 0.0 if bits == 0x8000000000000000 else struct.unpack("<d", struct.pack("<Q", bits))[0]
            if not math.isfinite(v) or not (DATE_MIN <= v <= DATE_MAX):
                raise FmtError("invalidDate", pos, field)
            return v

        if state == "expectHead" and T != b"HEAD":
            raise FmtError("malformed", pos, "HEAD must be first")
        if 0x41 <= T[0] <= 0x5A and T not in (b"HEAD", b"ITEM", b"TAIL"):
            raise FmtError("requiresNewerVersion", pos, (T, minor))
        if T == b"HEAD":
            if state != "expectHead":
                raise FmtError("malformed", pos, "duplicate HEAD")
            need(4)
            item_count = rd32(d, c); c += 4
            if item_count > MAX_ITEMS:
                raise lim("itemCount", pos)
            exported = getdate("exportedAt")
            gid = getstr("groupID", 1, MAX_ID, False)
            name = getstr("name", 1, MAX_NAME, False)
            icon = getstr("icon", 1, MAX_ICON, False)
            if c != e:
                raise FmtError("malformed", pos, "HEAD trailing bytes")
            if not any(ord(ch) not in W for ch in name):
                raise FmtError("invalidGroupName", pos)
            group = (gid, name, icon)
            state = "archiveScope"
        elif T == b"ITEM":
            if len(items) == item_count:
                raise FmtError("malformed", pos, "more items than declared")
            dt = getdate("dateCreated")
            iid = getstr("itemID", 1, MAX_ID, False)
            notes = getstr("notes", 0, MAX_NOTES, True)
            m = e - c
            if m < 1:
                raise FmtError("malformed", pos, "no image")
            if m > MAX_IMAGE:
                raise lim("image", pos)
            items.append((iid, notes, dt, (c, e)))
            state = "itemScope"
        elif T == b"TAIL":
            if L != 0:
                raise FmtError("malformed", pos, "TAIL not empty")
            if len(items) != item_count:
                raise FmtError("malformed", pos, "fewer items than declared")
            if pos + 12 != size:
                raise FmtError("trailingData", pos + 12)
            return dict(minor=minor, exportedAt=exported, group=group,
                        items=[(a, b, dt, d[x:y]) for a, b, dt, (x, y) in items])
        elif T == b"sOFT":
            if state != "archiveScope" or seen_soft:
                raise FmtError("malformed", pos, "sOFT misplaced")
            if L > MAX_SOFT:
                raise lim("software", pos)
            if L < 1:
                raise FmtError("malformed", pos, "sOFT empty")
            b = d[c:e]
            if 0 in b:
                raise FmtError("invalidText", pos, "software")
            try:
                b.decode("utf-8", "strict")
            except UnicodeDecodeError:
                raise FmtError("invalidText", pos, "software")
            seen_soft = True
        # else: unknown ancillary, skip
        pos += 12 + L


def hexdump(b):
    lines = []
    for i in range(0, len(b), 16):
        lines.append("%04x: %s" % (i, " ".join("%02x" % x for x in b[i:i + 16])))
    return "\n".join(lines)


GA = (b"00000000-0000-4000-8000-000000000001", b"Run", b"figure.run")
VA = encode(GA, 815000000.5, [])
VB = encode(GA, 815000000.5, [(b"00000000-0000-4000-8000-000000000002", "hi é".encode(), 815000000.25, b"\xff\xd8\xff\xd9")])
VC = encode((b"g", b"R", b"x"), 0.0, [], soft=None)
VD = encode(GA, 815000000.5, [(b"00000000-0000-4000-8000-000000000002", "hi é".encode(), 815000000.25, b"\xff\xd8\xff\xd9")],
            minor=1, extra={0: [(b"tEST", b"x")]})
VE = encode(GA, 815000000.5, [(b"00000000-0000-4000-8000-000000000002", "hi é".encode(), 815000000.25, b"\xff\xd8\xff\xd9")],
            minor=1, extra={0: [(b"XTST", b"x")]})

if __name__ == "__main__":
    for nm, v in (("A", VA), ("B", VB), ("C", VC), ("D", VD), ("E", VE)):
        print("== vector", nm, len(v), "bytes")
        print(hexdump(v))
        try:
            r = decode(v)
            print("decoded:", r["group"], r["exportedAt"], [(a, b, dt, x.hex()) for a, b, dt, x in r["items"]])
        except FmtError as ex:
            print("rejected:", ex.args)
