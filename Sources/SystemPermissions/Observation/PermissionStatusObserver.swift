import Foundation

/// Polls permission status and emits samples or changes using only status-checking capability.
/// Rust validates the full descriptor list before polling. Invalid lists finish without
/// invoking the options or status providers.
/// Rust validates each result and compares it with the previous poll for that permission.
/// A rejected result stops polling. The streams deliver any valid events already
/// buffered before finishing. `throwingUpdates` and `throwingChanges` surface the error.
public enum PermissionStatusObserver {
  /// A single status-check result, including initial and unchanged samples.
  public struct Update: Sendable, Equatable, Hashable {
    /// Permission type that was checked.
    public let type: PermissionType
    /// Result returned by the status check.
    public let result: PermissionOperationResult<PermissionStatus>

    /// Creates a status sample.
    public init(type: PermissionType, result: PermissionOperationResult<PermissionStatus>) {
      self.type = type
      self.result = result
    }
  }

  /// A single change event emitted by the observer.
  public struct Change: Sendable, Equatable, Hashable {
    /// Permission type that changed.
    public let type: PermissionType
    /// Previously observed status-check result.
    public let previousResult: PermissionOperationResult<PermissionStatus>
    /// Newly observed status-check result.
    public let currentResult: PermissionOperationResult<PermissionStatus>

    /// Creates a change event.
    public init(
      type: PermissionType,
      previousResult: PermissionOperationResult<PermissionStatus>,
      currentResult: PermissionOperationResult<PermissionStatus>
    ) {
      self.type = type
      self.previousResult = previousResult
      self.currentResult = currentResult
    }
  }

