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
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.python = self.root / "python.exe"
        self.dotnet = self.root / "dotnet-x64/dotnet.exe"
        self.tools = self.root / "vc/bin/HostARM64/x64"
        write_pe(self.python, windows.MACHINES["arm64"])
        write_pe(self.dotnet, windows.MACHINES["x64"])
        for name in ("cl.exe", "link.exe", "dumpbin.exe"):
            write_pe(self.tools / name, windows.MACHINES["arm64"])
        self.environment = {
            "VSCMD_ARG_HOST_ARCH": "ARM64",
            "VSCMD_ARG_TGT_ARCH": "X64",
            "VCTOOLSINSTALLDIR": str(self.root / "vc"),
            "DOTNET_BIN": str(self.dotnet),
            "RUSTFLAGS": "-Clink-arg=/INCREMENTAL:NO",
        }
        self.enterContext(patch.object(windows.sys, "executable", str(self.python)))
        self.check = self.enterContext(
            patch.object(
                windows.subprocess,
                "check_output",
                return_value="Host:\n  Architecture: x64\n",
            )
        )

    def test_accepts_arm64_host_tools_and_x64_dotnet(self):
        env, tools, dotnet = windows.arm64_host_x64_environment(self.environment)
        self.assertEqual(tools, self.tools)
        self.assertEqual(dotnet, str(self.dotnet))
        self.assertEqual(env["CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER"], str(tools / "link.exe"))
        self.assertEqual(env["DOTNET_ROOT_X64"], str(self.dotnet.parent))
        self.assertEqual(env["DOTNET_GENERATE_ASPNET_CERTIFICATE"], "false")
        self.assertEqual(
            env["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"),
            ["-Clink-arg=/INCREMENTAL:NO", "-Ctarget-feature=+crt-static"],
        )
        self.assertEqual(self.check.call_args.args[0], [dotnet, "--info"])

    def test_rejects_an_arm64_target_shell(self):
        with self.assertRaisesRegex(SystemExit, "-host_arch=arm64 -arch=x64"):
            windows.arm64_host_x64_environment(dict(self.environment, VSCMD_ARG_TGT_ARCH="ARM64"))
        self.check.assert_not_called()

    def test_rejects_emulated_python_or_msvc(self):
        write_pe(self.python, windows.MACHINES["x64"])
        with self.assertRaisesRegex(SystemExit, "native ARM64 Python"):
            windows.arm64_host_x64_environment(self.environment)
        write_pe(self.python, windows.MACHINES["arm64"])
        write_pe(self.tools / "link.exe", windows.MACHINES["x64"])
        with self.assertRaisesRegex(SystemExit, "native ARM64-hosted x64 MSVC"):
            windows.arm64_host_x64_environment(self.environment)
        self.check.assert_not_called()

    def test_rejects_arm64_dotnet_before_running_it(self):
        write_pe(self.dotnet, windows.MACHINES["arm64"])
        with self.assertRaisesRegex(SystemExit, "absolute path of the x64 .NET 10"):
            windows.arm64_host_x64_environment(self.environment)
        self.check.assert_not_called()

    def test_requires_dotnet_to_report_x64(self):
        self.check.return_value = "Host:\n  Architecture: arm64\n"
        with self.assertRaisesRegex(SystemExit, "Use the x64 .NET 10 SDK"):
            windows.arm64_host_x64_environment(self.environment)


