#!/usr/bin/env python3
"""Generates a shared corpus of mutated PTC files and the reference model's verdict for each.
usage: python3 -I gen.py <ref_dir> <out_dir> <count> <seed>"""
import sys, struct, zlib, random, os
sys.path.insert(0, sys.argv[1])
from ref import encode, decode, FmtError, VA, VB, VC, VD, VE, GA, MAX_CHUNK_PAYLOAD

out_dir, count, seed = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rng = random.Random(seed)

two = encode(GA, 1.0, [(b"i1", b"a", 2.0, b"\x01\x02\x03\x04"), (b"i2", b"b", 3.0, b"\x05\x06\x07\x08")])
rich = encode((GA[0], "Lifting 🏋️ log".encode(), b"dumbbell"), 815000000.5,
              [(b"a", "first é 日本 \x00".encode(), 815000000.25, b"\xaa" * 40),
               (b"b", b"", -0.0, b"\xff"), (b"c", b"x", 5e-324, b"\x11" * 300)],
              minor=1, extra={"archive": [(b"tEST", b"\x01\x02\x03")], 0: [(b"cROP", b"\x00" * 32)], 2: [(b"tAGs", b"\x01\x00\x00\x00\x03\x00\x00\x00leg")]})
seeds = [VA, VB, VC, VD, VE, two, rich, b'{\n  "exportedAt" : "2026"\n}']
INT32 = [0, 1, 2, 4, 7, 8, 12, 16, 128, 129, 256, 257, 1024, 1025, 100000, 100001, 1 << 20, (1 << 20) + 1, 1 << 26, (1 << 26) + 1,
         1 << 28, (1 << 28) + 1, MAX_CHUNK_PAYLOAD, MAX_CHUNK_PAYLOAD + 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
DATES = [0, 0x8000000000000000, 1, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000,
         struct.unpack("<Q", struct.pack("<d", 63113904000.0))[0], struct.unpack("<Q", struct.pack("<d", 63113904000.0))[0] + 1,
         struct.unpack("<Q", struct.pack("<d", -63114076800.0))[0], struct.unpack("<Q", struct.pack("<d", -63114076800.0))[0] + 1]
BAD = [b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe2\x82", b"\x80", b"\x00", b"\xff"]
TYPES = [b"HEAD", b"ITEM", b"TAIL", b"sOFT", b"tEST", b"XTST", b"ITEm", b"SOFT", b"soft", b"H1AD", b"\x00\x00\x00\x00"]

def chunks_of(b):
    pos, out = 16, []
    while len(b) - pos >= 12:
        L = struct.unpack_from("<I", b, pos)[0]
        if L > len(b) - pos - 12: return None
        out.append([b[pos+4:pos+8], bytearray(b[pos+8:pos+8+L])])
        pos += 12 + L
    return out if pos == len(b) else None

def rechain(pre12, chs):
    out = bytearray(pre12); crc = zlib.crc32(pre12); out += struct.pack("<I", crc)
    for t, p in chs:
        body = struct.pack("<I", len(p)) + bytes(t) + bytes(p)
        crc = zlib.crc32(body, crc); out += body + struct.pack("<I", crc)
    return bytes(out)

def fix(b):
    b = bytearray(b)
    if len(b) < 16: return bytes(b)
    crc = zlib.crc32(bytes(b[:12])); b[12:16] = struct.pack("<I", crc); pos = 16
    while len(b) - pos >= 12:
        L = struct.unpack_from("<I", b, pos)[0]
        if L > len(b) - pos - 12: break
        crc = zlib.crc32(bytes(b[pos:pos+8+L]), crc); b[pos+8+L:pos+12+L] = struct.pack("<I", crc); pos += 12 + L
    return bytes(b)

def raw(b):
    b = bytearray(b)
    for _ in range(rng.randint(1, 6)):
        op = rng.randrange(8)
        if op == 0 and b: i = rng.randrange(len(b) * 8); b[i >> 3] ^= 1 << (i & 7)
        elif op == 1 and b: b[rng.randrange(len(b))] = rng.randrange(256)
        elif op == 2: b[rng.randrange(len(b) + 1):0] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 4)))
        elif op == 3 and b: i = rng.randrange(len(b)); del b[i:i + rng.randint(1, 4)]
        elif op == 4 and len(b) >= 4: i = rng.randrange(len(b) - 3); b[i:i+4] = struct.pack("<I", rng.choice(INT32))
        elif op == 5: del b[max(0, len(b) - rng.randint(1, 32)):]
        elif op == 6: b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 16)))
        elif op == 7 and len(b) >= 2:
            n = rng.randint(1, min(16, len(b) - 1)); s = rng.randrange(len(b) - n + 1); d = rng.randrange(len(b) - n + 1); b[d:d+n] = b[s:s+n]
    return bytes(b)

