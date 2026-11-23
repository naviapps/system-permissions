"""Exercise Windows host selection, child commands and receipts using owned fixtures."""

import hashlib
import importlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
windows = importlib.import_module("windows")


def write_pe(path, machine):
    path.parent.mkdir(parents=True, exist_ok=True)
    header = b"MZ" + bytes(58) + (64).to_bytes(4, "little")
    path.write_bytes(header + b"PE\0\0" + machine.to_bytes(2, "little"))


class CrossEnvironmentTests(unittest.TestCase):
    def test_arm64_host_requires_the_explicit_x64_dotnet_executable(self):
        support = windows.load("windows")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            dotnet = root / "dotnet-x64/dotnet.exe"
            tools = root / "vc/bin/HostARM64/x64"
            environment = {"DOTNET_BIN": str(dotnet), "DOTNET_ROOT": str(root / "arm64")}
            with (
                patch.object(
                    support, "native_msvc_environment", return_value=(environment, tools)
                ) as select,
                patch.object(
                    support.subprocess,
                    "check_output",
                    side_effect=["Architecture: x64", "10.0.403"],
                ) as probe,
            ):
                write_pe(dotnet, 0xAA64)
                with self.assertRaisesRegex(ValueError, "target-native x64 PE image"):
                    support.native_environment("arm64", environment, target_architecture="x64")
                probe.assert_not_called()
                select.reset_mock()
                write_pe(dotnet, 0x8664)
                env, selected_tools, executable = support.native_environment(
                    "arm64", environment, target_architecture="x64"
                )
            select.assert_called_once_with("arm64", environment, target_architecture="x64")
            self.assertEqual(selected_tools, tools)
            self.assertEqual(executable, str(dotnet))
            self.assertEqual(env["DOTNET_ROOT_X64"], str(dotnet.parent))
            self.assertIn("-Ctarget-feature=+crt-static", env["CARGO_ENCODED_RUSTFLAGS"])


