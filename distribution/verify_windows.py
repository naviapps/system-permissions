#!/usr/bin/env python3
"""Build and check Windows x64 packages on an owned worker."""

import argparse
import subprocess
import tempfile
from pathlib import Path

from sdk_tooling.adapters import load, support_inputs
from sdk_tooling.c_headers import prepare_generated
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.windows_delivery import (
    RID,
    X64Acceptance,
    acceptance_source,
    export_native,
    publish_package_evidence,
    verify_packages,
)

from distribution.verify_bindings import WINDOWS_ADAPTER, pack_and_consume

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = "system-permissions-windows.json"
PACKAGED_FIXTURE = "fixtures/acceptance/windows/verify-package.ps1"


def check_packaged_desktop(fixture, library, host, env):
    if env.get("GITHUB_ACTIONS") != "true" or env.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ValueError("The MSIX fixture requires a disposable GitHub-hosted Windows runner")
    sdk = Path(env["WINDOWSSDKDIR"]) / "bin" / env["WINDOWSSDKVERSION"].rstrip("\\/") / host
    powershell = Path(env["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    with tempfile.TemporaryDirectory(dir=env["RUNNER_TEMP"], prefix="permissions-msix-") as work:
        subprocess.run(
            [
                str(powershell),
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / PACKAGED_FIXTURE),
                "-Work",
                work,
                "-SdkBin",
                str(sdk),
                "-Fixture",
                str(fixture),
                "-Library",
                str(library),
            ],
            cwd=work,
            env=env,
            check=True,
            timeout=180,
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--packaged-desktop", action="store_true", help="Check an installed MSIX")
    parser.add_argument(
        "--export-native",
        action="store_true",
        help="Export the accepted build for combined NuGet packaging",
    )
    args = parser.parse_args(argv)
    windows, artifacts = (load(name) for name in ("windows", "artifacts"))
    artifact_root = load("vm_environment").artifacts_dir()
    if args.export_native and artifact_root is None:
        parser.error("--export-native requires a verification artifact directory")
    acceptance = X64Acceptance(ROOT)
    host, env = acceptance.host, acceptance.env
    env["DOTNET_GENERATE_ASPNET_CERTIFICATE"] = "false"

    def inputs():
        values = support_inputs(ROOT)
        if args.packaged_desktop:
            values[PACKAGED_FIXTURE] = artifacts.file_sha256(ROOT / PACKAGED_FIXTURE)
        source = (
            acceptance_source(ROOT, match_actions=True, environment=env) if artifact_root else None
        )
        return source, values

    before = inputs()
    prepare_generated(ROOT)
    native = ffi_product(ROOT)
    built = acceptance.build(native)
    native_root = ROOT / ".native-build"
    with (
        artifacts.build_lock(native_root),
        tempfile.TemporaryDirectory(dir=native_root, prefix="permissions-acceptance-") as directory,
    ):
        candidate = Path(directory)
        library, import_library, native_receipt = acceptance.stage(native, built, candidate)
        fixture = candidate / "abi.exe"
        load("c_compiler").compile_c(
            ROOT / "crates/ffi/tests/c/abi.c",
            output=fixture,
            compiler=[acceptance.tools / "cl.exe"],
            include_dirs=[ROOT / "crates/ffi/include"],
            libraries=[import_library],
            flags=("/MT",),
            style="msvc",
            cwd=candidate,
            env=env,
        )
        windows.require_pe_machine(fixture, "x64")
        acceptance.run(fixture)
        packages = pack_and_consume(
            acceptance.dotnet, library, RID, env, candidate, version=native.version
        )
        if args.packaged_desktop:
            check_packaged_desktop(fixture, library, host, env)
        expected = {
            file.name: native_receipt["outputs"][file.name] for file in (library, import_library)
        }
        if artifacts.hashes((library, import_library), candidate) != expected:
            raise ValueError("Staged Windows files changed during acceptance")
        if before != inputs():
            raise ValueError("SDK inputs changed during Windows acceptance")
        if windows.verify_artifact(native, "x64", environment=env)[1] != native_receipt:
            raise ValueError("The Windows native build changed during acceptance")

        packaged_check = (
            "installed x64 MSIX identity, status, direct request and Settings admission"
        )
        receipt = {
            "target": native_receipt["target"],
            "runtime": RID,
            "hostArchitecture": host,
            "executionMode": "x64-emulation" if host == "arm64" else "native",
            "compiler": native_receipt["compiler"],
            "toolInputs": before[1],
            "dependencies": native_receipt["dependencies"],
            "cargoBuild": native_receipt["cargoBuild"],
            "exports": native_receipt["inspection"]["exports"],
            "abiVersions": native_receipt["abiVersions"],
            "abiProbeArchitecture": "x64",
            "nativeSha256": expected[library.name],
            "packages": packages,
            "coverage": [
                "Rust deterministic contracts",
                "Windows source compilation",
                "C ownership and buffer bounds",
                ".NET cancellation and stale-write contracts",
                "unpackaged nonprompting status and unsupported direct request",
                "clean local NuGet consumer",
                *([packaged_check] if args.packaged_desktop else []),
            ],
            "notRun": [
                *([] if args.packaged_desktop else [packaged_check]),
                "OS permission prompts",
                "Settings launch",
                "product integration",
            ],
        }
        if args.export_native:
            verify_packages(candidate / "packages", packages)
            name = f"{WINDOWS_ADAPTER}.{native.version}.nupkg"
            companion = candidate / "companion"
            artifacts.stage_file(candidate / "packages" / name, companion / name)
            inventory = native_receipt["outputs"] | {
                "native-build.json": artifacts.file_sha256(built / "native-build.json")
            }
            export_native(built, inventory, artifact_root)
            publish_package_evidence(
                companion,
                receipt | {"source": before[0][0], "packages": {name: packages[name]}},
                receipt_name=RECEIPT,
                destination=artifact_root / "sdk-nuget-companions",
                tooling=artifacts,
            )
            print(f"Verified the Windows {RID} runtime and Windows adapter on {host}.")
            return
        publish_package_evidence(
            candidate / "packages",
            receipt,
            receipt_name=RECEIPT,
            destination=(artifact_root or (ROOT / "build/windows")) / RID,
            legacy_packages_directory=True,
            tooling=artifacts,
        )
    print(f"Windows {RID} nonprompting acceptance passed on {host} ({receipt['executionMode']}).")


if __name__ == "__main__":
    main()
