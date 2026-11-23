#!/usr/bin/env python3
"""Build and check Windows x64 packages on an owned worker."""

import argparse
import hashlib
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path

from sdk_tooling import vm_environment as vm
from sdk_tooling.adapters import load, support_inputs
from sdk_tooling.dotnet import pinned_sdk_version
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.windows_delivery import (
    RID,
    TARGET,
    locked_fetch_args,
    publish_package_evidence,
    verify_packages,
)

from distribution.verify_bindings import pack_and_consume

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = "system-permissions-windows.json"


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
    if version != pinned_sdk_version(ROOT):
        raise SystemExit("Use the pinned x64 .NET SDK from global.json")
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

    rust_libdir = subprocess.check_output(
        ["rustc", "--print", "target-libdir", "--target", TARGET], cwd=ROOT, env=env, text=True
    ).strip()
    try:
        windows.require_rust_target_stdlib(rust_libdir, TARGET)
    except ValueError as error:
        raise SystemExit(str(error)) from None

    run(*locked_fetch_args(notice_targets=notice_targets))
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
    built = ROOT / "target" / TARGET / "release"
    product = ffi_product(ROOT)
    cargo_build = load("cargo_build")
    graph = cargo.CargoDependencies(ROOT, [product.package], [TARGET], env)
    dependencies = graph.provenance()
    units = {
        TARGET: cargo_build.compile_units(
            [
                "cargo",
                "build",
                "-p",
                product.package,
                "--release",
                "--target",
                TARGET,
                "--locked",
                "--offline",
                "--message-format=json-render-diagnostics",
            ],
            graph=graph,
            target=TARGET,
            library=built / "system_permissions.dll",
            env=env,
        )
    }
    cargo_build.verify_units(units, dependencies, [TARGET], product.package, product.library)
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
        windows.probe_abi(product, library, import_library, tools, env, "x64")
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
        load("dotnet").run_managed(
            dotnet,
            ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
            cwd=ROOT,
            env=env,
            properties={"SystemPermissionsNativeLibrary": str(library)},
            verify_style=True,
        )
        packages = pack_and_consume(dotnet, library, RID, env, candidate)
        verify_packages(candidate / "packages", packages)
        if hashlib.sha256(library.read_bytes()).hexdigest() != native_hash:
            raise ValueError("The staged Windows DLL changed during acceptance")
        if support_inputs(ROOT) != tool_inputs:
            raise ValueError("SDK tool inputs changed during Windows acceptance")
        if graph.provenance() != dependencies:
            raise ValueError("Native dependencies changed during Windows acceptance")
        receipt = {
            "target": TARGET,
            "runtime": RID,
            "hostArchitecture": host,
            "executionMode": "x64-emulation" if emulated else "native",
            "compiler": compiler,
            "toolInputs": tool_inputs,
            "dependencies": dependencies,
            "cargoBuild": units,
            "exports": sorted(expected),
            "abiVersions": product.abi_versions(windows=True),
            "abiProbeArchitecture": "x64",
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
        publish_package_evidence(
            candidate / "packages",
            receipt,
            receipt_name=RECEIPT,
            destination=output,
            legacy_packages_directory=True,
            tooling=artifacts,
        )
    print(f"Windows {RID} nonprompting acceptance passed on {host} ({receipt['executionMode']}).")


if __name__ == "__main__":
    main()
