/// A failure of the shared permission contract, distinct from an observed OS permission result.
public struct PermissionContractError: Error, Decodable, Sendable {
  /// Stable Rust error code, such as `inputTooLarge`.
  public let code: String
  public let message: String?

  package init(code: String, message: String?) {
    self.code = code
    self.message = message
  }
  private enum CodingKeys: String, CodingKey {
    case code = "error"
    case message
  }
}
