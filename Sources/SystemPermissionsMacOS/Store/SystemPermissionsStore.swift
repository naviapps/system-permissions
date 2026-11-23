import Combine
import SystemPermissions

/// Observable macOS projection of a Rust-owned permission state store.
/// Hosts select tracked permissions and decide when requests may prompt.
@MainActor
public final class SystemPermissionsStore: ObservableObject {
  public let trackedTypes: [PermissionType]
  private let permissionChecker: any PermissionChecking
  private let state: PermissionState
  private var results: [PermissionType: PermissionOperationResult<PermissionStatus>] = [:]

  /// Rejects invalid descriptors and conflicting metadata without starting OS operations.
  public init(
    trackedTypes: [PermissionType] = PermissionType.builtIn,
    permissionChecker: any PermissionChecking = PermissionChecker()
  ) throws {
    self.permissionChecker = permissionChecker
    state = try PermissionState(types: trackedTypes)
    let initial = try Self.project(state)
    self.trackedTypes = initial.map(\.0)
    results = Dictionary(uniqueKeysWithValues: initial)
  }

  /// The last stored status for the permission's default scope (read/write for Photos).
  public func status(for type: PermissionType) -> PermissionOperationResult<PermissionStatus>? {
    results[type]
  }

  public func allowsAccess(_ type: PermissionType) -> Bool? {
    guard case .supported(let value) = status(for: type) else { return nil }
    return value.allowsAccess
  }

  /// Batches status publication atomically. Cancellation keeps the previous view state.
  /// Permissions with a pending request for their stored scope are left unchanged by the batch.
  @discardableResult
  public func refreshAll() async throws -> [PermissionType: PermissionOperationResult<
    PermissionStatus
  >] {
    guard !Task.isCancelled else { return results }
    let admissions = try state.admitAllRefreshes()
    return try await withAdmissions(admissions.map(\.token)) {
      let requests = try admissions.map {
        (try PermissionType(descriptor: $0.permission), $0.token)
      }
      return try await withThrowingTaskGroup(
        of: (PermissionType, UInt64, PermissionOperationResult<PermissionStatus>)?.self
      ) { group in
        for (type, token) in requests {
          let added = group.addTaskUnlessCancelled { [permissionChecker] in
            guard !Task.isCancelled else { return nil }
            let result = await permissionChecker.status(for: type)
            guard !Task.isCancelled else { return nil }
            return (type, token, result)
          }
          if !added { break }
        }
        var updates: [(PermissionType, UInt64, PermissionOperationResult<PermissionStatus>)] = []
        for try await update in group { if let update { updates.append(update) } }
        try apply(updates)
        return results
      }
    }
  }

  /// While a request for the stored scope is pending, returns the current value without checking.
  @discardableResult
  public func refresh(_ type: PermissionType) async throws -> PermissionOperationResult<
    PermissionStatus
  >? {
    try await refresh(type, options: type.defaultOptions(on: permissionChecker.platform))
  }

  /// An add-only Photos check returns its own observation without updating read/write status.
  @discardableResult
  public func refresh(_ type: PermissionType, options: PermissionOptions) async throws
    -> PermissionOperationResult<PermissionStatus>?
  {
    try await run(type, options: options, kind: .refresh) {
      await permissionChecker.status(for: type, options: options)
    }
  }

  /// An add-only Photos request returns its own result without updating read/write status.
  /// A cancelled add-only request returns unknown for that scope. Cancellation cannot dismiss
  /// a displayed OS prompt or reverse a granted permission.
  @discardableResult
  public func requestAccess(for type: PermissionType, options: PermissionOptions? = nil)
    async throws
    -> PermissionOperationResult<PermissionStatus>?
  {
    let options = options ?? type.defaultOptions(on: permissionChecker.platform)
    return try await run(type, options: options, kind: .request) {
      await permissionChecker.requestAccess(for: type, options: options)
    }
  }

  private func run(
    _ type: PermissionType, options: PermissionOptions, kind: PermissionState.OperationKind,
    _ check: @MainActor () async -> PermissionOperationResult<PermissionStatus>
  ) async throws -> PermissionOperationResult<PermissionStatus>? {
    let cancelled = Task.isCancelled
    if cancelled, status(for: type) == nil { return nil }
    let admission = try state.admitScoped(type, options: options, kind: kind, cancelled: cancelled)
    switch admission.kind {
    case .untracked:
      return nil
    case .invalidOptions:
      return Task.isCancelled ? status(for: type) : .failed(.invalidOptions)
    case .suppressed:
      return status(for: type)
    case .isolated:
      guard !Task.isCancelled else { return .supported(.unknown) }
      let result = await check()
      return Task.isCancelled ? .supported(.unknown) : result.validatedForState()
    case .stored:
      guard let token = admission.token else {
        throw PermissionContractError(code: "invalidResult", message: "Missing admission token.")
      }
      return try await withAdmissions([token]) {
        guard !Task.isCancelled else { return status(for: type) }
        let result = await check()
        try apply([(type, token, result)])
        return status(for: type)
      }
    }
  }

  private func withAdmissions<Value>(
    _ tokens: [UInt64],
    _ operation: @MainActor () async throws -> Value
  ) async throws -> Value {
    let outcome: Result<Value, any Error>
    do {
      outcome = .success(try await operation())
    } catch {
      outcome = .failure(error)
    }
    var cleanupFailures: [any Error] = []
    for token in tokens {
      do { _ = try state.finish(token) } catch { cleanupFailures.append(error) }
    }
    switch outcome {
    case .success(let value):
      if let failure = cleanupFailures.first {
        throw Self.addCleanupContext(to: failure, failures: Array(cleanupFailures.dropFirst()))
      }
      return value
    case .failure(let failure):
      throw Self.addCleanupContext(to: failure, failures: cleanupFailures)
    }
  }

  private static func addCleanupContext(to failure: any Error, failures: [any Error]) -> any Error {
    guard !failures.isEmpty else { return failure }
    guard let contract = failure as? PermissionContractError else {
      return CleanupContextError(primary: failure, cleanupFailures: failures)
    }
    let details = failures.map { String(describing: $0) }.joined(separator: "; ")
    return PermissionContractError(
      code: contract.code,
      message: (contract.message.map { $0 + " " } ?? "") + "Token cleanup failed: " + details)
  }

  private struct CleanupContextError: Error, CustomStringConvertible {
    let primary: any Error
    let cleanupFailures: [any Error]

    var description: String {
      let details = cleanupFailures.map { String(describing: $0) }.joined(separator: "; ")
      return "\(primary) Token cleanup failed: " + details
    }
  }

  private func apply(
    _ updates: [(PermissionType, UInt64, PermissionOperationResult<PermissionStatus>)]
  ) throws {
    guard !Task.isCancelled, try state.apply(updates.map { ($0.0, $0.1, $0.2.validatedForState()) })
    else { return }
    // A failed projection must not publish a partial dictionary as a permission change.
    let updated = Dictionary(uniqueKeysWithValues: try Self.project(state))
    guard updated != results else { return }
    objectWillChange.send()
    results = updated
  }

  private static func project(_ state: PermissionState) throws
    -> [(PermissionType, PermissionOperationResult<PermissionStatus>)]
  {
    try state.snapshot().values.map {
      (try PermissionType(descriptor: $0.permission), $0.result)
    }
  }
}
