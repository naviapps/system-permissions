// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "SystemPermissionsConsumer",
  platforms: [.macOS(.v26)],
  dependencies: [.package(name: "system-permissions", path: "../sdk")],
  targets: [
    .executableTarget(
      name: "SystemPermissionsConsumer",
      dependencies: [
        .product(name: "SystemPermissions", package: "system-permissions"),
        .product(name: "SystemPermissionsMacOS", package: "system-permissions"),
      ])
  ]
)
