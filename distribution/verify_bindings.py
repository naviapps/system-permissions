#!/usr/bin/env python3
"""Validate C ownership, .NET contracts and clean, private NuGet consumption."""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from sdk_tooling.adapters import load

ROOT = Path(__file__).resolve().parents[1]
DOTNET_PROJECTS = ("NaviApps.SystemPermissions", "NaviApps.SystemPermissions.Windows")


def run(*args, env):
    subprocess.run([str(a) for a in args], cwd=ROOT, env=env, check=True)


def pack_and_consume(dotnet, library, rid, env, output):
    runtime = output / "native" / rid
    native_name = "libsystem_permissions.dylib" if rid.startswith("osx-") else library.name
    staged = load("artifacts").stage_native(library, runtime / native_name)
    packages = output / "packages"
    for name in DOTNET_PROJECTS:
        load("dotnet").pack_project(
            dotnet,
            ROOT / "bindings/dotnet/src" / name / (name + ".csproj"),
            output=packages,
            cwd=ROOT,
            env=env,
            properties={
                "SystemPermissionsRuntimeIdentifier": rid,
                "SystemPermissionsNativeLibrary": str(staged),
            },
        )
    built = [packages / (name + ".0.1.0.nupkg") for name in DOTNET_PROJECTS]
    notices = {
        "licenses/" + path.relative_to(ROOT / "ThirdParty").as_posix(): path
        for path in (ROOT / "ThirdParty").rglob("*")
        if path.is_file() and path.name not in (".DS_Store", "registry-notices.json")
    }
    hashes = {
        package.name: load("nuget").audit_package(
            package,
            expected_files={
                "README.md": ROOT / "bindings/dotnet/README.md",
                "LICENSE": ROOT / "LICENSE",
                **(notices if package == built[0] else {}),
            },
            runtime_files={"runtimes/" + rid + "/native/" + native_name: library}
            if package == built[0]
            else {},
        )
        for package in built
    }
    load("nuget").run_isolated_consumer(
        dotnet,
        packages=built,
        references={"NaviApps.SystemPermissions.Windows": "0.1.0"},
        source=(ROOT / "fixtures/consumers/dotnet/Program.cs").read_text(encoding="utf-8"),
        work_parent=output,
        env=env,
        runtime=rid,
        properties={"Nullable": "enable", "TreatWarningsAsErrors": "true"},
        exclude_paths=(ROOT / "target", runtime, library.parent),
    )
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, help="Explicit already source-built test library")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit(
            "Use distribution/verify_windows.py to build x64 on an owned Windows worker"
        )
    dotnet = os.environ.get("DOTNET_BIN") or shutil.which("dotnet")
    if not dotnet:
        raise SystemExit("Set DOTNET_BIN to the task's .NET 10 executable")
    env = dict(
        os.environ,
        DOTNET_CLI_TELEMETRY_OPTOUT="1",
        DOTNET_NOLOGO="1",
        DOTNET_CLI_USE_MSBUILD_SERVER="0",
        MSBUILDDISABLENODEREUSE="1",
        DOTNET_CLI_UI_LANGUAGE="en",
        CARGO_TARGET_DIR=str(ROOT / "target"),
    )
    arm = platform.machine().lower() in ("arm64", "aarch64")
    target, rid = (
        ("aarch64-apple-darwin", "osx-arm64") if arm else ("x86_64-apple-darwin", "osx-x64")
    )
    library = (
        args.library.resolve()
        if args.library
        else ROOT
        / "Artifacts/CSystemPermissions.xcframework/macos-arm64_x86_64/CSystemPermissions.framework/CSystemPermissions"
    )
    if not library.is_file():
        raise SystemExit("Build the tracked framework with make native first")
    output = ROOT / "build/bindings"
    output.mkdir(parents=True, exist_ok=True)
    load("c_compiler").compile_c(
        ROOT / "crates/ffi/tests/c/abi.c",
        output=output / "abi",
        compiler=["xcrun", "clang"],
        include_dirs=[ROOT / "crates/ffi/include"],
        libraries=[library],
        standard="c17",
        flags=["-Wl,-rpath," + str(library.parent.parent)],
        cwd=ROOT,
        env=env,
    )
    run(output / "abi", env=env)
    load("dotnet").run_managed(
        dotnet,
        ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
        cwd=ROOT,
        env=env,
        properties={"SystemPermissionsNativeLibrary": str(library)},
        verify_style=True,
    )
    packages = pack_and_consume(dotnet, library, rid, env, output)
    (output / "acceptance.json").write_text(
        json.dumps(
            {
                "target": target,
                "nativeSha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                "packages": packages,
                "coverage": [
                    "C ownership and buffers",
                    "managed deterministic contracts",
                    "clean local NuGet consumption",
                ],
                "notRun": [
                    "Windows runtime",
                    "packaged AppCapability fixture",
                    "OS permission prompts",
                    "Settings launch",
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("C ownership, .NET contracts and clean NuGet consumer passed; no OS requests were made.")


if __name__ == "__main__":
    main()
