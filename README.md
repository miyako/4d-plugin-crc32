![version](https://img.shields.io/badge/version-17%2B-3E8B93)
![platform](https://img.shields.io/static/v1?label=platform&message=mac-intel%20|%20mac-arm%20|%20win-64&color=blue)
[![license](https://img.shields.io/github/license/miyako/4d-plugin-crc32)](LICENSE)
![downloads](https://img.shields.io/github/downloads/miyako/4d-plugin-crc32/total)

# 4d-plugin-crc32

4D implementation of the standard 32-bit CRC (CRC-32/ADCCP, the same polynomial used by PKZIP, gzip, and Ethernet FCS). The plugin exposes a single command that computes the checksum of a `Blob` and returns it as a `Longint`.

| Command | Returns | Purpose |
|---|---|---|
| [`CRC32 Get`](#crc32-get) | `Longint` | Compute the CRC-32 checksum of a blob's contents. |

**Platforms:** carbon · cocoa · win32 · win64

---

## Requirements & platform notes

- No minimum OS version or special permission is required — the command performs a pure in-memory computation with no OS/system API dependency beyond standard C library calls.
- Behavior is identical on every listed platform; there is no `#if VERSIONMAC`/`#if VERSIONWIN` branching anywhere in the plugin's source.
- The parameter is **mandatory** — there is no optional/overloaded form of this command.
- The checksum returned is the well-known CRC-32 variant (polynomial `0xEDB88320`, reflected), the same one produced by PHP's `crc32()`, gzip, and PKZIP. It is a data-integrity checksum, not a cryptographic hash — don't use it where collision-resistance against a deliberate adversary matters.

---

## CRC32 Get

### Syntax

```
CRC32 Get ( data ) → Result
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `data` | Blob | The binary content to checksum. Mandatory — always read from the call, no default. |
| Result | Longint | The CRC-32 checksum of `data`'s bytes. |

### Description

`CRC32 Get` reads the blob's raw bytes and its length, then runs the standard 32-bit CRC-32/ADCCP algorithm over them, returning the result as a `Longint`.

- Passing an **empty blob** (zero length) is safe: the internal loop is guarded on the byte count, so it never dereferences the blob's pointer when there's nothing to read. You'll get back the CRC-32 of an empty input (`0`), not an error.
- The checksum is computed purely from the bytes in the blob — text encoding matters. If you're checksumming text, convert it to a blob with an explicit, known encoding first (see the example below); checksumming the same string under two different encodings will produce two different, both-correct results.
- On very large blobs (hundreds of MB or more), the command periodically yields control back to 4D during the computation so the application doesn't appear to hang for the duration — computation time scales with input size either way, so expect a large blob to take proportionally longer.

### Example

From the plugin's own test method (`Method1.4dm`):

```4d
C_BLOB:C604($data)

CONVERT FROM TEXT:C1011("Hello world!"; "us-ascii"; $data)

$crc32:=CRC32 Get($data)

ASSERT:C1129($crc32=461707669)
  //http://www.w3schools.com/php/func_string_crc32.asp
```

Checksumming the contents of a file on disk:

```4d
C_BLOB($data)
C_LONGINT($crc32)

DOCUMENT TO BLOB(Document; $data)

$crc32:=CRC32 Get($data)

ALERT("CRC-32: "+String($crc32))
```

Checksumming text under a different encoding (note the result will differ from the `us-ascii` example above for any non-ASCII character):

```4d
C_BLOB($data)
C_TEXT($text)
C_LONGINT($crc32)

$text:="Hello world!"
CONVERT FROM TEXT($text; "UTF-8"; $data)

$crc32:=CRC32 Get($data)
```

---

## Error handling & troubleshooting

- **Empty blob returns a defined value, not an error.** Passing a zero-length blob is safe and returns the CRC-32 of an empty input rather than raising an error or crashing.
- **Text-encoding mismatches change the result, silently.** `CRC32 Get` only ever sees bytes — if you build the blob from text, the encoding you pass to `CONVERT FROM TEXT` (or equivalent) determines the byte sequence, and therefore the checksum. Two teams checksumming "the same string" under different encodings will get two different values with no error raised on either side; always pin down and document which encoding you're standardizing on.
- **Not a security checksum.** CRC-32 is designed to catch accidental corruption (transmission errors, bad disk sectors), not deliberate tampering — a motivated party can construct a different input with the same CRC-32. Don't use this command as an integrity check against adversarial input; use a cryptographic hash for that.

---

## Quick reference

```4d
C_BLOB($data)
C_LONGINT($crc32)

CONVERT FROM TEXT("Hello world!"; "us-ascii"; $data)
$crc32:=CRC32 Get($data)
```
