# PTC v1: PictureTrack binary collection container (normative specification)

Format version 1.0 (major 1, minor 0). MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. This document is self-sufficient: a conforming reader or writer can be built from it alone.

---

## 0. Scope and identity

- A `.ptcollection` file holds exactly ONE collection:
  - a group: originalID (String), name (String, non-blank), icon (String, an SF Symbol name);
  - exportedAt (Date);
  - N items, each with originalID (String), notes (String, may be empty or long), dateCreated (Date) and image bytes. Image bytes are opaque and stored exactly as on disk (JPEG, HEIC, ...).
- UTType `com.maxxu.picturetrack.collection`, filename extension `ptcollection`, conforming to `public.data`, MIME type `application/vnd.picturetrack.collection`. In Swift: `UTType(exportedAs: "com.maxxu.picturetrack.collection", conformingTo: .data)`.
- A file is identified by its content (signature, preamble CRC and major version), never by its name or extension.
- The legacy JSON+base64 `.ptcollection` format is not readable. Readers report it as `legacyFormat` (section 9.1).

---

## 1. Conventions

1. **Integers.** `u16`, `u32` and `u64` are unsigned, little-endian and fixed width. The format has no varints, no signed integers, no padding and no alignment. Swift MUST read them with `withUnsafeBytes { UIntN(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UIntN.self)) }`. `load(fromByteOffset:as:)` MUST NOT be used, because it traps on misaligned offsets.
2. **f64.** IEEE 754 binary64, stored as the `u64` (LE) of its `bitPattern`.
3. **str.** A `u32 n`, then exactly `n` bytes of UTF-8.
   - There is no terminator, no BOM handling (a leading EF BB BF is the ordinary scalar U+FEFF) and no Unicode normalization. Bytes are preserved exactly.
   - "Well-formed UTF-8" follows Unicode section 3.9 / RFC 3629: no overlong forms, no surrogates U+D800 to U+DFFF, nothing above U+10FFFF, no truncated sequences. This is exactly the set accepted by Swift's `String(validating: bytes, as: UTF8.self)` (verified on iOS 27.1 SDK / macOS 27.2: it rejects `C0 80`, `ED A0 80`, `F4 90 80 80` and `E2 82`).
   - `String(decoding:as:)` MUST NOT be used, because it silently repairs invalid input.
4. **date.** An f64 holding `Date.timeIntervalSinceReferenceDate` (section 6.3).
5. **Offsets.** Offsets count from file byte 0, and `[a, b)` is half-open. In Swift, file byte `p` is `data[data.startIndex + p]`. A mapped `Data`, or a slice of one, need not start at index 0, so every index MUST be computed from `startIndex`.
6. **CRC-32.** The algorithm is CRC-32/ISO-HDLC, i.e. zlib/PNG/gzip:
   - polynomial 0x04C11DB7 (reflected 0xEDB88320), init 0xFFFFFFFF, reflected input and output, xorout 0xFFFFFFFF;
   - check value: `crc("123456789") = 0xCBF43926`.
   - Swift: `import zlib`, then `UInt32(truncatingIfNeeded: crc32_z(uLong(seed), ptr, len))`, where `seed` is the previous CRC value (0 to start) and `len` is a size_t.
   - Use `crc32_z`, not `crc32`, whose length parameter is a 32-bit `uInt`.
   - Never pass a nil pointer: zlib returns 0 for a null buffer regardless of the seed. Never pass an empty piece. Every CRC span in this format is at least 8 bytes.
   - Continuation property: `crc32_z(crc32_z(0, A), B) == crc32_z(0, A || B)`. Python: `zlib.crc32(data, seed)`.
   - Stored CRC values are `u32` LE.

---

## 2. File structure

```
file      = preamble HEAD *ANC *( ITEM *ANC ) TAIL EOF
preamble  = 16 bytes                                   (section 3)
chunk     = u32 L | type[4] | payload[L] | u32 crc     (section 4)
ANC       = any ancillary chunk (type byte 0 lowercase)
```

- HEAD MUST start at offset 16.
- There are exactly `HEAD.itemCount` ITEM chunks.
- TAIL is the last chunk, and its crc field ends exactly at EOF. No byte follows it.
- **Archive scope** is the region after HEAD and before the first ITEM (or before TAIL if there are no items).
- **Item scope** of item i is the region after ITEM i and before the next ITEM or TAIL.
- v1.0 defines four chunk types: `HEAD`, `ITEM` and `TAIL` (critical) and `sOFT` (ancillary).
- The smallest valid file is 67 bytes (vector C). The smallest ITEM chunk is 30 bytes.

---

## 3. Preamble (offset 0, 16 bytes)

The layout of these 16 bytes is FROZEN for every major version, so a reader of any age can always identify the file and its version.

| Off | Size | Type | Field | v1.0 value |
|---|---|---|---|---|
| 0 | 8 | bytes | signature | `89 50 54 43 0D 0A 1A 0A` ("\x89PTC\r\n\x1A\n") |
| 8 | 2 | u16 | major | `01 00` (1) |
| 10 | 2 | u16 | minor | `00 00` (0) |
| 12 | 4 | u32 | preambleCRC | CRC-32 of bytes [0, 12) |

For writers of 1.0 the preamble is the constant `89 50 54 43 0D 0A 1A 0A 01 00 00 00 6C 43 D1 C6` (preambleCRC 0xC6D1436C).

What the signature bytes detect:

| Byte(s) | Detects |
|---|---|
| 0x89 (high bit set) | 7-bit stripping (it becomes 0x09). Latin-1 to UTF-8 transcoding (it becomes C2 89). A lossy UTF-8 decode and re-encode (it becomes EF BF BD). It also stops text sniffers from treating the file as text. |
| "PTC" | readable in hex dumps |
| 0D 0A | CRLF to LF conversion |
| 1A | Ctrl-Z, which stops DOS `type` |
| final 0A | LF to CRLF conversion |

