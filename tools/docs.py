#!/usr/bin/env python3
"""Build the SDK-owned Swift API catalogs through the pinned DocC driver."""

from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent


def main():
    load("docs").check_catalogs(
        ROOT,
        [
            ROOT / "Sources" / name / (name + ".docc")
            for name in ("SystemPermissions", "SystemPermissionsMacOS")
        ],
        output=ROOT / "build/docs",
        bundle_identifier_prefix="com.naviapps.",
        retain_archives=True,
    )


if __name__ == "__main__":
    main()
