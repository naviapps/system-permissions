import Foundation

/// Operating system whose permission contract is being queried.
public enum PermissionPlatform: String, Codable, Sendable {
  case macOS = "macos"
  case windows
}

extension PermissionType {
  /// Platform-specific capabilities and defaults, validated by the shared Rust core.
  public struct Metadata: Decodable, Sendable {
    public let defaultOptions: PermissionOptions
    public let usageDescriptionKeys: [UsageDescriptionKey]
    public let capability: PermissionCapability
  }

  public func metadata(on platform: PermissionPlatform, options: PermissionOptions = .none) throws
    -> Metadata
  {
    try NativePermissions.call([
      "op": "metadata", "platform": platform.rawValue,
      "permission": NativePermissions.object(descriptor),
      "options": NativePermissions.object(options),
    ])
  }

  /// Default options for the macOS adapter.
  public var defaultOptions: PermissionOptions {
    defaultOptions(on: .macOS)
  }
  /// macOS capability metadata. Invalid descriptors do not advertise available operations.
  public var capability: PermissionCapability {
    capability(on: .macOS)
  }

  package func defaultOptions(on platform: PermissionPlatform) -> PermissionOptions {
    (try? metadata(on: platform))?.defaultOptions ?? .none
  }

  func capability(on platform: PermissionPlatform) -> PermissionCapability {
    (try? metadata(on: platform))?.capability
      ?? PermissionCapability(
        supportsStatusCheck: false, supportsRequest: false, systemSettingsURL: nil,
        requiresRelaunch: false)
  }
}