class BuildRouteTests(unittest.TestCase):
    def test_rejects_an_arm64_output_before_detecting_the_host(self):
        with (
            patch.object(windows, "load") as load,
            patch.object(sys, "stderr"),
            self.assertRaises(SystemExit) as rejected,
        ):
            windows.main(["--architecture", "arm64"])
        self.assertEqual(rejected.exception.code, 2)
        load.assert_not_called()

    def test_x64_is_the_default_target_on_both_hosts(self):
        for host in ("arm64", "x64"):
            with self.subTest(host=host):
                self.check_route(host)

    def test_refuses_to_publish_after_sdk_tool_inputs_change(self):
        self.check_route("arm64", change_inputs=True)

    def test_rejects_a_non_x64_c_fixture_before_running_it(self):
        self.check_route("arm64", fixture_machine=0xAA64)

    def test_requires_pinned_dotnet_before_cargo(self):
        self.check_route("arm64", dotnet_version="10.0.404")

    def test_requires_x64_rust_standard_library_before_cargo(self):
        self.check_route("arm64", missing_stdlib=True)

    def test_x64_retry_preserves_previous_package_pair_when_receipt_write_fails(self):
        self.check_route("arm64", retry=True)

    def test_x64_managed_packages_use_the_dll_already_loaded_by_the_c_fixture(self):
        self.check_route("arm64", replace_dll=True)

    def test_x64_refuses_to_publish_when_the_staged_dll_changes(self):
        self.check_route("arm64", change_staged=True)

    def test_x64_preserves_unrelated_existing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "win-x64"
            output.mkdir()
            unrelated = output / "notes.txt"
            unrelated.write_text("Keep this file", encoding="utf-8")
            bindings, artifacts = Mock(), Mock()
            with self.assertRaisesRegex(ValueError, "outside the SDK package pair"):
                windows.publish_x64(
                    root,
                    output,
                    output,
                    {"packages": {"fixture.nupkg": "digest"}},
                    bindings,
                    artifacts,
                )
            bindings.stage_native.assert_not_called()
            artifacts.publish.assert_not_called()
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "Keep this file")

    def check_route(
        self,
        host,
        *,
        dotnet_version="10.0.403",
        missing_stdlib=False,
        retry=False,
        replace_dll=False,
        change_staged=False,
        change_inputs=False,
        fixture_machine=0x8664,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            target, rid = "x86_64-pc-windows-msvc", "win-x64"
            library = root / "target" / target / "release/system_permissions.dll"
            write_pe(library, 0x8664)
            accepted_dll = library.read_bytes()
            library.with_suffix(".dll.lib").write_bytes(b"accepted import library")
            (root / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.99.1"\n')
            (root / "mise.toml").write_text('[tools]\ndotnet = "10.0.403"\n')
            support = windows.load("windows")
            tool_inputs = {"fixtures/distribution/windows.py": "a" * 64}
            final_inputs = (
                {"fixtures/distribution/windows.py": "d" * 64} if change_inputs else tool_inputs
            )
            libdir = root / "stdlib" / target
            libdir.mkdir(parents=True)
            if not missing_stdlib:
                (libdir / "libstd-fixture.rlib").touch()
            tools = root / "msvc"
            dotnet = str(root / "dotnet.exe")
            evidence = root / "evidence"
            env = {"CARGO_ENCODED_RUSTFLAGS": "", "PATH": "", "NAVI_CI_ARTIFACTS": str(evidence)}
            environment = env, tools, dotnet
            output = root / "build/windows" / rid
            evidence /= rid
            (root / library.name).write_bytes(b"stale DLL outside the fixture")
            payload = b"package fixture"
            write_failure = False
            package_names = ("Permission.0.1.0.nupkg", "Permission.Windows.0.1.0.nupkg")

            def compile_fixture(*_args, output, **_kwargs):
                write_pe(output, fixture_machine)

            def stage_fixture(source, destination):
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                return destination

            def pack_fixture(_dotnet, selected_library, _rid, _env, output, *, tooling):
                self.assertEqual(selected_library.read_bytes(), accepted_dll)
                self.assertIs(tooling, bindings_tools)
                packages = output / "packages"
                packages.mkdir()
                for name in package_names:
                    (packages / name).write_bytes(payload)
                if change_staged:
                    selected_library.write_bytes(accepted_dll + b"changed staged library")
                return dict.fromkeys(package_names, hashlib.sha256(payload).hexdigest())

            def run_fixture(command, **_kwargs):
                if Path(command[0]).name == "abi.exe":
                    staged_dll = Path(command[0]).with_name(library.name)
                    self.assertEqual(staged_dll.read_bytes(), accepted_dll)
                    if replace_dll:
                        replacement = library.with_name("replacement.dll")
                        replacement.write_bytes(accepted_dll + b"concurrent Cargo output")
                        replacement.replace(library)

            def managed_fixture(_dotnet, _project, *, env, **_kwargs):
                selected_library = Path(env["SYSTEM_PERMISSIONS_NATIVE_LIBRARY"])
                self.assertEqual(selected_library.read_bytes(), accepted_dll)

            def report_fixture(path, data):
                for name, digest in data["packages"].items():
                    copied = (path.parent / name).read_bytes()
                    self.assertEqual(hashlib.sha256(copied).hexdigest(), digest)
                if write_failure and path.is_relative_to(evidence.parent):
                    raise OSError("Fixture receipt write failed")
                path.write_text(json.dumps(data), encoding="utf-8")

            windows_tools = Mock(wraps=support, MSVC_TARGETS=support.MSVC_TARGETS)
            windows_tools.host_architecture.return_value = host
            windows_tools.native_environment.return_value = environment
            windows_tools.verify_library.return_value = {"system_permissions_abi_version"}
            bindings_tools = Mock()
            bindings_tools.compile_c.side_effect = compile_fixture
            bindings_tools.stage_native.side_effect = stage_fixture
            bindings_tools.run_managed.side_effect = managed_fixture
            artifacts_tools = Mock(wraps=windows.load("artifacts"))
            artifacts_tools.write_json.side_effect = report_fixture
            cargo_tools = Mock()
            native_tools = Mock(DARWIN_TARGETS=("aarch64-apple-darwin", "x86_64-apple-darwin"))
            sdk_bindings = Mock()
            sdk_bindings.pack_and_consume.side_effect = pack_fixture
            compiler = "rustc 1.99.1 (fixture)"
            info = f"{compiler}\nhost: {support.MSVC_TARGETS[host]}\n"
            outputs = {
                (dotnet, "--version"): dotnet_version + "\n",
                ("rustc", "--version", "--verbose"): info,
                ("rustc", "--print", "target-libdir", "--target", target): str(libdir) + "\n",
            }
            modules = {
                "windows": windows_tools,
                "bindings": bindings_tools,
                "artifacts": artifacts_tools,
                "cargo": cargo_tools,
                "native": native_tools,
            }
            with (
                patch.object(windows, "ROOT", root),
                patch.object(windows, "load", side_effect=modules.get),
                patch.object(
                    windows, "support_inputs", side_effect=(tool_inputs, final_inputs) * 3
                ),
                patch.object(
                    windows.subprocess,
                    "check_output",
                    side_effect=lambda args, **_: outputs[tuple(args)],
                ),
                patch.object(windows.subprocess, "run", side_effect=run_fixture) as run,
                patch.dict(sys.modules, {"bindings": sdk_bindings}),
                patch.dict(os.environ, {"DOTNET_HOST_PATH": "other architecture"}),
                patch("builtins.print") as report,
            ):
                if dotnet_version != "10.0.403" or missing_stdlib:
                    pattern = (
                        "pinned Rust standard library" if missing_stdlib else "pinned x64 .NET"
                    )
                    with self.assertRaisesRegex(SystemExit, pattern):
                        windows.main([])
                    run.assert_not_called()
                    return
                if fixture_machine != 0x8664:
                    with self.assertRaisesRegex(ValueError, "target-native x64 PE image"):
                        windows.main([])
                    self.assertTrue(
                        all(Path(call.args[0][0]).name != "abi.exe" for call in run.call_args_list)
                    )
                    bindings_tools.run_managed.assert_not_called()
                    sdk_bindings.pack_and_consume.assert_not_called()
                    artifacts_tools.publish.assert_not_called()
                    return
                if change_staged:
                    with self.assertRaisesRegex(ValueError, "staged Windows DLL changed"):
                        windows.main([])
                    artifacts_tools.publish.assert_not_called()
                    self.assertFalse(evidence.exists())
                    self.assertFalse(output.exists())
                    return
                if change_inputs:
                    with self.assertRaisesRegex(ValueError, "SDK tool inputs changed"):
                        windows.main([])
                    sdk_bindings.pack_and_consume.assert_called_once()
                    artifacts_tools.publish.assert_not_called()
                    return
                windows.main([])
                if retry:
                    receipt = evidence / "system-permissions-windows.json"
                    previous_receipt = receipt.read_bytes()
                    local_receipt = output / "system-permissions-windows.json"
                    previous_local = local_receipt.read_bytes()
                    payload = b"package rebuilt on retry"
                    write_failure = True
                    with self.assertRaisesRegex(OSError, "Fixture receipt write failed"):
                        windows.main([])
                    self.assertEqual(receipt.read_bytes(), previous_receipt)
                    self.assertEqual(local_receipt.read_bytes(), previous_local)
                    for name in package_names:
                        self.assertEqual((evidence / name).read_bytes(), b"package fixture")
                        self.assertEqual(
                            (output / "packages" / name).read_bytes(), b"package fixture"
                        )
                    write_failure = False
                    windows.main([])
                    self.assertEqual(
                        json.loads(receipt.read_bytes())["packages"],
                        dict.fromkeys(package_names, hashlib.sha256(payload).hexdigest()),
                    )
                    self.assertEqual(receipt.read_bytes(), local_receipt.read_bytes())
                    for name in package_names:
                        self.assertEqual((evidence / name).read_bytes(), payload)
                        self.assertEqual((output / "packages" / name).read_bytes(), payload)
                    return
            cargo_tools.runtime_notices.assert_called_once_with(root, env)
            cargo_tools.CargoDependencies.assert_called_once_with(
                root,
                ("system-permissions-ffi",),
                ("aarch64-apple-darwin", "x86_64-apple-darwin", target),
                env,
            )
            cargo_tools.CargoDependencies.return_value.retain_notices.assert_called_once_with()
            invocation = windows_tools.native_environment.call_args
            self.assertEqual(invocation.args[0], host)
            self.assertEqual(invocation.kwargs, {"target_architecture": "x64"})
            self.assertNotIn("DOTNET_HOST_PATH", invocation.args[1])
            self.assertEqual(invocation.args[1]["DOTNET_GENERATE_ASPNET_CERTIFICATE"], "false")
            commands = [call.args[0] for call in run.call_args_list]
            fixture = Path(commands[-1][0])
            self.assertEqual(fixture.name, "abi.exe")
            self.assertEqual(fixture.parent.parent, output.parent)
            self.assertFalse(fixture.parent.exists())
            self.assertEqual({entry.name for entry in output.parent.iterdir()}, {rid})
            self.assertEqual({entry.name for entry in evidence.parent.iterdir()}, {rid})
            self.assertEqual(
                [command[1] for command in commands if "--target" in command],
                ["fetch", "clippy", "test", "build"],
            )
            self.assertTrue(
                all(
                    command[command.index("--target") + 1] == target
                    for command in commands
                    if "--target" in command
                )
            )
            self.assertEqual(windows_tools.verify_library.call_args.args[-1], "x64")
            accepted_copy = fixture.parent / library.name
            self.assertEqual(windows_tools.verify_library.call_args.args[0], accepted_copy)
            self.assertEqual(
                bindings_tools.compile_c.call_args.kwargs["libraries"],
                [accepted_copy.with_suffix(".dll.lib")],
            )
            self.assertEqual(bindings_tools.run_managed.call_args.args[0], dotnet)
            self.assertEqual(env["SYSTEM_PERMISSIONS_NATIVE_LIBRARY"], str(accepted_copy))
            self.assertNotIn(str(library.parent), env["PATH"].split(os.pathsep))
            sdk_bindings.pack_and_consume.assert_called_once_with(
                dotnet, accepted_copy, rid, env, fixture.parent, tooling=bindings_tools
            )
            receipt = json.loads((evidence / "system-permissions-windows.json").read_bytes())
            self.assertEqual(receipt["nativeSha256"], hashlib.sha256(accepted_dll).hexdigest())
            self.assertEqual(receipt["target"], target)
            self.assertEqual(receipt["runtime"], rid)
            self.assertEqual(receipt["toolInputs"], tool_inputs)
            self.assertEqual(receipt["hostArchitecture"], host)
            self.assertEqual(
                receipt["executionMode"], "native" if host == "x64" else "x64-emulation"
            )
            report.assert_called_once_with(
                f"Windows {rid} nonprompting acceptance passed on {host} "
                f"({receipt['executionMode']})."
            )
            self.assertEqual((evidence / "Permission.0.1.0.nupkg").read_bytes(), b"package fixture")

    def test_package_verification_rejects_changed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            package_directory = Path(directory)
            package = package_directory / "Permission.0.1.0.nupkg"
            package.write_bytes(b"accepted")
            hashes = {package.name: hashlib.sha256(package.read_bytes()).hexdigest()}
            windows.verify_packages(package_directory, hashes)
            package.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "differs from the accepted package pair"):
                windows.verify_packages(package_directory, hashes)


if __name__ == "__main__":
    unittest.main()
