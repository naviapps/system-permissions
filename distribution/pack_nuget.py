"""Pack the SystemPermissions core NuGet from verified native artifacts."""

import argparse
from pathlib import Path

from sdk_tooling.c_headers import prepare_generated
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.nuget import pack_native, retained_notice_files
from sdk_tooling.windows_delivery import RID
from sdk_tooling.xcframework import xcframework

ROOT = Path(__file__).resolve().parents[1]
DOTNET = ROOT / "bindings/dotnet"
PACKAGE = "NaviApps.SystemPermissions"


def notice_files():
    return retained_notice_files(ROOT / "ThirdParty", "licenses")


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--runtime", action="append", required=True, choices=("osx-arm64", "osx-x64", RID)
    )
    parser.add_argument("--result", type=Path, help="Write the package filename to a new file")
    args = parser.parse_args()
    prepare_generated(ROOT)
    native = ffi_product(ROOT) if set(args.runtime) == {RID} else xcframework(ROOT)
    package = pack_native(
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
