#!/usr/bin/env python3
"""Run the independent Git Rust and installed macOS C fixtures."""

from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parents[1]


def main(argv=None):
    load("installed_consumers").check_installed(
        root=ROOT,
        git_url="https://github.com/naviapps/system-permissions.git",
        rust_packages=("system-permissions",),
        framework=(
            "Artifacts/CSystemPermissions.xcframework/macos-arm64_x86_64/"
            "CSystemPermissions.framework"
        ),
        header="system_permissions.h",
        argv=argv,
    )


if __name__ == "__main__":
    main()
