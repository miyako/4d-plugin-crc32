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

## Source versions and manual publication

Run **Bump version** manually, selecting the intended branch and `patch`, `minor`,
or `major`. It checks out the immutable dispatch SHA, validates source metadata,
and commits only the coordinated source version fields. An executable pre-push
guard requires exactly one update whose advertised old SHA is the selected SHA
and whose new SHA is a clean, single-parent direct child. A moved, rewound,
deleted, or already-updated branch is rejected; dispatch again after inspection.
The push is non-force and disables followed tags. Bump creates no tag, release,
or automatic Build.

Run **Build** separately on the intended source commit using the Actions branch
selector; it has no inputs. Every job checks out `github.sha`. Source metadata,
not an existing tag, supplies the strict `X.Y.Z` and prospective `vX.Y.Z` tag.
There is no main/default-branch-only restriction. Publication is serialized
repository-wide across branches without cancelling a running build.

The version authority is the coordinated promise in the Bump header introduced
by `00acd54`: marketing and current/build versions advance together. The older
marketing-first implementation drifted: `61128f3` advanced marketing and the
source plist to `1.0.5` but left all six current/build settings at `1.0.3`.
This migration repairs those settings and the source English localized short
version/info string to the existing `1.0.5`, without a release increment.
Future bumps reject drift rather than silently repairing it. Xcode references,
absent plist keys (including `CFBundleVersion`), BOMs, line endings and modes
are preserved. Prebuilt bundles, 4D project/data files, localization counters,
manifest/schema resources and dependencies are not version inputs or rewritten.

Build preserves Windows x64 MSBuild (v143/Windows SDK 10.0), macOS universal
arm64/x86_64 Xcode `Default`, bundled 4D Plugin API/CRC sources, framework and
resource copy phases, the intentional `test/Plugins` packaging layout, Windows
artifact transfer, universal checks, Developer ID signing/verification,
ZIP/DMG notarization and DMG stapling. The existing macOS deployment override
is 11.0, while source project settings are 11.5; this migration changes neither.
The legacy Windows project produces under `CRC32.4dbase/plugins` and the
existing workflow normalizes the discovered binary into `test/Plugins`.
These native toolchain/layout caveats are not bypassed by lifecycle tests.
Native builds and the existing 4D test method require their respective hosts.
Signing still requires `APPLE_DEVELOPER_ID_CERTIFICATE`,
`APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`,
`NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_TEAM_ID`, and `NOTARYTOOL_PASSWORD`.

Before native work, and again immediately after all packaging/signing/notary/
staple gates, publication checks the remote tag and all authenticated release
pages, including drafts. Any existing match, authentication/network error,
404, malformed response or later-page failure stops publication. A successful
complete no-match is required. It then creates an exact-SHA tag with a
create-only Git refs POST, verifies the remote SHA, creates a non-draft,
non-prerelease release with the original empty notes policy, and separately
uploads `CRC32-X.Y.Z.zip` and `CRC32-X.Y.Z.dmg` to the newly returned release ID.
No release update, asset clobber, deletion, rollback or retry is performed.

**Partial-state recovery:** inspect the error, remote tag SHA, published/draft
releases and uploaded assets manually. A failed create or upload deliberately
retains any tag, release and assets already created; rerunning cannot repair or
overwrite them. A maintainer must decide how to complete the retained release
outside this workflow or prepare a new source version. Never assume a failed
run left no remote state.

Local lifecycle regressions (no native build, signing or publication):

```sh
python3 -m unittest discover -s .github/tests -v
actionlint
```

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
