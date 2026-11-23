"""Pack the SystemPermissions core NuGet from verified native artifacts."""

import argparse
from pathlib import Path

from sdk_tooling.adapters import load
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.windows_delivery import RID
from sdk_tooling.xcframework import xcframework

ROOT = Path(__file__).resolve().parents[1]
DOTNET = ROOT / "bindings/dotnet"
PACKAGE = "NaviApps.SystemPermissions"
NOTICES = ROOT / "ThirdParty"


def notice_files():
    return {
        "licenses/" + path.relative_to(NOTICES).as_posix(): path
        for path in load("artifacts").files(NOTICES)
        if path.name not in (".DS_Store", "registry-notices.json")
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--runtime", action="append", required=True, choices=("osx-arm64", "osx-x64", RID)
    )
    parser.add_argument("--result", type=Path, help="Write the package filename to a new file")
    args = parser.parse_args()
    native = ffi_product(ROOT) if set(args.runtime) == {RID} else xcframework(ROOT)
    package = load("nuget").pack_native(
        native,
        project=DOTNET / "src" / PACKAGE / (PACKAGE + ".csproj"),
        nuget_config=DOTNET / "NuGet.Config",
        package_files={
            "LICENSE": ROOT / "LICENSE",
            "README.md": DOTNET / "README.md",
            **notice_files(),
        },
        input_files=[Path(__file__), ROOT / "native.toml", ROOT / "mise.toml"],
        runtimes=args.runtime,
    )
    if args.result is not None:
        with args.result.open("x", encoding="utf-8") as output:
            output.write(package.name)


if __name__ == "__main__":
    main()
