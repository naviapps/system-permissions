import Foundation

extension PermissionType {
  /// Usage description keys required for this permission type and permission options.
  public func usageDescriptionKeys(for options: PermissionOptions) -> [UsageDescriptionKey] {
    (try? metadata(on: .macOS, options: options))?.usageDescriptionKeys ?? []
  }

  /// Returns missing usage description keys in the provided bundle.
  public func missingUsageDescriptions(
    in bundle: Bundle = .main,
    options: PermissionOptions = .none
  ) -> [UsageDescriptionKey] {
    let info = bundle.infoDictionary ?? [:]
    return usageDescriptionKeys(for: options).filter { key in
      guard let value = info[key.rawValue] as? String else { return true }
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}
