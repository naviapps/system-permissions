"""Exercise Windows host selection, child commands and receipts using owned fixtures."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from distribution import verify_windows as windows


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
    def test_msix_fixture_never_runs_on_a_shared_worker(self):
        with (
            patch.object(windows.subprocess, "run") as run,
            self.assertRaisesRegex(ValueError, "disposable GitHub-hosted"),
        ):
            windows.check_packaged_desktop(
                Path("abi.exe"),
                Path("system_permissions.dll"),
                "x64",
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
            )
        run.assert_not_called()

    def test_checks_the_adapter_pair_before_exporting_the_native_build(self):
        for host in ("x64", "arm64"):
            with self.subTest(host=host):
                self.check_route(host, export_native=True)

    def test_local_publish_flattens_the_legacy_pair(self):
        self.check_route("x64", use_artifact_root=False)

    def test_refuses_evidence_when_inputs_change(self):
        self.check_route("arm64", change_inputs=True, export_native=True)

    def test_rejects_a_non_x64_consumer_before_running_it(self):
        self.check_route("arm64", fixture_machine=0xAA64)

    def test_refuses_evidence_when_accepted_files_change(self):
        for change in ("staged", "native"):
            with self.subTest(change=change):
                self.check_route("arm64", change_files=change, export_native=True)

    def check_route(
        self,
        host,
        *,
        use_artifact_root=True,
        export_native=False,
        change_inputs=False,
        change_files=None,
        fixture_machine=0x8664,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built = root / ".native-build/windows/win-x64"
            library = built / "system_permissions.dll"
            write_pe(library, 0x8664)
            import_library = built / (library.name + ".lib")
            import_library.write_bytes(b"accepted import library")
            artifacts = windows.load("artifacts")
            windows_tools = Mock(wraps=windows.load("windows"))
            receipt_path = built / "native-build.json"
            abi = "system_permissions_abi_version"
            native_receipt = {
                "outputs": artifacts.hashes((library, import_library), built),
                "target": "x86_64-pc-windows-msvc",
                "compiler": "rustc 1.99.1",
                "abiVersions": {abi: 2},
                "dependencies": {},
                "cargoBuild": {},
                "inspection": {"exports": [abi]},
            }
            receipt_path.write_text(json.dumps(native_receipt), encoding="utf-8")
            windows_tools.verify_artifact.return_value = (
                built,
                {} if change_files == "native" else native_receipt,
            )
            artifact_root = root / "evidence" if use_artifact_root else None
            destination = (artifact_root or (root / "build/windows")) / windows.RID
            transfer = root / "evidence/sdk-windows/win-x64"
            companions = root / "evidence/sdk-nuget-companions"
            arguments = ["--export-native"] if export_native else []
            packages = (
                "NaviApps.SystemPermissions.0.1.0.nupkg",
                "NaviApps.SystemPermissions.Windows.0.1.0.nupkg",
            )
            if not use_artifact_root:
                legacy = destination / "packages"
                legacy.mkdir(parents=True)
                for name in packages:
                    (legacy / name).write_bytes(b"previous package")
            scope = {
                "artifacts": artifacts,
                "windows": windows_tools,
                "vm_environment": Mock(artifacts_dir=Mock(return_value=artifact_root)),
                "c_compiler": Mock(
                    compile_c=Mock(
                        side_effect=lambda *a, output, **k: write_pe(output, fixture_machine)
                    )
                ),
                "dotnet": Mock(),
            }
            acceptance = Mock(host=host, env={}, tools=root / "msvc", dotnet="dotnet.exe")
            acceptance.build.return_value = built

            def stage(_native, _built, candidate):
                return (
                    artifacts.stage_native(library, candidate / library.name),
                    artifacts.stage_native(import_library, candidate / import_library.name),
                    native_receipt,
                )

            def pack(_dotnet, selected_library, _rid, _env, candidate):
                self.assertEqual(selected_library.read_bytes(), library.read_bytes())
                self.assertEqual(acceptance.run.call_args.args[0].parent, selected_library.parent)
                output = candidate / "packages"
                output.mkdir()
                for name in packages:
                    (output / name).write_bytes(b"verified package")
                if change_files == "staged":
                    selected_library.write_bytes(b"changed after acceptance")
                return artifacts.hashes(artifacts.files(output), output)

            acceptance.stage.side_effect = stage
            first = {"distribution/verify_windows.py": "a" * 64}
            second = {"distribution/verify_windows.py": "b" * 64} if change_inputs else first
            with (
                patch.object(windows, "ROOT", root),
                patch.object(windows, "load", side_effect=scope.__getitem__),
                patch.object(windows, "X64Acceptance", return_value=acceptance),
                patch.object(windows, "ffi_product", return_value=Mock(version="0.1.0")),
                patch.object(windows, "support_inputs", side_effect=(first, second)),
                patch.object(windows, "acceptance_source", return_value=("a" * 40, None)),
                patch.object(windows, "pack_and_consume", side_effect=pack) as installed,
                patch("builtins.print"),
            ):
                failures = (
                    (fixture_machine != 0x8664, "target-native x64 PE image"),
                    (change_files == "staged", "Staged Windows files changed"),
                    (change_inputs, "SDK inputs changed"),
                    (change_files == "native", "Windows native build changed"),
                )
                if error := next((message for failed, message in failures if failed), None):
                    with self.assertRaisesRegex(ValueError, error):
                        windows.main(arguments)
                    self.assertFalse(destination.exists())
                    self.assertFalse(transfer.exists())
                    self.assertFalse(companions.exists())
                    if fixture_machine != 0x8664:
                        acceptance.run.assert_not_called()
                        scope["dotnet"].run_managed.assert_not_called()
                        installed.assert_not_called()
                    return
                windows.main(arguments)

            if export_native:
                self.assertFalse(destination.exists())
                self.assertEqual(
                    artifacts.hashes(artifacts.files(transfer), transfer),
                    artifacts.hashes(artifacts.files(built), built),
                )
                evidence = json.loads((companions / windows.RECEIPT).read_bytes())
                adapter = packages[1]
                self.assertEqual(
                    {entry.name for entry in companions.iterdir()}, {adapter, windows.RECEIPT}
                )
                self.assertEqual(
                    evidence["packages"], {adapter: artifacts.file_sha256(companions / adapter)}
                )
                return
            self.assertFalse(transfer.exists())
            self.assertFalse(companions.exists())
            evidence = json.loads((destination / windows.RECEIPT).read_bytes())
            self.assertEqual(
                evidence["executionMode"], "native" if host == "x64" else "x64-emulation"
            )
            self.assertEqual(evidence["abiVersions"], {abi: 2})
            self.assertEqual(evidence["nativeSha256"], artifacts.file_sha256(library))
            self.assertEqual(set(evidence["packages"]), set(packages))
            self.assertEqual(
                {entry.name for entry in destination.iterdir()},
                {*packages, windows.RECEIPT},
            )


if __name__ == "__main__":
    unittest.main()