def structural(b):
    chs = chunks_of(b)
    if chs is None: return raw(b)
    pre = bytearray(b[:12])
    for _ in range(rng.randint(1, 3)):
        if not chs: break
        i = rng.randrange(len(chs)); t, p = chs[i]; op = rng.randrange(10)
        if op == 0 and t == b"HEAD" and len(p) >= 4: p[0:4] = struct.pack("<I", rng.choice(INT32))
        elif op == 1 and t in (b"HEAD", b"ITEM"):
            at = 12 if t == b"HEAD" else 8; k = rng.randrange(3 if t == b"HEAD" else 2)
            for _ in range(k):
                if at + 4 > len(p): break
                at += 4 + struct.unpack_from("<I", p, at)[0]
            if at + 4 <= len(p): p[at:at+4] = struct.pack("<I", rng.choice(INT32))
        elif op == 2 and t in (b"HEAD", b"ITEM"):
            o = 4 if t == b"HEAD" else 0
            if len(p) >= o + 8: p[o:o+8] = struct.pack("<Q", rng.choice(DATES) if rng.random() < 0.7 else rng.getrandbits(64))
        elif op == 3 and p:
            j = rng.randrange(len(p)); bad = rng.choice(BAD); p[j:j+len(bad)] = bad
        elif op == 4 and p: p[rng.randrange(len(p))] = rng.randrange(256)
        elif op == 5: chs.insert(rng.randrange(len(chs) + 1), [rng.choice(TYPES), bytearray(rng.randrange(256) for _ in range(rng.randrange(12)))])
        elif op == 6: del chs[i]
        elif op == 7: chs.insert(rng.randrange(len(chs) + 1), [t, bytearray(p)])
        elif op == 8: j = rng.randrange(len(chs)); chs[i], chs[j] = chs[j], chs[i]
        elif op == 9: pre[8 + rng.randrange(4)] = rng.randrange(256)
    return rechain(bytes(pre), chs)

def verdict(b):
    try:
        r = decode(b)
    except FmtError as e:
        code, off, detail = e.args
        field = ""
        if code == "limitExceeded": field = detail[0]
        elif code in ("invalidText", "invalidDate"): field = detail
        return "%s %d %s" % (code, off if off is not None else -1, field)
    h = bytearray()
    def s(x): h.extend(struct.pack("<I", len(x)) + x)
    gid, name, icon = r["group"]
    for x in (gid, name, icon): s(x if isinstance(x, bytes) else x.encode("utf-8"))
    h.extend(struct.pack("<d", r["exportedAt"]))
    for iid, notes, dt, img in r["items"]:
        s(iid.encode("utf-8")); s(notes.encode("utf-8")); h.extend(struct.pack("<d", dt)); s(bytes(img))
    return "accepted %d %d %08x" % (r["minor"], len(r["items"]), zlib.crc32(bytes(h)))

with open(os.path.join(out_dir, "corpus.bin"), "wb") as fc, open(os.path.join(out_dir, "expected.txt"), "w") as fe:
    cases = []
    for v in (VA, VB, VC, VD, VE, two, rich): cases.append(v)
    while len(cases) < count:
        b = rng.choice(seeds); k = rng.randrange(3)
        cases.append(raw(b) if k == 0 else structural(b) if k == 1 else fix(raw(b)))
    for b in cases:
        fc.write(struct.pack("<I", len(b)) + b)
        fe.write(verdict(b) + "\n")
    # Byte-for-byte vectors and the two-item / rich files for the Swift side.
    for name, v in (("A", VA), ("B", VB), ("C", VC), ("D", VD), ("E", VE), ("two", two), ("rich", rich)):
        open(os.path.join(out_dir, "vec-%s.bin" % name), "wb").write(v)
print("generated", len(cases), "cases")
