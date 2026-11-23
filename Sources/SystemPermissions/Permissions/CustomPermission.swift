/// Host-defined permission descriptor with validated identifier and capability metadata.
public struct CustomPermission: Sendable, Hashable {
  /// Reason a host-defined custom permission identifier is invalid.
  public enum IdentifierValidationError: String, Error, Equatable, Hashable, Sendable {
    /// The identifier is empty.
    case empty
    /// The identifier matches a built-in ``PermissionType`` identifier.
    case reserved
    /// The identifier does not contain at least two `.`-separated segments.
    case missingNamespace
    /// One or more namespace segments are empty.
    case emptySegment
    /// A segment starts or ends with a character other than a lowercase ASCII letter or digit.
    case invalidSegmentBoundary
    /// The identifier contains a character outside lowercase ASCII letters, digits, `_`, `-`, and `.`.
    case invalidCharacter
  }

  /// Host-owned namespaced ASCII identifier used by ``PermissionType/custom(_:)``.
  public let identifier: String
  /// Capability metadata supplied by the host app.
  public let capability: PermissionCapability
  /// Info.plist usage description keys required by the host-defined permission.
  ///
  /// Duplicate keys are removed during construction while preserving their first occurrence.
  public let usageDescriptionKeys: [UsageDescriptionKey]

  /// Creates a custom permission descriptor.
  ///
  /// Duplicate `usageDescriptionKeys` are removed while preserving their first occurrence.
  /// Invalid identifiers throw ``IdentifierValidationError``; oversized key lists throw
  /// ``PermissionContractError``.
  public init(
    identifier: String,
    capability: PermissionCapability,
    usageDescriptionKeys: [UsageDescriptionKey] = []
  ) throws {
    if let error = Self.validationError(for: identifier) {
      throw error
    }
    self.init(
      validatedIdentifier: identifier, capability: capability,
      usageDescriptionKeys: try UsageDescriptionKey.validated(usageDescriptionKeys.map(\.rawValue)))
  }

  init(
    validatedIdentifier: String, capability: PermissionCapability,
    usageDescriptionKeys: [UsageDescriptionKey]
  ) {
    identifier = validatedIdentifier
    self.capability = capability
    self.usageDescriptionKeys = usageDescriptionKeys
  }

  /// Returns the first validation error for a custom identifier, or `nil` when valid.
  ///
  /// Validation is intentionally strict and does not trim or normalize input. Callers that accept
  /// user-entered identifiers should trim and canonicalize before asking SystemPermissions to validate
  /// them. Construction uses this same validation.
  public static func validationError(
    for identifier: String
  ) -> IdentifierValidationError? {
    struct Validation: Decodable { let error: String? }
    guard
      let result = try? NativePermissions.call(
        ["op": "validateIdentifier", "identifier": identifier], as: Validation.self)
    else { return .invalidCharacter }
    return result.error.flatMap(IdentifierValidationError.init(rawValue:))
  }

  /// Compares permission identity by identifier.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identifier == rhs.identifier
  }

  /// Hashes permission identity by identifier.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(identifier)
  }
}
