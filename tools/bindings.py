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

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent
DOTNET_PROJECTS = ("NaviApps.SystemPermissions", "NaviApps.SystemPermissions.Windows")


def run(*args, env):
    subprocess.run([str(a) for a in args], cwd=ROOT, env=env, check=True)


def pack_and_consume(dotnet, library, rid, env, output, *, tooling):
    runtime = ROOT / "bindings/dotnet/runtimes" / rid / "native"
    native_name = "libsystem_permissions.dylib" if rid.startswith("osx-") else library.name
    tooling.stage_native(library, runtime / native_name)
    packages = output / "packages"
    for name in DOTNET_PROJECTS:
        tooling.pack_project(
            dotnet,
            ROOT / "bindings/dotnet/src" / name / (name + ".csproj"),
            output=packages,
            cwd=ROOT,
            env=env,
            properties={
                "SystemPermissionsRuntimeIdentifier": rid,
                "SystemPermissionsNativeFileName": native_name,
            },
        )
    built = [packages / (name + ".0.1.0.nupkg") for name in DOTNET_PROJECTS]
    notices = {
        "licenses/" + path.relative_to(ROOT / "ThirdParty").as_posix(): path
        for path in (ROOT / "ThirdParty").rglob("*")
        if path.is_file() and path.name not in (".DS_Store", "registry-notices.json")
    }
    hashes = {
        package.name: tooling.audit_package(
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
    tooling.run_isolated_consumer(
        dotnet,
        packages=built,
        references={"NaviApps.SystemPermissions.Windows": "0.1.0"},
        source=r"""using System;
using NaviApps.SystemPermissions;
using NaviApps.SystemPermissions.Windows;
if(PermissionContract.BuiltIns.Count != 23) throw new Exception("Native metadata not loaded.");
if(!PermissionOperationResult.Supported(PermissionStatus.Limited).AllowsAccess) throw new Exception("Access semantics.");
if (PermissionContract.DecodeDescriptorJson("{\"id\":\"camera\"}"u8) != PermissionDescriptor.Camera)
 throw new Exception("Portable descriptor decoding lost its permission identity.");
try {
 _ = PermissionContract.DecodeDescriptorJson("{\"id\":\"camera\",\"id\":\"microphone\"}"u8);
 throw new Exception("The portable descriptor accepted a duplicate id.");
} catch (PermissionContractException error) when (error.Error == "invalidJson") { }
if(PermissionContract.ValidateUsageDescriptionKey("HostUsageKey") != "HostUsageKey")
 throw new Exception("The packaged native contract did not validate a host usage description key.");
if(PermissionContract.ValidateUsageDescriptionKey("Host\uFFFD") != "Host\uFFFD")
 throw new Exception("A valid host key changed spelling.");
try {
 _ = PermissionContract.ValidateUsageDescriptionKey("Host\uD800");
 throw new Exception("The binding accepted an unpaired surrogate in a host key.");
} catch (PermissionContractException error) when (error.Error == "invalidJson") { }
var custom = new PermissionDescriptor("com.example.privacy", Custom: new CustomPermission(new(true, false, "example:é", false), ["HostUsageKey"]));
var accepted = PermissionContract.Validate(custom);
var roundTrip = PermissionContract.Validate(custom);
var changed = accepted with { Custom = accepted.Custom! with { UsageDescriptionKeys = ["OtherUsageKey"] } };
if (accepted != roundTrip || accepted.GetHashCode() != roundTrip.GetHashCode() ||
    !accepted.HasSameIdentity(changed) || accepted == changed)
 throw new Exception("The packaged binding did not distinguish descriptor value from permission identity.");
using var store = new PermissionStore();
var capability = PermissionContract.Metadata(custom, PermissionPlatform.Windows).Capability;
if (capability.SystemSettingsURL != "example:é")
 throw new Exception("The capability did not preserve the original Settings destination.");
var escaped = custom with {
 Custom = custom.Custom! with { Capability = capability with { SystemSettingsURL = "example:%C3%A9" } }
};
try {
 _ = store.Track([custom, escaped]);
 throw new Exception("Tracking accepted conflicting Settings destinations.");
} catch (PermissionContractException error) when (error.Error == "inconsistentMetadata") { }
store.Track(new[] { PermissionDescriptor.Camera });
var token = store.Begin(PermissionDescriptor.Camera) ?? throw new Exception("Native store admission.");
store.Apply(new[] {new PermissionUpdate(PermissionDescriptor.Camera, token, PermissionOperationResult.Supported(PermissionStatus.Denied))});
if(store.Get(PermissionDescriptor.Camera)?.Value != PermissionStatus.Denied) throw new Exception("Native store.");
var checker = new StatusOnly(PermissionOperationResult.Supported(PermissionStatus.Granted));
var refreshed = await store.RefreshAllAsync(checker);
if (refreshed.Values[0].Result?.Value != PermissionStatus.Granted) throw new Exception("Atomic status refresh.");
using (var cancelObservation = new System.Threading.CancellationTokenSource())
await using (var observation = PermissionStatusObserver.Updates([PermissionDescriptor.Camera], checker,
    pollingInterval: TimeSpan.FromDays(60), cancellationToken: cancelObservation.Token).GetAsyncEnumerator()) {
 if (!await observation.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)) ||
     observation.Current.Result.Value != PermissionStatus.Granted)
  throw new Exception("Status observation.");
 var nextSample = observation.MoveNextAsync().AsTask();
 try {
  _ = await nextSample.WaitAsync(TimeSpan.FromMilliseconds(250));
  throw new Exception("A long observation interval ended early.");
 } catch (TimeoutException) {
  cancelObservation.Cancel();
 }
 try {
  _ = await nextSample.WaitAsync(TimeSpan.FromSeconds(5));
  throw new Exception("The long observation interval did not cancel.");
 } catch (OperationCanceledException) when (cancelObservation.IsCancellationRequested) { }
}
var malformed = new StatusOnly(PermissionOperationResult.Unsupported(new(false, false, "relative/path", false)));
await using (var observation = PermissionStatusObserver.Updates([PermissionDescriptor.Camera], malformed).GetAsyncEnumerator()) {
 try {
  _ = await observation.MoveNextAsync();
  throw new Exception("The observer accepted a malformed provider result.");
 } catch (PermissionContractException error) when (error.Error == "invalidResult") { }
}
var environment = new WindowsPermissionEnvironment(new NeverDispatch());
if(environment.Platform != PermissionPlatform.Windows) throw new Exception("Windows package missing.");
var settings = await new PermissionChecker(environment).OpenSettingsAsync(PermissionDescriptor.Accessibility);
if (settings.Kind != "unsupported") throw new Exception("The packaged checker lost Settings admission.");
Console.WriteLine("Clean NuGet consumer loaded packaged native code and both managed packages.");
sealed class StatusOnly(PermissionOperationResult result) : IPermissionStatusChecking {
 public System.Threading.Tasks.Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options, System.Threading.CancellationToken token) =>
  System.Threading.Tasks.Task.FromResult(result);
}
sealed class NeverDispatch : IWindowsPermissionDispatcher {
 public System.Threading.Tasks.Task<T> InvokeAsync<T>(Func<T> action, System.Threading.CancellationToken token) => throw new Exception("No OS requests in consumer fixture.");
}""",
        work_parent=output,
        env=env,
        runtime=rid,
        properties={"Nullable": "enable", "TreatWarningsAsErrors": "true"},
        clear_environment=("SYSTEM_PERMISSIONS_NATIVE_LIBRARY",),
        exclude_paths=(ROOT / "target", runtime, library.parent),
    )
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, help="Explicit already source-built test library")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Use tools/windows.py to build x64 on an owned Windows worker")
    tooling = load("bindings")
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
        raise SystemExit("Build the tracked framework with tools/native.py first")
    output = ROOT / "build/bindings"
    output.mkdir(parents=True, exist_ok=True)
    tooling.compile_c(
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
    env["SYSTEM_PERMISSIONS_NATIVE_LIBRARY"] = str(library)
    tooling.run_managed(
        dotnet,
        ROOT / "bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj",
        cwd=ROOT,
        env=env,
        verify_style=True,
    )
    packages = pack_and_consume(dotnet, library, rid, env, output, tooling=tooling)
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
