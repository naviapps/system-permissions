#!/usr/bin/env python3
"""Run injected Swift permission contracts using only installable SDK inputs."""

from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent


def main(argv=None):
    load("consumers").check_swift(
        root=ROOT,
        inputs=("Package.swift", "Sources", "Tests", "Artifacts", "ThirdParty"),
        fixture=ROOT / "fixtures/swift-consumer",
        executables=("SystemPermissionsConsumer",),
        argv=argv,
    )


if __name__ == "__main__":
    main()
