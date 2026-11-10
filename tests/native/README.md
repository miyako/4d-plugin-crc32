# Native ownership audit and regression

## Scope and reachability

Baseline: `c651527a629419d7072f27a2e132abe7e6e7ca6e`.
Guidance: `miyako/skills/4d-skills/skills/4dplugin/SKILL.md` as merged
at `e6b492fcb81e5e1a7f7db723594b420e63bf6eb9` (#71, incorporating #69).

Both `manifest.json` and
`CRC32.4dbase/Plugins/CRC32.bundle/Contents/Resources/manifest.json`
declare only `CRC32 Get(&O):L`. There is no `&Y` parameter; such metadata
would indicate array capability, not ownership. The actual dispatcher in
`4DPlugin.cpp` maps selector 1 to `CRC32_Get`, which uses `C_BLOB`,
`C_LONGINT`, and `CRC32/crc.c`. No picture/text wrapper is called on that
public path.

The inventory includes every tracked native translation unit and header,
not only exported commands or indexed text matches:

| Surface | Files inspected | Ownership result |
|---|---|---|
| Entry/dispatcher | `4DPlugin.cpp`, `4DPlugin.h`, `4D Plugin_Prefix.pch` | Scalar blob input copied to private bytes; scalar integer result. No native string owner. |
| Scalar wrappers | `C_INTEGER`, `C_LONGINT`, `C_REAL`, `C_DATE`, `C_TIME` (`.cpp` and `.h` each) | Value copies; no string owner. |
| Blob wrapper | `C_BLOB.cpp/.h` | Owned vector; independent text conversions through `C_TEXT`; no shallow `PA_Unistring` assignment. |
| Text wrapper | `C_TEXT.cpp/.h`, `C_TYPES.h` | Copies borrowed parameter content; owned C++ text; output via engine content setter, not descriptor transfer. CF/Objective-C copy helpers release temporary owners. |
| Numeric/date arrays | `ARRAY_BOOLEAN`, `ARRAY_INTEGER`, `ARRAY_LONGINT`, `ARRAY_REAL`, `ARRAY_DATE`, `ARRAY_TIME` (`.cpp` and `.h` each) | Value copies and SDK array handles; no string transfers. |
| Text array | `ARRAY_TEXT.cpp/.h` | Copies borrowed elements into C++ strings before owner mutation; creates an independent native allocation for each accepted output; correctly does not dispose transferred strings. |
| Picture wrappers | `C_PICTURE.cpp/.h` (`CPicture` and `C_PICTURE`) | Confirmed dormant double disposal, overwritten empty owners, missing reference releases, and conversion byte/unit error, fixed here. |
| Pointer wrapper | `C_POINTER.cpp/.h` | Metadata reconstruction from pointer value; ambiguous contract, deferred below. |
| SDK boundary | `4DPluginAPI.c/.h`, `PublicTypes.h`, `PrivateTypes.h`, `EntryPoints.h`, `Flags.h`, `4DPluginAPI.def` | Actual contracts examined; all SDK files left unchanged. |
| CRC dependency | `CRC32/crc.c`, `crc.h`, `sniptype.h` | Included for reachability and dispatcher validation; CRC algorithm and dependency files unchanged. |

`CRC32.vcxproj` explicitly compiles the SDK, all 16 wrapper `.cpp` files,
`4DPlugin.cpp`, and `CRC32/crc.c` (19 translation units).
`CRC32.xcodeproj/project.pbxproj` lists the same complete set in its Sources
phase. `4DPluginAPI.h` includes all wrapper headers; `C_TYPES.h` is included
transitively. The solution, filters, prefix header, project include paths,
compile-as settings, resources, and build phases were examined. The runner
asserts that both project compile inventories match its actual source set.
Dormant wrappers therefore remain in scope despite the scalar manifest.
The baseline has 45 tracked `.c`/`.cpp`/`.h`/`.pch` files, plus the SDK `.def`.
No other tracked first-party native implementation was excluded.

## Bundled SDK evidence

The SDK implementation's last file-history commit is
`663f2e2dceaf92a711dbe6b08c08629bd48d35e5` (`mv`).
`4DPluginAPI.c` SHA-256:
`355ee208ad6c61dcc68e8432546fc42484888211dd07ed8fa3fdb4440f3edbd8`.
The runner pins all six compiled SDK implementation/header hashes. Header
comments (`v13`, implementation `v14`) are not a verified upstream release
identity. No upstream SDK version claim or SDK rewrite is made.

| Actual SDK surface | Contract used |
|---|---|
| `PA_CreateUnistring`, lines 244-250 | Calls engine creation; descriptor owns its returned allocation. Allocated and null empty representations are tested separately. |
| `PA_DisposeUnistring`, lines 252-261 | Disposes the allocation then resets only the supplied descriptor, not other aliases. |
| `PA_SetUnistring`, lines 263-270; `PA_ReturnString`, lines 2260-2263 | Engine content setter passes a UTF-16 buffer, unlike array descriptor assignment. Shim copies content with termination and validates lifetime independence. |
| `PA_CreateVariable`, lines 3523-3657 | String/picture kinds allocate an initial empty owner; Undefined allocates none. Shallow-overwriting the former leaks it. |
| `PA_GetPictureVariable`, lines 3729-3737 | Returned picture belongs to the variable; getter explicitly documents borrowing. |
| `PA_GetStringVariable`, lines 3693-3703 | Engine-backed variable-to-string conversion, not the array getter implementation. No first-party caller here; allocation ownership is not established by this forwarding code. |
| `PA_SetStringVariable`, lines 3826-3831; `PA_SetPictureVariable`, lines 3852-3857 | Shallow assignment, no retain/copy or old-owner disposal. Use Undefined when immediately installing an independently owned value. |
| `PA_ClearVariable`, lines 3947-3955 | Engine-backed owning cleanup. Do not clear the same string via a second alias. |
| `PA_GetStringInArray`, lines 4264-4283 | Borrowed descriptor; no dispose or use after replacement/shrink/clear. |
| `PA_SetStringInArray`, lines 4444-4460 | Accepted assignment disposes the old element then shallow-transfers the input. Requires Unicode array, non-null data, index in inclusive `0..fNbElements`, non-null descriptor pointer. Rejections retain caller ownership; no error-code-based success inference. |
| `PA_DuplicatePicture`, lines 446-454 | `retainOnly=1` retains the same picture (engine parameter inverted to zero). Getters borrow; extra retain must have an eventual dispose. |
| `PA_ConvertCharsetToCharset`, lines 4776-4792 | Engine receives source/destination byte counts and returns bytes written through `fParam3`; divide by `sizeof(PA_Unichar)` for the C++ UTF-16 constructor. |
| `PA_ExecuteCommandByID`, lines 5257-5289 | Synchronous argument pointers; wrapper-created owners remain to clean after the call. Returned variable is independently returned by value. These five built-in commands are procedures, not owning-valued functions. |

The fix keeps one owner for the file path, retains the borrowed file-output
picture before clearing its argument, releases the `setBytes` temporary,
and avoids allocated empty owners when immediately setting argument values.
`createCopy` and `createGrayScale` retain an input, obtain the resulting
picture, then detach it from the argument before cleanup: the returned owner
survives the wrapper's destruction. Property/thumbnail input aliases are
detached without disposing the wrapper-owned picture. Real output picture
arguments remain initialized as pictures for the engine to replace.

There are no first-party `PA_ExecuteMethod*`, JSON Parse, object-property,
or collection-element calls in this repository; this SDK has no
`PA_GetObjectProperty`/collection-element implementation. No speculative
cleanup was added for nonexistent surfaces or procedure return values.

## Regression commands and evidence

On macOS with Xcode's command-line tools:

```sh
python3 tests/native/run_ownership.py
python3 tests/native/run_ownership.py --baseline
python3 -m unittest discover -s .github/tests -q
```

The runner compiles the actual 19 project translation units, plus
`ownership.mm`, with the **full unchanged bundled SDK**, ASan and UBSan.
Only `gCall4D` is redirected to an engine-boundary shim. No PA API
implementation is substituted or extracted. Cocoa/Carbon supply actual
text conversion for synthetic fixtures; no file, user database, network,
or real picture decoding is used. Known commands synchronously inspect
their arguments and replace output picture owners. Picture representation
enumeration deliberately returns failure, without initialized string output,
to avoid inventing the unresolved picture-data ownership contract.

The exact same final harness is compiled against a `git archive` of the
immutable baseline for `--baseline`; it asserts the expected diagnostic,
not merely any nonzero exit:

| Scenario, each with allocated and null empty strings | Baseline | Fixed |
|---|---|---|
| File path owner | Double-disposal diagnostic | Pass |
| `setBytes` temporary reference | Retain-count diagnostic | Pass |
| `createCopy` conversion | ASan heap-buffer-overflow | Pass |
| Grayscale, properties, thumbnail | Leaked initial picture owner | Pass |
| Arrays, scalar content setters, actual CRC dispatcher | Pass | Pass |

Totals: 12 expected baseline failures, 6 unaffected baseline passes;
18 fixed passes. Each successful scenario finishes with zero tracked
string allocations, handles, and picture references. LSan is disabled
because it is unsupported on macOS; explicit allocation/reference ledgers
cover allocated empty strings/pictures as well as nonempty values.
ASan/UBSan remain enabled with fail-fast behavior.
Local execution used macOS 26.7 arm64 and Apple clang 21.0.0.

Fixtures assert exact ASCII, BMP Japanese, supplementary surrogate pairs,
empty text, UTF-16 lengths/capacity/termination, both empty representations,
repeated file replacement, independent picture handoffs, array replacement,
shrink and clear, independent output allocations, and copying borrowed
array content before clearing its original owner. Rejected wrong type,
negative/out-of-range index, null data, and null descriptor cases retain
caller ownership. Index zero and a valid null-empty descriptor are accepted.
Scalar content setters retain independent results after source mutation.
The real dispatcher still produces `0xcbf43926` for synthetic `123456789`.

## Deferred and validation boundaries

- `C_POINTER::getVariable` consumes variable-definition metadata and sets
  `fFiller=1`. The SDK header says to clear pointer-value results, but the
  engine-only implementation does not establish whether this metadata
  representation owns content. Neither blindly clearing nor clearing then
  relabeling borrowed metadata is justified. No change or certification.
- `PA_GetPictureData` format strings and SDK-only application/structure
  full-path outputs have engine-dependent, undocumented allocation ownership.
  Existing picture-data code checks the SDK error immediately; failed
  outputs are not read or cleared. Success-output ownership is deferred.
  No application-path or `PA_GetStringVariable` caller exists in first-party
  code; the latter's engine-backed conversion ownership is also deferred.
- The SDK's `PA_ResizeArray` updates element count even after a failed
  reallocation. Ordinary success-path arrays do not validate or repair that
  unrelated SDK OOM/count-corruption issue. Allocation-failure behavior is
  not certified.
- No real 4D or Windows host was executed, and the original Poppler Windows
  crash was not reproduced here. These are native macOS shim/sanitizer
  results, not host, codec, or plugin-package certification. The public
  CRC command does not reach these picture defects.

Build/CI inspection preceded commands and push. Existing `Build` and
`Bump version` workflows are manual `workflow_dispatch` only and remain
byte-for-byte unchanged. No native project/release configuration was run.
The new Native ownership workflow runs only Python tests and direct unsigned
compiler/sanitizer commands on pull requests and master pushes. It performs
no signing, notarization, packaging, uploads, tagging, or binary publication.
Tracked bundle binaries, manifests, resources, version metadata, third-party
code, and all SDK files remain unchanged.