  /// Builds a stream that samples status immediately and on every poll.
  ///
  /// Unchanged, unsupported and failed results are emitted. The buffer retains at most
  /// the number of unique requested types. A slow consumer can miss intermediate samples;
  /// stable results are emitted again on the next poll.
  /// When `options` is omitted, each type uses the default for the checker's platform.
  /// Polling intervals below 250 milliseconds are clamped to 250 milliseconds.
  /// Consumer cancellation stops subsequent checks and discards a pending check's result.
  public static func updates(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2)
  ) -> AsyncStream<Update> {
    updates(for: types, using: checker, pollingInterval: pollingInterval) {
      $0.defaultOptions(on: checker.platform)
    }
  }

  /// Builds a sample stream using the supplied options for each type.
  public static func updates(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2),
    options: @Sendable @escaping (PermissionType) -> PermissionOptions
  ) -> AsyncStream<Update> {
    observe(
      for: types, using: checker, pollingInterval: pollingInterval, options: options,
      event: makeUpdate)
  }

  /// Builds a sample stream that throws `PermissionContractError` when Rust rejects
  /// a descriptor or provider result. Buffered valid updates are delivered before an error.
  ///
  /// Sampling, buffering, default options and cancellation follow `updates`.
  public static func throwingUpdates(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2),
    options: (@Sendable (PermissionType) -> PermissionOptions)? = nil
  ) -> AsyncThrowingStream<Update, any Error> {
    observeThrowing(
      for: types, using: checker, pollingInterval: pollingInterval,
      options: options ?? { $0.defaultOptions(on: checker.platform) }, event: makeUpdate)
  }

  /// Builds a stream of differences between consecutive polls, skipping initial samples.
  ///
  /// The buffer keeps only the newest events, up to the number of unique requested types.
  /// A slow consumer can miss changes, and `previousResult` describes the preceding poll,
  /// not necessarily the last delivered event. Use `updates` to converge on current status.
  ///
  /// When `options` is omitted, each type uses the default for the checker's platform.
  /// Polling intervals below 250 milliseconds are clamped to 250 milliseconds.
  /// Consumer cancellation stops subsequent checks. A pending provider check can finish
  /// if it does not cooperate with cancellation; its result is then discarded.
  public static func changes(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2)
  ) -> AsyncStream<Change> {
    changes(for: types, using: checker, pollingInterval: pollingInterval) {
      $0.defaultOptions(on: checker.platform)
    }
  }

  /// Builds a change stream using the supplied options for each type.
  public static func changes(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2),
    options: @Sendable @escaping (PermissionType) -> PermissionOptions
  ) -> AsyncStream<Change> {
    observe(
      for: types, using: checker, pollingInterval: pollingInterval, options: options,
      event: makeChange)
  }

  /// Builds a change stream that throws `PermissionContractError` when Rust rejects
  /// a descriptor or provider result. Buffered valid changes are delivered before an error.
  ///
  /// Transition filtering, buffering, default options and cancellation follow `changes`.
  public static func throwingChanges(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration = .seconds(2),
    options: (@Sendable (PermissionType) -> PermissionOptions)? = nil
  ) -> AsyncThrowingStream<Change, any Error> {
    observeThrowing(
      for: types, using: checker, pollingInterval: pollingInterval,
      options: options ?? { $0.defaultOptions(on: checker.platform) }, event: makeChange)
  }

  private typealias EventProvider<Event> =
    @Sendable (
      PermissionType, PermissionOperationResult<PermissionStatus>?,
      PermissionOperationResult<PermissionStatus>
    ) -> Event?

  private static let makeUpdate: EventProvider<Update> = { type, _, result in
    Update(type: type, result: result)
  }

  private static let makeChange: EventProvider<Change> = { type, previous, result in
    guard let previous else { return nil }
    return Change(type: type, previousResult: previous, currentResult: result)
  }

  private static func observe<Event: Sendable>(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration,
    options: @Sendable @escaping (PermissionType) -> PermissionOptions,
    event: @escaping EventProvider<Event>
  ) -> AsyncStream<Event> {
    guard let observation = try? PermissionStatusObservation.prepare(types) else {
      return AsyncStream { continuation in
        continuation.finish()
      }
    }

    let (stream, continuation) = AsyncStream<Event>.makeStream(
      bufferingPolicy: .bufferingNewest(observation.types.count))
    let task = Task {
      defer { continuation.finish() }
      try? await poll(
        observation, using: checker, pollingInterval: pollingInterval,
        options: options, event: event
      ) { continuation.yield($0) }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private static func observeThrowing<Event: Sendable>(
    for types: [PermissionType],
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration,
    options: @Sendable @escaping (PermissionType) -> PermissionOptions,
    event: @escaping EventProvider<Event>
  ) -> AsyncThrowingStream<Event, any Error> {
    let observation: PermissionStatusObservation.Prepared?
    do {
      observation = try PermissionStatusObservation.prepare(types)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    guard let observation else {
      return AsyncThrowingStream { $0.finish() }
    }

    let (stream, continuation) = AsyncThrowingStream<Event, any Error>.makeStream(
      bufferingPolicy: .bufferingNewest(observation.types.count))
    let task = Task {
      do {
        try await poll(
          observation, using: checker, pollingInterval: pollingInterval,
          options: options, event: event
        ) { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private static func poll<Event: Sendable>(
    _ observation: PermissionStatusObservation.Prepared,
    using checker: any PermissionStatusChecking,
    pollingInterval: Duration,
    options: @Sendable (PermissionType) -> PermissionOptions,
    event: EventProvider<Event>,
    emit: @Sendable (Event) -> Void
  ) async throws {
    let interval = PermissionStatusObservation.clampedInterval(pollingInterval)

    while !Task.isCancelled {
      for type in observation.types {
        guard !Task.isCancelled else { return }
        let selectedOptions = options(type)
        guard !Task.isCancelled else { return }
        let result = await checker.status(for: type, options: selectedOptions)
        guard !Task.isCancelled else { return }
        let sample = try observation.state.recordObservation(type, result: result)
        if let value = event(type, sample.previousResult, sample.result) {
          emit(value)
        }
      }
      try? await Task.sleep(for: interval)
    }
  }
}

private enum PermissionStatusObservation {
  typealias Prepared = (state: PermissionState, types: [PermissionType])

  static func prepare(_ types: [PermissionType]) throws -> Prepared? {
    guard !types.isEmpty, !Task.isCancelled else { return nil }
    let state = try PermissionState(types: types)
    let tracked = try state.snapshot().values.map { try PermissionType(descriptor: $0.permission) }
    return (state, tracked)
  }

  static func clampedInterval(_ interval: Duration) -> Duration {
    let minimum: Duration = .milliseconds(250)
    return interval < minimum ? minimum : interval
  }
}
