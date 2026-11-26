#!/usr/bin/env python3
"""Validate C ownership, .NET contracts and clean, private NuGet consumption."""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from sdk_tooling.adapters import load
from sdk_tooling.artifacts import file_sha256
from sdk_tooling.c_headers import prepare_generated
from sdk_tooling.check_options import select_dotnet_host
from sdk_tooling.dotnet import subprocess_environment
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.xcframework import xcframework

from distribution.pack_nuget import DOTNET, PACKAGE, package_files

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_ADAPTER = PACKAGE + ".Windows"


def consume_pair(dotnet, packages, version, env, output, *, runtime=None, exclude_paths=()):
    load("nuget").run_isolated_consumer(
        dotnet,
        packages=packages,
        references={WINDOWS_ADAPTER: version},
        source=(ROOT / "fixtures/consumers/dotnet/Program.cs").read_text(encoding="utf-8"),
        work_parent=output,
        env=env,
        runtime=runtime,
        properties={
            "DefineConstants": "WINDOWS_ADAPTER",
            "Nullable": "enable",
            "TreatWarningsAsErrors": "true",
            "JsonSerializerIsReflectionEnabledByDefault": "false",
        },
        exclude_paths=exclude_paths,
    )


def pack_and_consume(dotnet, library, rid, env, output):
    runtime = output / "native" / rid
    native_name = "libsystem_permissions.dylib" if rid.startswith("osx-") else library.name
    staged = load("artifacts").stage_native(library, runtime / native_name)
    packages = output / "packages"
    version = ffi_product(ROOT).version
    pack_project = load("dotnet").pack_project
    for name, properties, sources in (
        (
            PACKAGE,
            {
                "SystemPermissionsRuntimeIdentifier": rid,
                "SystemPermissionsNativeLibrary": str(staged),
            },
            (),
        ),
        (WINDOWS_ADAPTER, {"SystemPermissionsPackAdapter": "true"}, (packages,)),
    ):
        pack_project(
            dotnet,
            DOTNET / "src" / name / (name + ".csproj"),
            output=packages,
            cwd=ROOT,
            env=dict(env, NUGET_PACKAGES=str(output / "core-restore")),
            properties={"Version": version, **properties},
            nuget_config=DOTNET / "NuGet.Config",
            sources=sources,
        )
    core, adapter = (packages / f"{name}.{version}.nupkg" for name in (PACKAGE, WINDOWS_ADAPTER))
    audit = load("nuget").audit_package
    hashes = {
        core.name: audit(
            core,
            expected_files=package_files(),
            runtime_files={f"runtimes/{rid}/native/{native_name}": library},
            expected_dependencies=[],
        ),
        adapter.name: audit(
            adapter,
            expected_files=package_files(include_notices=False),
            runtime_files={},
            expected_dependencies=[(PACKAGE, f"[{version}]")],
        ),
    }
    consume_pair(
        dotnet,
        [core, adapter],
        version,
        env,
        output,
        runtime=rid,
        exclude_paths=(ROOT / "target", runtime, library.parent),
    )
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--library", type=Path, help="Explicit already source-built test library")
    inputs.add_argument("--feed", type=Path, help="Verify the combined core and adapter packages")
    inputs.add_argument(
        "--verify-native", action="store_true", help="Verify the tracked framework first"
    )
    args = parser.parse_args()
    if args.feed is not None:
        env = subprocess_environment()
        target = "x64" if sys.platform == "win32" else None
        dotnet, _, _ = select_dotnet_host(env, target)
        version = ffi_product(ROOT).version
        packages = [args.feed / f"{name}.{version}.nupkg" for name in (PACKAGE, WINDOWS_ADAPTER)]
        with tempfile.TemporaryDirectory(prefix="system-permissions-feed-") as temporary:
            consume_pair(
                dotnet, packages, version, env, temporary, runtime="win-x64" if target else None
            )
        return
    if sys.platform != "darwin":
        raise SystemExit(
            "Use distribution/verify_windows.py to build x64 on an owned Windows worker"
        )
    dotnet = os.environ.get("DOTNET_BIN") or shutil.which("dotnet")
    if not dotnet:
        raise SystemExit("Set DOTNET_BIN to the task's .NET 10 executable")
    env = subprocess_environment()
    env.update(
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
    prepare_generated(ROOT, verify=args.verify_native)
    if args.verify_native:
        xcframework(ROOT).verify()
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
    subprocess.run([output / "abi"], cwd=ROOT, env=env, check=True)
    load("dotnet").run_managed(
        dotnet,
        ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
        cwd=ROOT,
        env=env,
        properties={"SystemPermissionsNativeLibrary": str(library)},
        verify_style=True,
    )
    with tempfile.TemporaryDirectory(dir=output, prefix="consumer-") as temporary:
        packages = pack_and_consume(dotnet, library, rid, env, Path(temporary))
    (output / "acceptance.json").write_text(
        json.dumps(
            {
                "target": target,
                "nativeSha256": file_sha256(library),
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