---

## 4. Chunk framing and the chained CRC

| Rel. off | Size | Type | Field |
|---|---|---|---|
| +0 | 4 | u32 | L = payload length, 0 <= L <= MAX_CHUNK_PAYLOAD (335,544,320) for EVERY type, including unknown ones |
| +4 | 4 | bytes | type (FourCC) |
| +8 | L | bytes | payload |
| +8+L | 4 | u32 | crc |

The next chunk starts at +12+L.

**Chained CRC (normative).** Number the CRC fields in file order: C0 is the preambleCRC at offset 12, and Ck is the crc field of the k-th chunk.
- `C0 = crc32_z(0, file[0, 12))`.
- `Ck = crc32_z(C(k-1), file[pos_k, pos_k + 8 + L_k))`. That is, each chunk's CRC covers its own length, type and payload, seeded with the previous CRC field's value.
- Equivalently, Ck is the CRC-32 of every file byte from offset 0 to the end of chunk k's payload, EXCLUDING the bytes of all CRC fields.
- CRC field bytes MUST NOT be fed into the running CRC. This is a known pitfall: the CRC-32 of any message followed by its own LE CRC is the constant residue 0x2144DF1C, so including the fields would reset the chain at every chunk and let whole chunks be reordered undetected. This was verified with the reference model.

**Type code rules.** Each of the 4 type bytes MUST be an ASCII letter (0x41 to 0x5A or 0x61 to 0x7A). Types are compared as exact bytes, so comparison is case-sensitive.

| Byte | Uppercase | Lowercase |
|---|---|---|
| 0 | critical: a reader that does not know the type MUST reject the file | ancillary: a reader that does not know the type MUST skip it |
| 1 | public: assigned only by this spec | private: for third-party tools, never assigned by this spec |
| 2 | used in every spec-assigned type | reserved. Readers MUST NOT reject because of it. |
| 3 | (ancillary only) unsafe-to-copy | (ancillary only) safe-to-copy. Only editing tools use this bit. |

Readers decide behavior from byte 0 alone, after the letter check.

---

## 5. Chunk types defined in v1.0

### 5.1 HEAD (`48 45 41 44`), critical

There is exactly one HEAD, at offset 16. L MUST equal exactly 24 + a + b + c; the maximum is 1,304.

| Payload off | Size | Type | Field | Constraint |
|---|---|---|---|---|
| 0 | 4 | u32 | itemCount | 0 to 100,000 (an empty collection is valid) |
| 4 | 8 | date | exportedAt | section 6.3 |
| 12 | 4+a | str | group.originalID | 1 to 128 bytes, no 0x00 |
| 16+a | 4+b | str | group.name | 1 to 1,024 bytes, no 0x00, non-blank (section 6.2), stored untrimmed |
| 20+a+b | 4+c | str | group.icon | 1 to 128 bytes, no 0x00 |

### 5.2 ITEM (`49 54 45 4D`), critical

There are exactly itemCount ITEM chunks, all after HEAD. The minimum L is 18 and the maximum is 269,484,176.

| Payload off | Size | Type | Field | Constraint |
|---|---|---|---|---|
| 0 | 8 | date | dateCreated | section 6.3 |
| 8 | 4+a | str | item.originalID | 1 to 128 bytes, no 0x00 |
| 12+a | 4+n | str | notes | 0 to 1,048,576 bytes, U+0000 ALLOWED |
| 16+a+n | m | bytes | image | m = L - (16 + a + n), with 1 <= m <= 268,435,456 |

- The image has NO length field: it is every remaining payload byte. Its zero-copy slice is file bytes `[pos+24+a+n, pos+8+L)`, i.e. `data[base+pos+24+a+n ..< base+pos+8+L]`.
- The format never inspects image bytes. The app applies its own check (section 11.4).

### 5.3 TAIL (`54 41 49 4C`), critical

There is exactly one TAIL, and it is the last chunk, with L = 0. The final 12 bytes of every valid file are therefore `00 00 00 00 54 41 49 4C` followed by the last chained CRC.

### 5.4 sOFT (`73 4F 46 54`), ancillary, public, unsafe-to-copy

- Payload: raw UTF-8 with no length prefix (L is the length), 1 to 256 bytes, no 0x00. It identifies the writer, e.g. `PictureTrack/1.0 (1)`.
- At most one sOFT is allowed, and only in archive scope.
- Writers MUST emit it immediately after HEAD. This is a forcing function: every real file then exercises the reader's ancillary-chunk path.
- Readers MUST validate sOFT and reject the file if it is invalid or misplaced. Readers MUST NOT require it, and it MUST NOT affect the import.

### 5.5 Unknown types

- **Lowercase byte 0:** skip the chunk after its CRC is verified. It is allowed anywhere after HEAD and before TAIL, its payload is never interpreted or allocated, and it counts toward MAX_CHUNKS.
- **Uppercase byte 0:** reject with `requiresNewerVersion`.

---

## 6. Field rules

### 6.1 Strings

| Field | Min | Max | 0x00 allowed | Extra rule | Counts toward MAX_TOTAL_TEXT |
|---|---|---|---|---|---|
| group.originalID | 1 | 128 | no | none | yes |
| group.name | 1 | 1,024 | no | non-blank (6.2) | yes |
| group.icon | 1 | 128 | no | none (an unknown symbol maps to the app default at import) | yes |
| item.originalID | 1 | 128 | no | none | yes |
| notes | 0 | 1,048,576 | YES | none | yes |
| sOFT payload | 1 | 256 | no | none | no |

- Every string MUST be well-formed UTF-8.
- MAX_TOTAL_TEXT = 67,108,864 bytes, summed over all counted fields in the file.
- originalIDs are informational only. Uniqueness is not required or checked, and they MUST NOT be used as file names, paths or keys. Import assigns fresh UUIDs.