class BuildRouteTests(unittest.TestCase):
    def test_rejects_an_arm64_output_before_detecting_the_host(self):
        with (
            patch.object(windows, "host_architecture") as host,
            patch.object(sys, "stderr"),
            self.assertRaises(SystemExit) as rejected,
        ):
            windows.main(["--architecture", "arm64"])
        self.assertEqual(rejected.exception.code, 2)
        host.assert_not_called()

    def test_x64_is_the_default_target_on_both_hosts(self):
        for host in ("arm64", "x64"):
            with self.subTest(host=host):
                self.check_route(host)

    def test_candidate_tooling_owns_the_hosted_build_and_packages(self):
        self.check_route("arm64", tooling_revision="d" * 40)

    def test_refuses_to_publish_after_candidate_tooling_changes(self):
        self.check_route("arm64", tooling_revision="d" * 40, change_tooling=True)

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
        tooling_revision=None,
        dotnet_version="10.0.403",
        missing_stdlib=False,
        retry=False,
        replace_dll=False,
        change_staged=False,
        change_tooling=False,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            target, rid = "x86_64-pc-windows-msvc", "win-x64"
            library = root / "target" / target / "release/system_permissions.dll"
            write_pe(library, windows.MACHINES["x64"])
            accepted_dll = library.read_bytes()
            library.with_suffix(".dll.lib").write_bytes(b"accepted import library")
            (root / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.99.1"\n')
            (root / "mise.toml").write_text('[tools]\ndotnet = "10.0.403"\n')
            pin = "a" * 40
            (root / "tools").mkdir()
            (root / "tools/tooling-sources.json").write_text(json.dumps({windows.REPOSITORY: pin}))
            candidate = root / "tooling-candidate"
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
                write_pe(output, windows.MACHINES["x64"])

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

            windows_tools = Mock()
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
            info = f"{compiler}\nhost: {windows.HOST_TARGETS[host]}\n"
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
            load_candidate = Mock(side_effect=modules.get)
            with (
                patch.object(windows, "ROOT", root),
                patch.object(windows, "host_architecture", return_value=host),
                patch.object(
                    windows, "arm64_host_x64_environment", return_value=environment
                ) as cross,
                patch.object(
                    windows,
                    "load",
                    side_effect=modules.get,
                ) as load,
                patch.object(windows, "load_candidate", return_value=load_candidate) as select,
                patch.object(
                    windows,
                    "verify",
                    side_effect=ValueError("Pinned SDK tooling source has local changes")
                    if change_tooling
                    else None,
                ) as verify,
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
                args = []
                if tooling_revision:
                    args = [
                        "--architecture",
                        "x64",
                        "--tooling-source",
                        str(candidate),
                        "--tooling-revision",
                        tooling_revision,
                    ]
                if dotnet_version != "10.0.403" or missing_stdlib:
                    pattern = (
                        "pinned Rust standard library" if missing_stdlib else "pinned x64 .NET"
                    )
                    with self.assertRaisesRegex(SystemExit, pattern):
                        windows.main(args)
                    run.assert_not_called()
                    return
                if change_staged:
                    with self.assertRaisesRegex(ValueError, "staged Windows DLL changed"):
                        windows.main(args)
                    artifacts_tools.publish.assert_not_called()
                    self.assertFalse(evidence.exists())
                    self.assertFalse(output.exists())
                    return
                if change_tooling:
                    with self.assertRaisesRegex(ValueError, "tooling source has local changes"):
                        windows.main(args)
                    sdk_bindings.pack_and_consume.assert_called_once()
                    verify.assert_called_once_with(candidate, tooling_revision)
                    artifacts_tools.publish.assert_not_called()
                    return
                windows.main(args)
                if retry:
                    receipt = evidence / "system-permissions-windows.json"
                    previous_receipt = receipt.read_bytes()
                    local_receipt = output / "system-permissions-windows.json"
                    previous_local = local_receipt.read_bytes()
                    payload = b"package rebuilt on retry"
                    write_failure = True
                    with self.assertRaisesRegex(OSError, "Fixture receipt write failed"):
                        windows.main(args)
                    self.assertEqual(receipt.read_bytes(), previous_receipt)
                    self.assertEqual(local_receipt.read_bytes(), previous_local)
                    for name in package_names:
                        self.assertEqual((evidence / name).read_bytes(), b"package fixture")
                        self.assertEqual(
                            (output / "packages" / name).read_bytes(), b"package fixture"
                        )
                    write_failure = False
                    windows.main(args)
                    self.assertEqual(
                        json.loads(receipt.read_bytes())["packages"],
                        dict.fromkeys(package_names, hashlib.sha256(payload).hexdigest()),
                    )
                    self.assertEqual(receipt.read_bytes(), local_receipt.read_bytes())
                    for name in package_names:
                        self.assertEqual((evidence / name).read_bytes(), payload)
                        self.assertEqual((output / "packages" / name).read_bytes(), payload)
                    return
            if tooling_revision:
                select.assert_called_once_with(candidate, tooling_revision)
                verify.assert_called_once_with(candidate, tooling_revision)
                load.assert_not_called()
            else:
                select.assert_not_called()
                verify.assert_not_called()
                load_candidate.assert_not_called()
            cargo_tools.runtime_notices.assert_called_once_with(root, env)
            cargo_tools.CargoDependencies.assert_called_once_with(
                root,
                ("system-permissions-ffi",),
                ("aarch64-apple-darwin", "x86_64-apple-darwin", target),
                env,
            )
            cargo_tools.CargoDependencies.return_value.retain_notices.assert_called_once_with()
            if tooling_revision or host == "x64":
                invocation = windows_tools.native_environment.call_args
                self.assertEqual(invocation.args[0], host)
                self.assertEqual(
                    invocation.kwargs, {"target_architecture": "x64"} if tooling_revision else {}
                )
                self.assertNotIn("DOTNET_HOST_PATH", invocation.args[1])
                cross.assert_not_called()
            else:
                cross.assert_called_once()
                self.assertNotIn("DOTNET_HOST_PATH", cross.call_args.args[0])
                windows_tools.native_environment.assert_not_called()
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
            self.assertEqual(receipt["toolingRevision"], tooling_revision or pin)
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
