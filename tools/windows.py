#!/usr/bin/env python3
"""Build and check private Windows packages in an existing owned worker."""

import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import tomllib
from contextlib import ExitStack
from pathlib import Path

from _tooling import REPOSITORY, load, load_candidate, verify

ROOT = Path(__file__).resolve().parent.parent
TARGET = "x86_64-pc-windows-msvc"
RID = "win-x64"
HOST_TARGETS = {"arm64": "aarch64-pc-windows-msvc", "x64": TARGET}
MACHINES = {"arm64": 0xAA64, "x64": 0x8664}
RECEIPT = "system-permissions-windows.json"


def host_architecture():
    architecture = {
        "arm64": "arm64",
        "aarch64": "arm64",
        "amd64": "x64",
        "x86_64": "x64",
    }.get(platform.machine().lower())
    if sys.platform != "win32" or architecture is None:
        raise SystemExit("Use an owned Windows ARM64 or x64 worker")
    return architecture


def pe_machine(path):
    with path.open("rb") as image:
        dos = image.read(64)
        if len(dos) == 64 and dos[:2] == b"MZ":
            image.seek(int.from_bytes(dos[60:], "little"))
            header = image.read(6)
            if len(header) == 6 and header[:4] == b"PE\0\0":
                return int.from_bytes(header[4:], "little")
    raise ValueError(f"Invalid PE header: {path}")


def arm64_host_x64_environment(environment):
    env = environment.copy()
    if (
        env.get("VSCMD_ARG_HOST_ARCH", "").lower() != "arm64"
        or env.get("VSCMD_ARG_TGT_ARCH", "").lower() != "x64"
    ):
        raise SystemExit("Prepare VsDevCmd.bat -host_arch=arm64 -arch=x64 before building")
    if pe_machine(Path(sys.executable)) != MACHINES["arm64"]:
        raise SystemExit("Use native ARM64 Python for this build")
    vc = Path(env.get("VCTOOLSINSTALLDIR", ""))
    tools = vc / "bin" / "HostARM64" / "x64"
    if not vc.is_absolute() or any(
        not (tools / name).is_file() or pe_machine(tools / name) != MACHINES["arm64"]
        for name in ("cl.exe", "link.exe", "dumpbin.exe")
    ):
        raise SystemExit("Select the native ARM64-hosted x64 MSVC tools")
    dotnet = Path(env.get("DOTNET_BIN", ""))
    if not dotnet.is_absolute() or not dotnet.is_file() or pe_machine(dotnet) != MACHINES["x64"]:
        raise SystemExit("Set DOTNET_BIN to the absolute path of the x64 .NET 10 executable")
    env.update(
        CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=str(tools / "link.exe"),
        PATH=str(tools) + os.pathsep + env.get("PATH", ""),
        DOTNET_ROOT=str(dotnet.parent),
        DOTNET_ROOT_X64=str(dotnet.parent),
        DOTNET_CLI_TELEMETRY_OPTOUT="1",
        DOTNET_NOLOGO="1",
        DOTNET_CLI_USE_MSBUILD_SERVER="0",
        DOTNET_GENERATE_ASPNET_CERTIFICATE="false",
        MSBUILDDISABLENODEREUSE="1",
        DOTNET_CLI_UI_LANGUAGE="en",
        VSLANG="1033",
    )
    encoded = env.get("CARGO_ENCODED_RUSTFLAGS")
    flags = encoded.split("\x1f") if encoded else shlex.split(env.get("RUSTFLAGS", ""))
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join([*flags, "-Ctarget-feature=+crt-static"])
    info = subprocess.check_output([str(dotnet), "--info"], cwd=ROOT, env=env, text=True)
    if not re.search(r"(?m)^[ \t]+Architecture:[ \t]+x64[ \t]*$", info):
        raise SystemExit("Use the x64 .NET 10 SDK for the Windows x64 fixture")
    return env, tools, str(dotnet)


def verify_packages(directory, packages):
    if (
        directory.is_symlink()
        or set(path.name for path in directory.iterdir()) != packages.keys()
        or any(
            (directory / name).is_symlink()
            or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest
            for name, digest in packages.items()
        )
    ):
        raise ValueError("Windows package output differs from the accepted package pair")


