import AVFoundation
import AppKit
import ApplicationServices
import Contacts
import CoreServices
import EventKit
import Foundation
import Photos
import Speech
import SystemPermissions
import UserNotifications

extension PermissionEnvironment {
  /// Live implementation backed by system frameworks.
  static let live = PermissionEnvironment(
    status: { type, options in
      switch type {
      case .accessibility:
        return .supported(AXIsProcessTrusted() ? .granted : .denied)
      case .automation(let target):
        return automationStatus(targetApplication: target, prompt: false)
      case .inputMonitoring:
        return .supported(CGPreflightListenEventAccess() ? .granted : .denied)
      case .screenRecording:
        return .supported(CGPreflightScreenCaptureAccess() ? .granted : .denied)
      case .camera:
        return .supported(mapAVStatus(AVCaptureDevice.authorizationStatus(for: .video)))
      case .microphone:
        return .supported(mapAVStatus(AVCaptureDevice.authorizationStatus(for: .audio)))
      case .contacts:
        return .supported(mapCNStatus(CNContactStore.authorizationStatus(for: .contacts)))
      case .calendars:
        return .supported(mapEKStatus(EKEventStore.authorizationStatus(for: .event)))
      case .reminders:
        return .supported(mapEKStatus(EKEventStore.authorizationStatus(for: .reminder)))
      case .photos:
        let accessLevel = resolvedPhotoAccessLevel(options)
        return .supported(
          mapPHStatus(PHPhotoLibrary.authorizationStatus(for: accessLevel.systemValue)))
      case .speechRecognition:
        return .supported(mapSpeechStatus(SFSpeechRecognizer.authorizationStatus()))
      case .notifications:
        guard canUseUserNotificationCenter() else { return .failed(.apiUnavailable) }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return .supported(mapNotificationStatus(settings.authorizationStatus))
      case .location,
        .bluetooth,
        .localNetwork,
        .mediaLibrary,
        .systemAudioCapture,
        .desktopFolder,
        .documentsFolder,
        .downloadsFolder,
        .networkVolumes,
        .removableVolumes,
        .fileProviderDomain,
        .fullDiskAccess,
        .custom:
        return .unsupported(type.capability)
      }
    },
    requestAccess: { type, options in
      switch type {
      case .accessibility:
        let promptOptions =
          [accessibilityTrustedCheckPromptOptionKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(promptOptions)
        return .supported(trusted ? .granted : .denied)
      case .automation(let target):
        return automationStatus(targetApplication: target, prompt: true)
      case .inputMonitoring:
        return .supported(CGRequestListenEventAccess() ? .granted : .denied)
      case .screenRecording:
        let granted = CGRequestScreenCaptureAccess()
        return .supported(granted ? .granted : .denied)
      case .camera:
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return .supported(granted ? .granted : .denied)
      case .microphone:
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return .supported(granted ? .granted : .denied)
      case .contacts:
        do {
          let store = CNContactStore()
          let granted = try await store.requestAccess(for: .contacts)
          return .supported(granted ? .granted : .denied)
        } catch {
          return .failed(.apiUnavailable)
        }
      case .calendars:
        do {
          let store = EKEventStore()
          let granted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToEvents { granted, error in
              if let error {
                continuation.resume(throwing: error)
                return
              }
              continuation.resume(returning: granted)
            }
          }
          return .supported(granted ? .granted : .denied)
        } catch {
          return .failed(.apiUnavailable)
        }
      case .reminders:
        do {
          let store = EKEventStore()
          let granted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToReminders { granted, error in
              if let error {
                continuation.resume(throwing: error)
                return
              }
              continuation.resume(returning: granted)
            }
          }
          return .supported(granted ? .granted : .denied)
        } catch {
          return .failed(.apiUnavailable)
        }
      case .photos:
        let accessLevel = resolvedPhotoAccessLevel(options)
        let status = await PHPhotoLibrary.requestAuthorization(for: accessLevel.systemValue)
        return .supported(mapPHStatus(status))
      case .speechRecognition:
        let status = await withCheckedContinuation { continuation in
          SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
          }
        }
        return .supported(mapSpeechStatus(status))
      case .notifications:
        guard canUseUserNotificationCenter() else { return .failed(.apiUnavailable) }
        return await requestNotificationAccess(
          options: resolvedNotificationOptions(options),
          status: {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
          },
          request: {
            try await UNUserNotificationCenter.current().requestAuthorization(options: $0)
          })
      case .location,
        .bluetooth,
        .localNetwork,
        .mediaLibrary,
        .systemAudioCapture,
        .desktopFolder,
        .documentsFolder,
        .downloadsFolder,
        .networkVolumes,
        .removableVolumes,
        .fileProviderDomain,
        .fullDiskAccess,
        .custom:
        return .unsupported(type.capability)
      }
    },
    openURL: { url in
      NSWorkspace.shared.open(url)
    }
  )
}

