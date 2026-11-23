/// An Info.plist usage description key, including host-defined keys for custom permissions.
public struct UsageDescriptionKey: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
  /// The exact spelling of the key.
  public let rawValue: String

  /// Creates a key validated by the shared permission contract.
  public init?(rawValue: String) {
    guard let key = try? Self.validated([rawValue]).first else { return nil }
    self = key
  }

  private init(validatedValue: String) {
    rawValue = validatedValue
  }

  static func validated(_ keys: [String]) throws -> [Self] {
    let values: [String] = try NativePermissions.call([
      "op": "validateUsageDescriptionKeys", "keys": keys,
    ])
    return values.map(Self.init(validatedValue:))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let key = Self(rawValue: try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid usage description key.")
    }
    self = key
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    for byte in rawValue.utf8 { hasher.combine(byte) }
  }

  /// The SDK's predefined macOS keys, in declaration order.
  public static let allCases = [
    camera, microphone, contacts, calendarsFullAccess, remindersFullAccess, photos,
    photosAddOnly, speechRecognition, location, bluetooth, localNetwork, mediaLibrary,
    systemAudioCapture, desktopFolder, documentsFolder, downloadsFolder, networkVolumes,
    removableVolumes, fileProviderDomain, appleEvents,
  ]

  /// `NSCameraUsageDescription`.
  public static let camera = Self(validatedValue: "NSCameraUsageDescription")
  /// `NSMicrophoneUsageDescription`.
  public static let microphone = Self(validatedValue: "NSMicrophoneUsageDescription")
  /// `NSContactsUsageDescription`.
  public static let contacts = Self(validatedValue: "NSContactsUsageDescription")
  /// `NSCalendarsFullAccessUsageDescription`.
  public static let calendarsFullAccess = Self(
    validatedValue: "NSCalendarsFullAccessUsageDescription")
  /// `NSRemindersFullAccessUsageDescription`.
  public static let remindersFullAccess = Self(
    validatedValue: "NSRemindersFullAccessUsageDescription")
  /// `NSPhotoLibraryUsageDescription`.
  public static let photos = Self(validatedValue: "NSPhotoLibraryUsageDescription")
  /// `NSPhotoLibraryAddUsageDescription`.
  public static let photosAddOnly = Self(validatedValue: "NSPhotoLibraryAddUsageDescription")
  /// `NSSpeechRecognitionUsageDescription`.
  public static let speechRecognition = Self(validatedValue: "NSSpeechRecognitionUsageDescription")
  /// `NSLocationUsageDescription`.
  public static let location = Self(validatedValue: "NSLocationUsageDescription")
  /// `NSBluetoothAlwaysUsageDescription`.
  public static let bluetooth = Self(validatedValue: "NSBluetoothAlwaysUsageDescription")
  /// `NSLocalNetworkUsageDescription`.
  public static let localNetwork = Self(validatedValue: "NSLocalNetworkUsageDescription")
  /// `NSAppleMusicUsageDescription`.
  public static let mediaLibrary = Self(validatedValue: "NSAppleMusicUsageDescription")
  /// `NSAudioCaptureUsageDescription`.
  public static let systemAudioCapture = Self(validatedValue: "NSAudioCaptureUsageDescription")
  /// `NSDesktopFolderUsageDescription`.
  public static let desktopFolder = Self(validatedValue: "NSDesktopFolderUsageDescription")
  /// `NSDocumentsFolderUsageDescription`.
  public static let documentsFolder = Self(validatedValue: "NSDocumentsFolderUsageDescription")
  /// `NSDownloadsFolderUsageDescription`.
  public static let downloadsFolder = Self(validatedValue: "NSDownloadsFolderUsageDescription")
  /// `NSNetworkVolumesUsageDescription`.
  public static let networkVolumes = Self(validatedValue: "NSNetworkVolumesUsageDescription")
  /// `NSRemovableVolumesUsageDescription`.
  public static let removableVolumes = Self(validatedValue: "NSRemovableVolumesUsageDescription")
  /// `NSFileProviderDomainUsageDescription`.
  public static let fileProviderDomain = Self(
    validatedValue: "NSFileProviderDomainUsageDescription")
  /// `NSAppleEventsUsageDescription`.
  public static let appleEvents = Self(validatedValue: "NSAppleEventsUsageDescription")
}