### 6.2 Non-blank name

W is this pinned set of 26 scalars:
- U+0009 to U+000D
- U+0020, U+0085, U+00A0, U+1680
- U+2000 to U+200B
- U+2028, U+2029, U+202F, U+205F, U+3000

A name is valid only if it contains at least one Unicode scalar NOT in W. W equals Foundation's `CharacterSet.whitespacesAndNewlines` on macOS 27.2 (verified by enumerating all scalars). It is pinned so that a future Foundation cannot make two app versions disagree. The app's add-group UI MUST use the same predicate.

### 6.3 Dates

- **Value.** v = `Date.timeIntervalSinceReferenceDate`: SI seconds since the Foundation reference date **2001-01-01T00:00:00Z**. It is an absolute UTC instant with no time zone and no leap seconds (every day is 86,400 s). Unix time = v + 978,307,200 is informational only. Implementations MUST NOT convert through Unix time: the offset arithmetic changed the bits of 50,002 of 100,000 sampled values (measured).
- **Encoding.** `u64 LE = v.bitPattern`, verbatim.
- **Decoding.** `Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(littleEndian: raw)))`.
- **Valid values.** Finite, with -63,114,076,800.0 <= v <= 63,113,904,000.0 (exactly `Date.distantPast` and `Date.distantFuture`, verified). Subnormals are allowed.
- **Zero.** Writers MUST write +0.0 (all bits 0) for any zero. Readers MUST decode the bit pattern 0x8000000000000000 as +0.0 and accept it. Reason: a SwiftData on-disk store turns -0.0 into -1.52587890625e-05 (measured independently twice). +0.0 and -0.0 are equal Dates.
- **Precision.** Full binary64. The ulp at 2026 dates is 2^-23 s, about 1.19e-7 s, so sub-microsecond precision is preserved.
- **Round trips.** Encoding and decoding are bit-exact. SwiftData's on-disk store keeps Date as seconds since 2001, in SQLite as REAL, or INTEGER when the value is integral. It was measured bit-exact for 0, subnormals, 1e-300, 0.1, current dates, distantPast, distantFuture and 2,008 random values. The only exception is -0.0, which the zero rule neutralizes. That iOS behaves the same is an inference, since it is the same framework.
- **Rejected alternatives.** Int64 nanoseconds or microseconds would not round-trip (6.9% and 88% failures measured). ISO-8601 JSON drops sub-second precision.

---

## 7. Integrity

### 7.1 Mechanism

Integrity rests on three things: the preamble CRC, a chained CRC-32 on every chunk (section 4), and the strict grammar (sections 2 and 9). There is no whole-file SHA-256, no directory and no index.

### 7.2 Verify before interpreting

- Before a chunk's CRC passes, the reader reads only that chunk's 8-byte header. L is used only to bound the CRC span, after the letter, cap and remaining-bytes checks.
- No payload field, count or version is acted on before the CRC covering it has matched. Through the chain, that CRC also covers every earlier byte of the file.
- The major version is acted on only after the preamble CRC matches, so a flipped version bit is reported as `corrupted`, not "update the app".

### 7.3 Guarantees (accidental damage)

1. **Small errors are detected deterministically in a file of any size.** This covers every error of 1 or 2 bits and every burst of 32 bits or fewer, unless the damage alters a chunk length field (see item 6).
   - The generator is primitive: x has order 2^32-1 modulo G (verified by a period proof).
   - Every chunk codeword `[pos, pos+12+L)` is at most 2,684,354,656 bits, which is less than 2^32-1. The preamble codeword is 128 bits.
   - The reader stops at the first chunk that contains damage, and only the damage inside that chunk affects its check.
2. **Other damage** escapes with probability of about 2^-32 per damage event.
3. **Truncation at any point** fails the fast end check (R6) or the chunk loop.
   - Appended bytes fail R6 or produce `trailingData`.
   - `cat a b` produces `trailingData`.
4. **Dropped, duplicated or reordered chunks, bytes swapped between items, and ITEM chunks spliced in from another archive** all change the chain input at the first displaced chunk, so they are caught with probability 1-2^-32. Verified cases: a verbatim swap of two ITEM chunks, a swap of two images' bytes, and a duplicated or dropped ITEM. All were rejected.
5. **Text-mode conversion** breaks the signature, and the chain catches the same conversion anywhere else in the file. A zero-filled hole fails the type-letter check or the CRC.
6. **A damaged length field** moves where the CRC is read from. It is then caught by the CRC comparison plus the letter, bounds and grammar checks, with probability of about 1-2^-32 (not by the algebraic guarantee).
7. **Image completeness.** The CRC guarantees the image bytes are identical to what was exported. ImageIO cannot check this: half a JPEG still reports public.jpeg with count 1.

### 7.4 Not provided

The format provides no authenticity and no confidentiality. The CRC is unkeyed, so a hostile file can carry valid CRCs. The bounds-checked parser and the limits (sections 8 and 9) are the security boundary and MUST hold on their own. Fuzzing MUST therefore bypass the CRC with a "CRC fixer" that recomputes the chain after mutating a file.

### 7.5 Why CRC-32 (zlib) rather than SHA-256 (CryptoKit)

1. **Threat model.** The threat is accidental damage. An unkeyed SHA-256 can be recomputed by anyone who edits the file, so it adds no tamper evidence. Its only gain is moving the random-miss rate from 2^-32 to 2^-256.
2. **Cost.** Throughput measured on this M5 Mac over 1 GiB, by two independent probes:
   - zlib crc32: 9.3 to 9.5 GB/s;
   - CryptoKit SHA-256: 3.2 to 3.3 GB/s.

   That is about 3x less CPU and battery on every export and import.