private let accessibilityTrustedCheckPromptOptionKey = "AXTrustedCheckOptionPrompt"

private func mapAVStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized:
    return .granted
  case .denied:
    return .denied
  case .restricted:
    return .restricted
  case .notDetermined:
    return .notDetermined
  @unknown default:
    return .unknown
  }
}

private func mapCNStatus(_ status: CNAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized:
    return .granted
  case .denied:
    return .denied
  case .restricted:
    return .restricted
  case .notDetermined:
    return .notDetermined
  @unknown default:
    return .unknown
  }
}

private func mapEKStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized, .fullAccess:
    .granted
  case .writeOnly:
    .limited
  case .denied:
    .denied
  case .restricted:
    .restricted
  case .notDetermined:
    .notDetermined
  @unknown default:
    .unknown
  }
}

private func mapPHStatus(_ status: PHAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized:
    .granted
  case .limited:
    .limited
  case .denied:
    .denied
  case .restricted:
    .restricted
  case .notDetermined:
    .notDetermined
  @unknown default:
    .unknown
  }
}

private func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized:
    .granted
  case .denied:
    .denied
  case .restricted:
    .restricted
  case .notDetermined:
    .notDetermined
  @unknown default:
    .unknown
  }
}

private func mapNotificationStatus(_ status: UNAuthorizationStatus) -> PermissionStatus {
  switch status {
  case .authorized: .granted
  case .provisional: .provisional
  case .ephemeral: .ephemeral
  case .denied: .denied
  case .notDetermined: .notDetermined
  @unknown default: .unknown
  }
}

func requestNotificationAccess(
  options: NotificationRequestOptions,
  status: @Sendable () async -> UNAuthorizationStatus,
  request: @Sendable (UNAuthorizationOptions) async throws -> Bool
) async -> PermissionOperationResult<PermissionStatus> {
  let current = mapNotificationStatus(await status())
  guard current != .unknown else { return .failed(.apiUnavailable) }
  guard current == .notDetermined else { return .supported(current) }
  do {
    _ = try await request(options.systemValue)
    return .supported(mapNotificationStatus(await status()))
  } catch {
    return .failed(.apiUnavailable)
  }
}

private func resolvedPhotoAccessLevel(_ options: PermissionOptions) -> PhotoAccessLevel {
  if case .photos(let level) = options {
    return level
  }
  return .default
}

private func resolvedNotificationOptions(_ options: PermissionOptions) -> NotificationRequestOptions
{
  if case .notifications(let value) = options {
    return value
  }
  return .default
}

private func canUseUserNotificationCenter(
  bundle: Bundle = .main
) -> Bool {
  guard let bundleIdentifier = bundle.bundleIdentifier else { return false }
  return !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && bundle.bundleURL.pathExtension == "app"
}

extension PhotoAccessLevel {
  fileprivate var systemValue: PHAccessLevel {
    switch self {
    case .readWrite:
      .readWrite
    case .addOnly:
      .addOnly
    }
  }
}

extension NotificationRequestOptions {
  fileprivate var systemValue: UNAuthorizationOptions {
    var options: UNAuthorizationOptions = []
    if contains(.alert) { options.insert(.alert) }
    if contains(.badge) { options.insert(.badge) }
    if contains(.sound) { options.insert(.sound) }
    if contains(.criticalAlert) { options.insert(.criticalAlert) }
    if contains(.provisional) { options.insert(.provisional) }
    if contains(.providesAppNotificationSettings) {
      options.insert(.providesAppNotificationSettings)
    }
    return options
  }
}

/// Apple Events consent is scoped to the receiving application. Querying never prompts.
private func automationStatus(targetApplication: String, prompt: Bool) -> PermissionOperationResult<
  PermissionStatus
> {
  let target = NSAppleEventDescriptor(bundleIdentifier: targetApplication)
  let status = AEDeterminePermissionToAutomateTarget(
    target.aeDesc, typeWildCard, typeWildCard, prompt)
  return automationPermissionResult(for: status, prompt: prompt)
}

func automationPermissionResult(for status: OSStatus, prompt: Bool)
  -> PermissionOperationResult<PermissionStatus>
{
  switch status {
  case noErr: return .supported(.granted)
  case OSStatus(errAEEventNotPermitted): return .supported(.denied)
  case OSStatus(errAEEventWouldRequireUserConsent): return .supported(.notDetermined)
  case OSStatus(procNotFound) where !prompt: return .supported(.unknown)
  default: return .failed(.apiUnavailable)
  }
}