def publish_x64(package_source, output, artifacts, receipt, bindings, tooling):
    packages = receipt["packages"]
    destinations = [(output, True)]
    local, external = output.resolve(), artifacts.resolve()
    if local != external:
        if local.is_relative_to(external) or external.is_relative_to(local):
            raise ValueError("Local and CI x64 evidence directories must be disjoint")
        destinations.append((artifacts, False))

    def verify(directory, nested):
        names = packages.keys() | {RECEIPT}
        if nested:
            names.add("packages")
            verify_packages(directory / "packages", packages)
        if (
            {path.name for path in directory.iterdir()} != names
            or (directory / RECEIPT).is_symlink()
            or json.loads((directory / RECEIPT).read_bytes()) != receipt
            or any(
                (directory / name).is_symlink()
                or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest
                for name, digest in packages.items()
            )
        ):
            raise ValueError("Windows x64 evidence differs from the accepted package pair")

    with ExitStack() as stack:
        staged = []
        for destination, nested in destinations:
            if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
                raise ValueError("Windows x64 evidence requires an ordinary output directory")
            if destination.exists():
                for path in destination.iterdir():
                    if (
                        nested
                        and path.name == "packages"
                        and path.is_dir()
                        and not path.is_symlink()
                    ):
                        if all(
                            entry.name in packages and entry.is_file() and not entry.is_symlink()
                            for entry in path.iterdir()
                        ):
                            continue
                    elif (
                        (path.name in packages or path.name == RECEIPT)
                        and path.is_file()
                        and not path.is_symlink()
                    ):
                        continue
                    raise ValueError(
                        "Windows x64 evidence contains files outside the SDK package pair"
                    )
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = stack.enter_context(
                tempfile.TemporaryDirectory(dir=destination.parent, prefix="evidence-")
            )
            stage = Path(temporary) / "win-x64"
            stage.mkdir()
            for name in packages:
                bindings.stage_native(package_source / name, stage / name)
                if nested:
                    bindings.stage_native(package_source / name, stage / "packages" / name)
            tooling.write_json(stage / RECEIPT, receipt)
            verify(stage, nested)
            staged.append((stage, destination, nested))
        for stage, destination, nested in staged:
            tooling.publish(
                stage, destination, lambda path=destination, local=nested: verify(path, local)
            )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", choices=("x64",), default="x64")
    parser.add_argument("--tooling-source", type=Path, help="Local candidate SDK tooling checkout")
    parser.add_argument(
        "--tooling-revision", help="Exact Git commit of the local tooling candidate"
    )
    args = parser.parse_args(argv)
    if (args.tooling_source is None) != (args.tooling_revision is None):
        parser.error("Use --tooling-source and --tooling-revision together")
    host = host_architecture()
    pins = ROOT / "tools/tooling-sources.json"
    tooling_revision = args.tooling_revision or json.loads(pins.read_text())[REPOSITORY]
    selected = load
    if args.tooling_source is not None:
        selected = load_candidate(args.tooling_source, args.tooling_revision)

    import bindings as sdk_bindings

    windows = selected("windows")
    bindings = selected("bindings")
    artifact_tooling = selected("artifacts")
    cargo = selected("cargo")
    notice_targets = (*selected("native").DARWIN_TARGETS, TARGET)
    emulated = host == "arm64"
    environment = {
        key.upper(): value for key, value in os.environ.items() if key.upper() != "DOTNET_HOST_PATH"
    }
    if emulated and args.tooling_source is None:
        env, tools, dotnet = arm64_host_x64_environment(environment)
    elif emulated:
        env, tools, dotnet = windows.native_environment(
            host, environment, target_architecture="x64"
        )
    else:
        env, tools, dotnet = windows.native_environment("x64", environment)
    version = subprocess.check_output([dotnet, "--version"], cwd=ROOT, env=env, text=True).strip()
    if version != tomllib.loads((ROOT / "mise.toml").read_text())["tools"]["dotnet"]:
        raise SystemExit("Use the pinned x64 .NET SDK from mise.toml")
    env["CARGO_TARGET_DIR"] = str(ROOT / "target")
    flags = [
        *env["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"),
        "--remap-path-prefix=" + str(ROOT) + "=/system-permissions",
        "--remap-path-prefix=" + str(Path.home()) + "=/developer",
    ]
    if env.get("CARGO_HOME"):
        flags.append("--remap-path-prefix=" + env["CARGO_HOME"] + "=/cargo")
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(flags)
    compiler_info = subprocess.check_output(
        ["rustc", "--version", "--verbose"], cwd=ROOT, env=env, text=True
    ).splitlines()
    compiler = compiler_info[0]
    pinned = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())["toolchain"]["channel"]
    if (
        not compiler.startswith("rustc " + pinned + " ")
        or "host: " + HOST_TARGETS[host] not in compiler_info
    ):
        raise SystemExit("Use the pinned Rust toolchain built for the host architecture")

    def run(*args):
        subprocess.run([str(a) for a in args], cwd=ROOT, env=env, check=True)

    rust_libdir = Path(
        subprocess.check_output(
            ["rustc", "--print", "target-libdir", "--target", TARGET], cwd=ROOT, env=env, text=True
        ).strip()
    )
    if not rust_libdir.is_absolute() or not any(
        library.is_file() for library in rust_libdir.glob("libstd-*.rlib")
    ):
        raise SystemExit(f"Install the pinned Rust standard library for {TARGET}")

    run("cargo", "fetch", "--locked", "--target", TARGET)
    cargo.runtime_notices(ROOT, env)
    cargo.CargoDependencies(ROOT, ("system-permissions-ffi",), notice_targets, env).retain_notices()
    run("cargo", "fmt", "--all", "--", "--check")
    run(
        "cargo",
        "clippy",
        "--workspace",
        "--all-targets",
        "--target",
        TARGET,
        "--locked",
        "--offline",
        "--",
        "-D",
        "warnings",
    )
    run("cargo", "test", "--workspace", "--target", TARGET, "--locked", "--offline")
    run(
        "cargo",
        "build",
        "-p",
        "system-permissions-ffi",
        "--release",
        "--target",
        TARGET,
        "--locked",
        "--offline",
    )
    built = ROOT / "target" / TARGET / "release"
    output = ROOT / "build/windows" / RID
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix="candidate-") as directory:
        candidate = Path(directory)
        fixture = candidate / "abi.exe"
        library = bindings.stage_native(
            built / "system_permissions.dll", candidate / "system_permissions.dll"
        )
        import_library = bindings.stage_native(
            built / "system_permissions.dll.lib", candidate / "system_permissions.dll.lib"
        )
        native_hash = hashlib.sha256(library.read_bytes()).hexdigest()
        expected = windows.verify_library(
            library,
            [ROOT / "crates/ffi/include/system_permissions.h"],
            "system_permissions_",
            tools,
            env,
            "x64",
        )
        bindings.compile_c(
            ROOT / "crates/ffi/tests/c/abi.c",
            output=fixture,
            compiler=[tools / "cl.exe"],
            include_dirs=[ROOT / "crates/ffi/include"],
            libraries=[import_library],
            style="msvc",
            cwd=ROOT,
            env=env,
        )
        if pe_machine(fixture) != MACHINES["x64"]:
            raise SystemExit("The C fixture differs from the selected runtime architecture")
        run(fixture)
        env["SYSTEM_PERMISSIONS_NATIVE_LIBRARY"] = str(library)
        bindings.run_managed(
            dotnet,
            ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
            cwd=ROOT,
            env=env,
            verify_style=True,
        )
        packages = sdk_bindings.pack_and_consume(
            dotnet, library, RID, env, candidate, tooling=bindings
        )
        verify_packages(candidate / "packages", packages)
        if hashlib.sha256(library.read_bytes()).hexdigest() != native_hash:
            raise ValueError("The staged Windows DLL changed during acceptance")
        if args.tooling_source is not None:
            verify(args.tooling_source, tooling_revision)
        elif json.loads(pins.read_text())[REPOSITORY] != tooling_revision:
            raise ValueError("The SDK tooling pin changed during Windows acceptance")
        receipt = {
            "target": TARGET,
            "runtime": RID,
            "hostArchitecture": host,
            "executionMode": "x64-emulation" if emulated else "native",
            "compiler": compiler,
            "toolingRevision": tooling_revision,
            "exports": sorted(expected),
            "nativeSha256": native_hash,
            "packages": packages,
            "coverage": [
                "Rust deterministic contracts",
                "Windows source compilation",
                "C ownership and buffer bounds",
                ".NET cancellation and stale-write contracts",
                "unpackaged nonprompting AppCapability status",
                "clean local NuGet consumer",
            ],
            "notRun": [
                "packaged AppCapability fixture",
                "OS permission prompts",
                "Settings launch",
                "product integration",
            ],
        }
        artifacts = Path(env["NAVI_CI_ARTIFACTS"]) / RID if env.get("NAVI_CI_ARTIFACTS") else output
        publish_x64(candidate / "packages", output, artifacts, receipt, bindings, artifact_tooling)
    print(f"Windows {RID} nonprompting acceptance passed on {host} ({receipt['executionMode']}).")


if __name__ == "__main__":
    main()