3. **Streaming.** The chained CRC is checked as the file is parsed: one pass, fail-fast at the first damaged chunk, and the error is located to a byte offset and item. Garbage is rejected after at most one chunk of hashing, and no CryptoKit dependency is needed.
4. **Ordering protection at no extra cost.** Chaining gives the same sequence and binding protection that made a whole-file digest attractive.
5. **Parallelism and portability.** `crc32_combine` permits parallel verification (section 9.6). The CRC is also universal (Python `zlib.crc32`, Java `CRC32`, Go `crc32.ChecksumIEEE`).

---

## 8. Limits (normative for 1.0)

Writers MUST NOT exceed these limits, and readers MUST reject files that do.

| Constant | Value | Raisable in a minor? |
|---|---|---|
| MIN_ARCHIVE_BYTES | 67 | no |
| MAX_ARCHIVE_BYTES | 2^36 = 68,719,476,736 | yes |
| MAX_CHUNK_PAYLOAD (framing) | 335,544,320 (320 MiB) | NO, frozen for major 1 (keeps the 2-bit guarantee) |
| MAX_CHUNKS (every chunk, including HEAD and TAIL) | 1,048,576 | yes |
| MAX_ITEMS (itemCount) | 100,000 | yes |
| Image bytes per item | 1 to 268,435,456 (2^28) | yes, as long as the maximum ITEM L stays <= MAX_CHUNK_PAYLOAD |
| Notes per item | 0 to 1,048,576 (2^20) | yes |
| Group name | 1 to 1,024 bytes | yes |
| originalIDs, icon | 1 to 128 bytes | yes |
| sOFT | 1 to 256 bytes | yes |
| MAX_TOTAL_TEXT | 67,108,864 (2^26) | yes |
| Date range | [-63,114,076,800.0, 63,113,904,000.0] | no |

What the limits guarantee:
- **Reader heap.** Copied text is at most 64 MiB, plus O(itemCount) small structs (at most about 10 MiB). Image bytes are never copied.
- **Loop bound.** The parse loop runs at most 2^20 iterations. CRC work is linear in file size and at most 320 MiB per chunk. There is no recursion.
- **No unchecked allocation.** Every String's size is checked against its cap, the remaining bytes and the text budget before it is created. Arrays grow only by `append`.
- **No overflow.** Every intermediate value is at most 2^36 + 2^29 + 12, so Int (64-bit) arithmetic cannot overflow.

---

## 9. Reader (codec)

**API.** `static func decode(_ data: Data, progress: ((_ verified: Int, _ total: Int) -> Void)? = nil) throws -> ValidatedCollection`.
- It is pure: no I/O and no side effects.
- `ValidatedCollection` has `formatMinor`, `exportedAt`, `group (originalID, name, icon)` and `items: [Item(originalID, notes, dateCreated, image: Data)]`. Its initializer is private to the codec, so import code can only consume fully validated input.
- `SUPPORTED_MINOR = 0`.

**Primitives.**
- Let `size = data.count` and `base = data.startIndex`. All positions are Int offsets relative to `base`, and u32 values are widened with `Int(x)`.
- Invariant: `0 <= c <= e <= size`. "need k" is tested as `k <= e - c`, never as `c + k <= e`.
- No pointer escapes a `withUnsafeBytes` closure.
- The items array grows by `append`. `reserveCapacity(itemCount)` MAY be used only after itemCount <= MAX_ITEMS has been checked.

### 9.1 Error catalog

| Error | Raised when | User message (suggested) |
|---|---|---|
| `notAnArchive` | Signature mismatch with no diagnosis | Not a PictureTrack collection. |
| `legacyFormat` | Old JSON export | Exported by an older PictureTrack; can't be imported. |
| `textModeDamaged` | Signature mangled by a text-mode transfer or transcoding | Damaged by a text-mode transfer. |
| `truncated(offset)` | The file ends early, or the end marker is missing | Incomplete, or has extra bytes at the end. |
| `tooLarge` | size > MAX_ARCHIVE_BYTES | Too large. |
| `corrupted(offset)` | CRC mismatch, a non-letter type byte, or L > MAX_CHUNK_PAYLOAD | Damaged. |
| `unsupportedVersion(major, minor)` | major != 1 (after a valid preamble CRC) | Made by a different/newer PictureTrack format (major.minor). |
| `requiresNewerVersion(type, minor)` | Unknown critical chunk | Uses a newer feature (format 1.minor); update the app. |
| `limitExceeded(field, offset, minor)` | Any limit exceeded. field is one of itemCount, groupID, name, icon, itemID, notes, image, software, totalText, chunkCount. | If minor > SUPPORTED_MINOR: "made by a newer PictureTrack". Otherwise: damaged/unsupported. |
| `malformed(offset, reason)` | A grammar, exact-length, count or empty-field violation | Damaged. |
| `invalidText(field, offset)` | NUL where forbidden, or invalid UTF-8 | Damaged. |
| `invalidDate(field, offset)` | NaN, Inf, or out of range | Damaged. |
| `invalidGroupName(offset)` | Name is blank per W | Missing a valid collection name. |
| `trailingData(offset)` | Bytes after TAIL | Incomplete, or has extra bytes at the end. |
| `CancellationError` | `Task.isCancelled` | (silent) |

### 9.2 Validation order

The order is exact. The first failing check determines the error.

**R1. Signature.** If `size >= 8` and bytes [0, 8) equal the signature, continue to R2. Otherwise:
- if `1 <= size < 8` and the bytes equal the first `size` signature bytes, throw `truncated(0)`;
- else if bytes `50 54 43` ("PTC") occur at offset 1, 2 or 3, throw `textModeDamaged`;
- else, within the first 64 bytes only: skip a leading `EF BB BF`, then any bytes in {09, 0A, 0D, 20}. If the next byte is `7B` ('{'), throw `legacyFormat`;
- otherwise throw `notAnArchive`.

