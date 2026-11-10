#!/usr/bin/env python3
"""Compile actual sources and full bundled SDK, never a release target."""

import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
BASELINE = "c651527a629419d7072f27a2e132abe7e6e7ca6e"
SDK_HASHES = {
    "4DPluginAPI.c": "355ee208ad6c61dcc68e8432546fc42484888211dd07ed8fa3fdb4440f3edbd8",
    "4DPluginAPI.h": "7391841f0046f9e822b65ca6b07cafb3565aecfb58f65be4e0661adf97b8c786",
    "PublicTypes.h": "acce13e0896a3f55a3d96bf849a42bdae7cbd5c6f92874f1f47e0e34ad070dcc",
    "PrivateTypes.h": "99e66ee558612e3fcc4efa11d8439aad65bdc982e4006e9122b4bfc1533bc6e7",
    "EntryPoints.h": "130b06373937b58ac6c5336a342fd291974371dd462d9c56c06cea4ffc8a717d",
    "Flags.h": "89be5f9526b4f066543d93142760f2f7a630ddcdfb0540dfc20191c43563aa56",
}
SCENARIOS = ("file", "bytes", "copy", "gray", "size", "thumbnail", "arrays", "scalars", "dispatcher")
DEFECTS = {
    "file": "double disposal or borrowed string disposal",
    "bytes": "setBytes releases temporary owner",
    "copy": "AddressSanitizer: heap-buffer-overflow",
    "gray": "leaked picture reference or overwritten initial empty picture",
    "size": "leaked picture reference or overwritten initial empty picture",
    "thumbnail": "leaked picture reference or overwritten initial empty picture",
}


def build_and_run(source, build, expect_baseline):
    sdk = source / "4D Plugin API"
    for name, digest in SDK_HASHES.items():
        assert hashlib.sha256((sdk / name).read_bytes()).hexdigest() == digest, f"SDK changed: {name}"
    native = [sdk / "4DPluginAPI.c", *sorted((sdk / "Classes").glob("*.cpp")),
              source / "4DPlugin.cpp", source / "CRC32/crc.c", ROOT / "tests/native/ownership.mm"]
    expected = {str(path.relative_to(source)) for path in native[:-1]}
    project = ET.parse(source / "CRC32.vcxproj")
    windows = {node.attrib["Include"].replace("\\", "/")
               for node in project.findall(".//{*}ClCompile") if "Include" in node.attrib}
    assert windows == expected, "Windows compile inventory changed"
    mac = set(re.findall(r"/\* ([^*/]+\.(?:cpp|c)) in Sources \*/",
                        (source / "CRC32.xcodeproj/project.pbxproj").read_text()))
    assert mac == {Path(name).name for name in expected}, "macOS compile inventory changed"
    print(f"Compiling full unchanged SDK and all {len(expected)} project translation units", flush=True)
    command = [
        "xcrun", "clang++", "-x", "objective-c++", "-std=c++11",
        "-include", "Carbon/Carbon.h", "-I" + str(sdk), "-I" + str(sdk / "Classes"),
        "-I" + str(source / "CRC32"), "-Wno-deprecated-declarations", "-Wno-register",
        "-g", "-O1", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
        *map(str, native), "-framework", "Cocoa", "-framework", "Carbon",
        "-o", str(build / "ownership"),
    ]
    subprocess.run(command, check=True)
    environment = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1",
                       UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    for scenario in SCENARIOS:
        for empty in ("allocated", "null"):
            result = subprocess.run([str(build / "ownership"), scenario, empty],
                                    env=environment, text=True, capture_output=True)
            expected = DEFECTS.get(scenario) if expect_baseline else None
            if expected:
                # The null-empty baseline file still double-disposes its nonempty path.
                assert result.returncode != 0 and expected in result.stderr, (
                    scenario, empty, result.returncode, result.stdout, result.stderr)
                print(f"EXPECTED BASELINE FAILURE {scenario} {empty}: {expected}", flush=True)
            else:
                if result.returncode:
                    raise RuntimeError(f"{scenario} {empty}\n{result.stdout}\n{result.stderr}")
                print(result.stdout.strip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true", help="prove named defects on immutable baseline")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This harness requires the macOS SDK and Xcode clang++; no host certification is implied.")
    with tempfile.TemporaryDirectory(prefix="crc32-ownership-") as directory:
        build = Path(directory)
        source = ROOT
        if args.baseline:
            source = build / "baseline"
            source.mkdir()
            archive = subprocess.run(["git", "-C", str(ROOT), "archive", BASELINE],
                                     check=True, capture_output=True)
            subprocess.run(["tar", "-x", "-C", str(source)], input=archive.stdout, check=True)
        build_and_run(source, build, args.baseline)


if __name__ == "__main__":
    main()
