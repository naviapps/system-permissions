#!/usr/bin/env python3
"""Build and check Windows x64 packages on an owned worker."""

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path

from sdk_tooling import vm_environment as vm
from sdk_tooling.adapters import load, support_inputs

from distribution.verify_bindings import pack_and_consume

ROOT = Path(__file__).resolve().parents[1]
TARGET = "x86_64-pc-windows-msvc"
RID = "win-x64"
RECEIPT = "system-permissions-windows.json"


def verify_packages(directory, packages, *, receipt_name=None):
    names = packages.keys() | ({receipt_name} if receipt_name else set())
    if (
        directory.is_symlink()
        or {path.name for path in directory.iterdir()} != names
        or any(
            (directory / name).is_symlink()
            or not (directory / name).is_file()
            or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest
            for name, digest in packages.items()
        )
    ):
        raise ValueError("Windows package output differs from the accepted package pair")


def publish_x64(package_source, destination, receipt, artifacts):
    packages = receipt["packages"]
    names = packages.keys() | {RECEIPT}
    if (
        destination.parent.is_symlink()
        or destination.parent.is_junction()
        or destination.is_symlink()
        or destination.is_junction()
        or (destination.exists() and not destination.is_dir())
    ):
        raise ValueError("Windows x64 evidence requires an ordinary output directory")

    def owned_file(path, names):
        return path.name in names and path.is_file() and not path.is_symlink()

    if destination.exists():
        for path in destination.iterdir():
            if owned_file(path, names):
                continue
            if (
                path.name == "packages"
                and path.is_dir()
                and not path.is_symlink()
                and not path.is_junction()
                and all(owned_file(file, packages) for file in path.iterdir())
            ):
                # Migrate old local output, which also kept a second copy under packages/.
                continue
            raise ValueError("Windows x64 evidence contains files outside the SDK package pair")

    def verify(directory):
        verify_packages(directory, packages, receipt_name=RECEIPT)
        report = directory / RECEIPT
        if report.is_symlink() or json.loads(report.read_bytes()) != receipt:
            raise ValueError("Windows x64 evidence differs from the accepted package pair")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix="evidence-") as directory:
        stage = Path(directory) / RID
        stage.mkdir()
        for name in packages:
            artifacts.stage_native(package_source / name, stage / name)
        artifacts.write_json(stage / RECEIPT, receipt)
        verify(stage)
        artifacts.publish(stage, destination, lambda: verify(destination))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    tool_inputs = support_inputs(ROOT)

    windows = load("windows")
    host = windows.host_architecture()
    artifacts = load("artifacts")
    cargo = load("cargo")
    notice_targets = (*load("ffi").DARWIN_TARGETS, TARGET)
    emulated = host == "arm64"
    environment = {
        key.upper(): value for key, value in os.environ.items() if key.upper() != "DOTNET_HOST_PATH"
    }
    environment["DOTNET_GENERATE_ASPNET_CERTIFICATE"] = "false"
    env, tools, dotnet = windows.native_environment(host, environment, target_architecture="x64")
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
        or "host: " + windows.MSVC_TARGETS[host] not in compiler_info
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
    local = ROOT / "build/windows"
    output = (vm.artifacts_dir(env) or local) / RID
    with (
        artifacts.build_lock(local),
        tempfile.TemporaryDirectory(dir=local, prefix="candidate-") as directory,
    ):
        candidate = Path(directory)
        fixture = candidate / "abi.exe"
        library = artifacts.stage_native(
            built / "system_permissions.dll", candidate / "system_permissions.dll"
        )
        import_library = artifacts.stage_native(
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
        load("c_compiler").compile_c(
            ROOT / "crates/ffi/tests/c/abi.c",
            output=fixture,
            compiler=[tools / "cl.exe"],
            include_dirs=[ROOT / "crates/ffi/include"],
            libraries=[import_library],
            style="msvc",
            cwd=ROOT,
            env=env,
        )
        windows.require_pe_machine(fixture, "x64")
        run(fixture)
        env["SYSTEM_PERMISSIONS_NATIVE_LIBRARY"] = str(library)
        load("dotnet").run_managed(
            dotnet,
            ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
            cwd=ROOT,
            env=env,
            verify_style=True,
        )
        packages = pack_and_consume(dotnet, library, RID, env, candidate)
        verify_packages(candidate / "packages", packages)
        if hashlib.sha256(library.read_bytes()).hexdigest() != native_hash:
            raise ValueError("The staged Windows DLL changed during acceptance")
        if support_inputs(ROOT) != tool_inputs:
            raise ValueError("SDK tool inputs changed during Windows acceptance")
        receipt = {
            "target": TARGET,
            "runtime": RID,
            "hostArchitecture": host,
            "executionMode": "x64-emulation" if emulated else "native",
            "compiler": compiler,
            "toolInputs": tool_inputs,
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
        publish_x64(candidate / "packages", output, receipt, artifacts)
    print(f"Windows {RID} nonprompting acceptance passed on {host} ({receipt['executionMode']}).")


if __name__ == "__main__":
    main()