**R2.** If `size < 16`, throw `truncated(0)`.

**R3.** If `crc32_z(0, [0,12)) != u32@12`, throw `corrupted(0)`. Set `crc = u32@12`.

**R4.** Set `major = u16@8` and `minor = u16@10`. If major != 1, throw `unsupportedVersion(major, minor)`. Any minor is accepted.

**R5.** If `size < 67`, throw `truncated(0)`. If `size > 2^36`, throw `tooLarge`.

**R6. Fast end check.** If bytes [size-12, size-4) are not `00 00 00 00 54 41 49 4C`, throw `truncated(size-12)`. This is a necessary condition only; R8 is authoritative.

**R7. Initialize.** `pos = 16`, `state = expectHead`, `chunks = 0`, `itemCount = 0`, `items = []`, `textBudget = 67,108,864`, `seenSOFT = false`.

**R8. Chunk loop.** Repeat:
- a. `rem = size - pos`. If `rem < 12`, throw `truncated(pos)`.
- b. `L = Int(u32@pos)`, `T = bytes [pos+4, pos+8)`.
- c. If any byte of T is not in 41-5A or 61-7A, throw `corrupted(pos)`.
- d. If `L > 335,544,320`, throw `corrupted(pos)`.
- e. If `L > rem - 12`, throw `truncated(pos)`.
- f. `chunks += 1`. If `chunks > 1,048,576`, throw `limitExceeded(chunkCount)`.
- g. Compute `next = crc32_z(crc, bytes [pos, pos+8+L))` in pieces of at most 8 MiB. Between pieces, check `Task.isCancelled` (throw CancellationError) and report progress. If `next != u32@(pos+8+L)`, throw `corrupted(pos)`. Set `crc = next`.
- h. Dispatch, with payload cursor `c = pos+8` and end `e = pos+8+L`. Checks run in this order:
  1. If `state == expectHead` and `T != HEAD`: throw `malformed("HEAD must be first")`.
  2. If T[0] is uppercase and T is not HEAD, ITEM or TAIL: throw `requiresNewerVersion(T, minor)`. This runs before any count or grammar check, so a newer file always says "update".
  3. `HEAD`: if `state != expectHead`, throw `malformed("duplicate HEAD")`. Otherwise parse HEAD (9.3) and set `state = archiveScope`.
  4. `ITEM`: if `items.count == itemCount`, throw `malformed("more ITEM chunks than itemCount")`. Otherwise parse ITEM (9.3), append the item, and set `state = itemScope`.
  5. `TAIL`:
     - if `L != 0`, throw `malformed("TAIL not empty")`;
     - if `items.count != itemCount`, throw `malformed("fewer ITEM chunks than itemCount")`;
     - if `pos + 12 != size`, throw `trailingData(pos+12)`;
     - otherwise RETURN the ValidatedCollection.
  6. `sOFT`:
     - if `state != archiveScope` or `seenSOFT`, throw `malformed("sOFT misplaced")`;
     - if `L > 256`, throw `limitExceeded(software)`;
     - if `L < 1`, throw `malformed`;
     - if the payload contains 00, throw `invalidText(software)`;
     - if it is not valid UTF-8, throw `invalidText(software)`;
     - set `seenSOFT = true`.
  7. Any other T with lowercase T[0]: skip it.
- i. `pos += 12 + L`.

### 9.3 Field parsers

All parsers operate inside a payload [c, e).

**str(field, min, max, allowNUL, counted):**
- S1. need 4, else `malformed`.
- S2. `n = u32`; `c += 4`.
- S3. If `n > max`, throw `limitExceeded(field)`.
- S4. If `n > e - c`, throw `malformed("<field> overruns payload")`.
- S5. If `n < min`, throw `malformed("<field> empty")`.
- S6. If counted and `n > textBudget`, throw `limitExceeded(totalText)`; then `textBudget -= n`.
- S7. If `!allowNUL` and the bytes contain 00, throw `invalidText(field)`.
- S8. If `String(validating: data[base+c ..< base+c+n], as: UTF8.self)` is nil, throw `invalidText(field)`.
- S9. `c += n`.

**date(field):**
- D1. need 8, else `malformed`.
- D2. `bits = u64`; `c += 8`.
- D3. `v = (bits == 0x8000000000000000) ? +0.0 : Double(bitPattern: bits)`.
- D4. If `!v.isFinite`, or `v < -63,114,076,800.0`, or `v > 63,113,904,000.0`, throw `invalidDate(field)`.

**HEAD:**
- H1. need 4; `itemCount = u32`.
- H2. If `itemCount > 100,000`, throw `limitExceeded(itemCount)`.
- H3. exportedAt = date.
- H4. groupID = str(1, 128, no NUL).
- H5. name = str(1, 1024, no NUL).
- H6. icon = str(1, 128, no NUL).
- H7. If `c != e`, throw `malformed("HEAD has trailing bytes")`.
- H8. If the name has no scalar outside W, throw `invalidGroupName`.

**ITEM:**
- I1. dateCreated = date.
- I2. itemID = str(1, 128, no NUL).
- I3. notes = str(0, 1,048,576, NUL allowed).
- I4. `m = e - c`. If `m < 1`, throw `malformed("ITEM has no image bytes")`.
- I5. If `m > 268,435,456`, throw `limitExceeded(image)`.
- I6. `image = data[base+c ..< base+e]`. This is a slice that shares the mapping; no copy is made, and `subdata(in:)` MUST NOT be used.

### 9.4 Result

The result is `{formatMinor, exportedAt, group, items}`, with items in file order. The image slices keep the mapping alive.

### 9.5 Error-precedence consequences (must hold)

- A short old JSON file gives `legacyFormat`, not `truncated`.
- A flipped major bit gives `corrupted(0)`, not `unsupportedVersion`.
- An unknown critical chunk in a file that also has an item-count mismatch gives `requiresNewerVersion`.
- The `fewer items` count error at TAIL is reported as `malformed`, not as `truncated`.

