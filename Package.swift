// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "SystemPermissions",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SystemPermissions", targets: ["SystemPermissions"]),
    .library(name: "SystemPermissionsMacOS", targets: ["SystemPermissionsMacOS"]),
  ],
  targets: [
    .binaryTarget(name: "CSystemPermissions", path: "Artifacts/CSystemPermissions.xcframework"),
    .target(name: "SystemPermissions", dependencies: ["CSystemPermissions"]),
    .target(name: "SystemPermissionsMacOS", dependencies: ["SystemPermissions"]),
    .testTarget(
      name: "SystemPermissionsTests", dependencies: ["SystemPermissions"],
      resources: [.copy("Fixtures/notification-options.json")]),
    .testTarget(
      name: "SystemPermissionsMacOSTests",
      dependencies: ["SystemPermissionsMacOS", "SystemPermissions"]),
  ]
)
