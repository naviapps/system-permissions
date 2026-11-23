import Foundation

/// Describes what the system can do for a permission type.
public struct PermissionCapability: Codable, Hashable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case supportsStatusCheck, supportsRequest, requiresRelaunch
    case systemSettingsURL = "systemSettingsUrl"
  }

  /// Whether a public or reliable status API is available.
  public let supportsStatusCheck: Bool
  /// Whether a public request API is available.
  public let supportsRequest: Bool
  /// System Settings URL for manual changes, when known.
  public let systemSettingsURL: URL?
  /// Exact Settings destination from the permission contract.
  public let systemSettingsURLString: String?
  /// Whether macOS commonly requires app relaunch after a change.
  public let requiresRelaunch: Bool

  /// Creates capability metadata for a permission type.
  public init(
    supportsStatusCheck: Bool,
    supportsRequest: Bool,
    systemSettingsURL: URL?,
    requiresRelaunch: Bool
  ) {
    self.supportsStatusCheck = supportsStatusCheck
    self.supportsRequest = supportsRequest
    self.systemSettingsURL = systemSettingsURL
    self.systemSettingsURLString = systemSettingsURL?.absoluteString
    self.requiresRelaunch = requiresRelaunch
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    supportsStatusCheck = try container.decode(Bool.self, forKey: .supportsStatusCheck)
    supportsRequest = try container.decode(Bool.self, forKey: .supportsRequest)
    // Foundation can percent-encode the URL. Keep the original contract value separately.
    systemSettingsURLString = try container.decodeIfPresent(String.self, forKey: .systemSettingsURL)
    systemSettingsURL = try container.decodeIfPresent(URL.self, forKey: .systemSettingsURL)
    requiresRelaunch = try container.decode(Bool.self, forKey: .requiresRelaunch)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(supportsStatusCheck, forKey: .supportsStatusCheck)
    try container.encode(supportsRequest, forKey: .supportsRequest)
    try container.encodeIfPresent(systemSettingsURLString, forKey: .systemSettingsURL)
    try container.encode(requiresRelaunch, forKey: .requiresRelaunch)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.supportsStatusCheck == rhs.supportsStatusCheck,
      lhs.supportsRequest == rhs.supportsRequest,
      lhs.requiresRelaunch == rhs.requiresRelaunch
    else { return false }
    switch (lhs.systemSettingsURLString, rhs.systemSettingsURLString) {
    case (nil, nil): return true
    case (let lhs?, let rhs?): return lhs.utf8.elementsEqual(rhs.utf8)
    default: return false
    }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(supportsStatusCheck)
    hasher.combine(supportsRequest)
    hasher.combine(requiresRelaunch)
    hasher.combine(systemSettingsURLString != nil)
    if let address = systemSettingsURLString {
      for byte in address.utf8 { hasher.combine(byte) }
    }
  }
}