### 9.6 Optional parallel verification (non-normative)

A reader MAY walk the chunk headers first, with the same bounds checks R8 a to f, and compute per-chunk CRCs (seed 0) on 2 to 4 workers. It then combines them in order: `Ck = crc32_combine(C(k-1)', crc_chunk_k, 8+L_k)`, where the combine is applied on the seed relationship. The results and the error reported MUST be identical to the sequential algorithm, including reporting the lowest-offset failure first. The v1 reference is sequential.

---

## 10. Writer

**Inputs:**
- the export snapshot: groupID, name and icon, plus items with itemID, imageFilename, notes and dateCreated;
- `exportedAt = Date()`;
- `software = "PictureTrack/<CFBundleShortVersionString> (<CFBundleVersion>)"`, or `"PictureTrack"` if either value is missing.

Both `exportedAt` and `software` are injectable for tests. The writer runs off the main actor, uses only Foundation, zlib and FileHandle, writes strictly sequentially, and never seeks.

**W0. Preflight, before any file exists.** Use the SAME validator functions as the reader (sections 6 and 8):
- itemCount <= 100,000;
- each string's byte length within range, with no 0x00 except in notes;
- the name is non-blank per W;
- the total counted text is at most 2^26;
- every date is finite and in range, canonicalized with `t = (t == 0) ? 0.0 : t`.

Swift Strings always yield valid UTF-8 through `.utf8`, so no UTF-8 check is needed on write.

Then stat each image file (`URLResourceValues.fileSize`):
- a missing file throws `missingImage(filename)`;
- a size outside 1 to 2^28 throws `limitExceeded(image)`.

Compute `expected = 16 + (12 + 24 + a + b + c) + (12 + s) + sum(12 + 16 + a_i + n_i + m_i) + 12`.
- If expected > 2^36, throw `tooLarge`.
- If expected exceeds the temporary volume's `volumeAvailableCapacityForImportantUsage`, throw `insufficientSpace`.

Any failure throws a specific error, and no file is created.

**W1. Order.** Sort items ascending by (dateCreated, itemID), using a stable sort. Readers do not depend on order; this only makes the output deterministic.

**W2. Open.** Create the directory `temporaryDirectory/<UUID>/`, the file `<defaultFilename>.ptcollection` inside it, and a `FileHandle(forWritingTo:)`. On any thrown error or cancellation: close the handle, remove the directory, and rethrow.

**W3. Emit primitives.** Keep `crc: UInt32 = 0` and `written: Int = 0`.
- `emit(d)`: requires d non-empty. Update `crc = crc32_z(crc, d)` in pieces of at most 8 MiB, call `handle.write(contentsOf: d)`, then `written += d.count`.
- `emitCRC()`: write `u32LE(crc)` and set `written += 4`. It MUST NOT update `crc`.

Every byte except CRC fields goes through `emit`.

**W4. Preamble.** `emit(89 50 54 43 0D 0A 1A 0A 01 00 00 00)`, then `emitCRC()`.

**W5. HEAD.**
- Build the payload, at most 1,304 bytes: `u32 itemCount`, `f64 exportedAt`, then `str groupID`, `str name`, `str icon`.
- `emit(u32 L + "HEAD" + payload)` as one Data, then `emitCRC()`.

**W6. sOFT.** `emit(u32 L + "sOFT" + softwareBytes)`, then `emitCRC()`.

**W7. Items.** For each item, inside `autoreleasepool { }` and after `try Task.checkCancellation()`:
- a. Map the image with `Data(contentsOf: documents/filename, options: .alwaysMapped)`, or with the mmap helper from section 11.1. A missing file throws `missingImage`. Let `m = image.count`, and require 1 <= m <= 2^28.
- b. App image check (section 11.4). On failure, throw `invalidImageData(filename)`. Unimportable images therefore fail at export, never at import.
- c. Compute `L = 16 + a + n + m` as Int. It is at most 269,484,176, which is below MAX_CHUNK_PAYLOAD by construction.
  - Build `prefix = u32 L + "ITEM" + f64 dateCreated + u32 a + idBytes + u32 n + notesBytes`. The prefix is at most 1,048,732 bytes.
  - `emit(prefix)`.
- d. Emit the image in 8 MiB slices `image[i..<j]`. The slices share the mapping, so there is no copy, and the CRC and the write touch each page while it is still resident. Then `emitCRC()`.
- e. Leaving the scope releases `image`, which unmaps it. At most ONE image mapping is live at any time.

**W8. TAIL.** `emit(00 00 00 00 54 41 49 4C)`, then `emitCRC()`.

**W9. Close.** `try handle.synchronize()` is optional; a crash leaves a file without a valid TAIL, which every reader rejects. Then `try handle.close()`.
- Assert that `written == 16 + sum over chunks of (12 + L_k)`, computed independently from the lengths actually used.
- Assert that the file size equals `written`. (`expected` from W0 can differ only if an image was replaced in the meantime, and it is used only for the free-space check.)

**W10. Self-check.** In DEBUG builds and tests, decode the output and compare it field by field: dates bit-exact and image bytes equal.

**W11. Hand-off.** Present the URL (`fileExporter` or `fileMover`), or keep today's pattern: map the file, unlink it, and return `FileWrapper(regularFileWithContents: mapped)`. Delete the temp directory on completion or cancel.

**Peak writer memory:** one clean, evictable image mapping, one prefix buffer (at most about 1 MiB), the HEAD buffer, and 4 bytes of CRC state.

---

## 11. App integration (normative for PictureTrack)

### 11.1 Import input pipeline. All of this happens before decode, with no side effects in Documents or SwiftData.

