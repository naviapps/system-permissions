import Foundation

/// Dependency container for permission status, request, and System Settings side effects.
///
/// Pass custom closures when tests or host apps need a controlled permission backend.
public struct PermissionEnvironment: Sendable {
  /// Platform whose permission metadata describes the injected effects.
  public let platform: PermissionPlatform

  private let statusHandler:
    @Sendable (PermissionType, PermissionOptions) async -> PermissionOperationResult<
      PermissionStatus
    >
  private let requestAccessHandler:
    @Sendable (PermissionType, PermissionOptions) async -> PermissionOperationResult<
      PermissionStatus
    >
  private let openURLHandler: @Sendable (URL) -> Bool

  /// Creates a macOS environment from side-effect closures.
  public init(
    status:
      @escaping @Sendable (PermissionType, PermissionOptions) async ->
      PermissionOperationResult<PermissionStatus>,
    requestAccess:
      @escaping @Sendable (PermissionType, PermissionOptions) async ->
      PermissionOperationResult<PermissionStatus>,
    openURL: @escaping @Sendable (URL) -> Bool
  ) {
    self.init(platform: .macOS, status: status, requestAccess: requestAccess, openURL: openURL)
  }

  /// Creates an environment whose side effects use the selected platform's contract.
  public init(
    platform: PermissionPlatform,
    status:
      @escaping @Sendable (PermissionType, PermissionOptions) async ->
      PermissionOperationResult<PermissionStatus>,
    requestAccess:
      @escaping @Sendable (PermissionType, PermissionOptions) async ->
      PermissionOperationResult<PermissionStatus>,
    openURL: @escaping @Sendable (URL) -> Bool
  ) {
    self.platform = platform
    self.statusHandler = status
    self.requestAccessHandler = requestAccess
    self.openURLHandler = openURL
  }

  func status(
    for type: PermissionType,
    options: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    await statusHandler(type, options)
  }

  func requestAccess(
    for type: PermissionType,
    options: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    await requestAccessHandler(type, options)
  }

  func openURL(_ url: URL) -> Bool {
    openURLHandler(url)
  }
}