- **I1. Copy.** Inside the security scope, run an `NSFileCoordinator` coordinated read of the picked URL, which forces file-provider items to download. Inside it, `FileManager.copyItem` the file into `temporaryDirectory/<UUID>/`. On the same APFS volume this is usually a clone; whether File Provider sources clone is an inference. The copy prevents SIGBUS if the source is truncated while mapped, and prevents the file changing between verification and import.
- **I2. Size gate.** Read the copy's size. If it is over 2^36, throw `tooLarge` before mapping. If it is 0, decode an empty Data, which gives `notAnArchive`.
- **I3. Map.** Call `open(O_RDONLY)`, `mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)`, `close(fd)`, `madvise(p, size, MADV_SEQUENTIAL)`, then `Data(bytesNoCopy: p, count: size, deallocator: .unmap)`. Verified that a slice of this Data shares the mapping.
  - If mapping fails (for example, the iOS address space is exhausted), throw `archiveTooLargeForDevice`. Never fall back to reading the file into the heap. `.mappedIfSafe` and `.alwaysMapped` are only hints, so MUST NOT be relied on here.
  - Unlink the copy immediately; the mapping keeps it alive.
- **I4. Decode.** `CollectionArchiveCodec.decode(mapped)`, run off the main actor with progress and cancel UI.

### 11.2 Phase B: app checks, still before any side effect

- For every item, run the image check (section 11.4). On failure, throw `invalidImageData(index)`.
- If `UIImage(systemName: icon) == nil`, substitute `Symbols.defaultSymbol`.

### 11.3 Phase C: side effects, only after decode and phase B both pass

- Create a ModelContext and a new TrackerGroup with a fresh UUID.
- For each item, write the slice to Documents under a fresh UUID filename with `.atomic`, then insert a TrackerItem.
- Call `save()` once.
- On any error, delete every file written so far. This is the existing rollback.
- Crash safety: before the first write, record the planned filenames in an import journal (`Application Support/ImportJournals/<processID>_<UUID>.txt`) and delete it after `save()` or the rollback. At launch, for every journal left by another process, delete the listed files that no TrackerItem references, then the journal.
- MAY: write in reverse file order to reuse pages the verification pass left in the page cache.
- The mapped Data MUST stay alive until phase C ends.

### 11.4 Image check, shared by export and import

Create the source with `CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false])`. The data passes only if all three hold:
- the source is non-nil;
- `CGImageSourceGetType` is one of `public.jpeg`, `public.heic`, `public.heif`;
- `CGImageSourceGetCount >= 1`.

Implemented by `ImageStore.isTransferableImageData` (ImageManager.swift), which also requires real pixel dimensions. A bare `CGImageSourceCreateWithData` check is not enough: it returns non-nil for garbage (measured: type nil, count 0). Changing the allowlist is app policy and does not change the format.

### 11.5 FileDocument

`CollectionArchiveDocument.init(configuration:)` currently decodes `regularFileContents`, which reads the whole file into the heap. It MUST throw `CollectionArchiveError.invalidFile`, or check only the 16-byte preamble. Import goes only through `fileImporter` URL, then I1 to I4. The document type is used for export only.

### 11.6 Type declaration

- Swift: `conformingTo: .data`.
- Info.plist: `UTTypeConformsTo = public.data`, MIME `application/vnd.picturetrack.collection`, extension `ptcollection`. Info.plist declares these values.

---

## 12. Versioning and extension rules

- **E1. Frozen preamble.** Bytes 0 to 15 (signature, u16 major, u16 minor, CRC-32 of [0,12)) keep this exact layout and CRC algorithm in every major version.
- **E2. Major.** Readers accept exactly major 1, and reject every other value with `unsupportedVersion` after the preamble CRC passes. A major bump is REQUIRED for, and is the only way to make, any of these changes:
  - chunk framing: the length width, the header layout, the CRC algorithm, the chaining or the coverage;
  - the grammar (HEAD first, TAIL last, one collection);
  - the layout or meaning of any already-defined chunk type;
  - the str, date or integer encodings;
  - MAX_CHUNK_PAYLOAD or the date range;
  - lowering any limit;
  - compressing or encrypting existing content;
  - multiple collections per file.
- **E3. Minor.** Minor is informational:
  - readers MUST accept any minor value;
  - writers write the minor of the spec revision they implement;
  - readers use it only to word errors: "made by a newer PictureTrack (format 1.x)" for `requiresNewerVersion`, or `limitExceeded` when minor > SUPPORTED_MINOR.
- **E4. Ignorable additions** use a new ANCILLARY type (byte 0 lowercase, bytes 1 and 2 uppercase). Each definition MUST state:
  - the FourCC;
  - its scope (archive scope or item scope) and multiplicity;
  - an exact-length payload layout using the existing encodings;
  - per-field limits;
  - the safe-to-copy bit.

  A reader that knows the type MUST reject the file if the chunk's content or position is invalid. A reader that does not know it skips it.
- **E5. Additions that would be misread if ignored** use a new CRITICAL type (byte 0 uppercase). Old readers reject such files with `requiresNewerVersion`. Writers MUST emit a critical chunk only in files that actually use the feature, so files without it stay readable by old apps.
- **E6. Never:**
  - append fields to, or reorder, an existing chunk's payload (known payloads have exact lengths);
  - reuse or redefine a FourCC (the registry is append-only);
  - flip a type's critical or ancillary bit;
  - assign a type whose byte 1 is lowercase.
- **E7. Limits.** A minor MAY raise any limit marked "yes" in section 8, as long as every v1-defined chunk's maximum payload stays at most MAX_CHUNK_PAYLOAD. Old readers then reject only the files that exceed their own limits (`limitExceeded`, worded as "newer version").
- **E8. Editing tools** follow PNG's rules:
  - they MAY copy unknown safe-to-copy ancillary chunks unchanged, at the same relative position;
  - they MUST drop unknown unsafe-to-copy chunks in any scope whose critical data they change;
  - they MUST rewrite sOFT;
  - they MUST recompute the CRC chain from the first changed chunk onward.
- **E9. Hygiene.**
  - Registry for v1.0: `HEAD`, `ITEM`, `TAIL`, `sOFT`.
  - Each new minor ships new test vectors, and new readers MUST still decode every older vector.
  - The v1.0 test suite includes vector D (unknown ancillary chunk, minor 1, accepted) and vector E (unknown critical chunk, rejected).

**Worked examples:**
- 1.1 `tAGs` (item scope, at most 1 per item, safe-to-copy): u32 count (at most 64), then count str values, each 1 to 64 bytes with no NUL.
- 1.1 `cROP` (item scope, unsafe-to-copy): exactly 32 bytes, 4 f64 values x, y, w, h, each in [0, 1], with x+w <= 1 and y+h <= 1.
- 1.2 `tHMB` (item scope, unsafe-to-copy): a JPEG thumbnail of at most 512 KiB.
- 1.2 `cOVR` (archive scope): a cover image. Because HEAD is at offset 16, a Quick Look extension needs only the first few hundred KB.
- 1.3 `IREF` (critical, item scope): an item whose image reuses an earlier item's bytes. The grammar would then need a revision, so IREF is defined together with an ITEM variant, for example a critical `ITMR` that carries metadata plus a u32 reference.
- An image larger than about 318 MiB, or a video, needs major 2 (u64 lengths) or a critical continuation-chunk scheme.
- A signature `sIGN` (ancillary, placed just before TAIL, Ed25519 over [0, start of sIGN)).

---

## 13. Test vectors

All five vectors were generated and checked by the reference model in `Tools/PTCollectionTests/reference/ref.py`. Common inputs: group ID `00000000-0000-4000-8000-000000000001`, name `Run`, icon `figure.run`, exportedAt 815000000.5 (bits `00 00 40 e0 f4 49 c8 41`), sOFT `PictureTrack/1.0 (1)`.

**Vector A (0 items, 145 bytes, writer-conformant)**
```
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 49 00 00 00 48 45 41 44 00 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e 3c 10 a1 03 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 35 57 21 de 00 00 00 00 54 41 49 4c 17 c4 ae
0090: df
```

**Vector B (1 item, 218 bytes).** Item: ID `...000000000002`, notes "hi é" (`68 69 20 c3 a9`), dateCreated 815000000.25 (bits `00 00 20 e0 f4 49 c8 41`), image `ff d8 ff d9`.
```
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 49 00 00 00 48 45 41 44 01 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e 32 4c 6d f4 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 0a 27 ea 50 3d 00 00 00 49 54 45 4d 00 00 20
0090: e0 f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30
00a0: 30 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30
00b0: 2d 30 30 30 30 30 30 30 30 30 30 30 32 05 00 00
00c0: 00 68 69 20 c3 a9 ff d8 ff d9 e1 0a de 95 00 00
00d0: 00 00 54 41 49 4c 12 f6 1c d4
```

Field walk:

| Offset | Content |
|---|---|
| 0x00 | Preamble (crc C0 = 0xC6D1436C) |
| 0x10 | HEAD, L = 0x49 (73). itemCount 1 at 0x18; exportedAt at 0x1C; groupID str at 0x24 (len 36); name str at 0x4C ("Run"); icon str at 0x53 ("figure.run"). CRC at 0x61 = 0xF46D4C32. |
| 0x65 | sOFT, L = 20, payload 0x6D to 0x80, CRC at 0x81 = 0x50EA270A |
| 0x85 | ITEM, L = 0x3D (61). Date at 0x8D; ID str at 0x95; notes str at 0xBD (len 5); image = file bytes [0xC6, 0xCA). CRC at 0xCA = 0x95DE0AE1. |
| 0xCE | TAIL, CRC at 0xD6 = 0xD41CF612 |

The codec accepts B. The app's image check (11.4) MUST reject it, because 4 bytes are not a decodable JPEG. This tests the layering.

**Vector C (minimal reader-valid file, 67 bytes).** Group `g`, name `R`, icon `x`, exportedAt 0.0, 0 items, no sOFT.
```
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 1b 00 00 00 48 45 41 44 00 00 00 00 00 00 00 00
0020: 00 00 00 00 01 00 00 00 67 01 00 00 00 52 01 00
0030: 00 00 78 24 c5 b7 8b 00 00 00 00 54 41 49 4c 52
0040: 27 24 2c
```

**Vector D (forward compatibility, 231 bytes, MUST decode to B's content with formatMinor 1).** Vector B with minor = 1 (preamble CRC 0xDFCA722D) and an unknown ancillary chunk `tEST` with payload "x" in item 0's scope.
```
0000: 89 50 54 43 0d 0a 1a 0a 01 00 01 00 2d 72 ca df
0010: 49 00 00 00 48 45 41 44 01 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e cc 98 12 f2 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 a4 f7 54 c6 3d 00 00 00 49 54 45 4d 00 00 20
0090: e0 f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30
00a0: 30 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30
00b0: 2d 30 30 30 30 30 30 30 30 30 30 30 32 05 00 00
00c0: 00 68 69 20 c3 a9 ff d8 ff d9 fe 50 6f 4b 01 00
00d0: 00 00 74 45 53 54 78 37 32 6a ac 00 00 00 00 54
00e0: 41 49 4c 28 e9 88 a2
```

**Vector E (MUST be rejected with `requiresNewerVersion("XTST", 1)` at offset 0xCE).** Identical to D except:
- byte 0xD2 = `58` ('X', so the chunk type is XTST);
- bytes 0xD7 to 0xDA = `c8 c0 fe 40`;
- bytes 0xE3 to 0xE6 = `b5 ba f1 1c`.
