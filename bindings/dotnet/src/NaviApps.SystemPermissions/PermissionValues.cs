using System.Collections.ObjectModel;
using System.Text.Json.Serialization;

namespace NaviApps.SystemPermissions;

public enum PermissionStatus { Granted, Limited, Provisional, Ephemeral, Denied, Restricted, NotDetermined, Unknown }
public enum PermissionError { InvalidOptions, OpenFailed, ApiUnavailable }
public enum PermissionPlatform { [JsonStringEnumMemberName("macos")] MacOS, Windows }

public sealed record PermissionCapability(
    bool SupportsStatusCheck, bool SupportsRequest, [property: JsonPropertyName("systemSettingsUrl")] string? SystemSettingsURL, bool RequiresRelaunch);

/// <summary>Host capability metadata with an owned, ordered list of usage description keys.</summary>
[System.Diagnostics.CodeAnalysis.SuppressMessage("Naming", "CA1711:Identifiers should not have incorrect suffix", Justification = "Permission describes an OS capability in the public SDK contract, not a code-access security permission.")]
public sealed record CustomPermission(PermissionCapability Capability, IReadOnlyList<string> UsageDescriptionKeys)
{
    private readonly ReadOnlyCollection<string>? keys = CopyKeys(UsageDescriptionKeys);

    public IReadOnlyList<string> UsageDescriptionKeys
    {
        get => keys!;
        init => keys = CopyKeys(value);
    }

    /// <summary>Compare capability and exact usage description keys in order.</summary>
    public bool Equals(CustomPermission? other) =>
        other is not null && Capability == other.Capability &&
        (ReferenceEquals(keys, other.keys) ||
            (keys is not null && other.keys is not null && keys.SequenceEqual(other.keys, StringComparer.Ordinal)));

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Capability);
        if (keys is not null)
            foreach (string key in keys)
                hash.Add(key, StringComparer.Ordinal);
        return hash.ToHashCode();
    }

    // Let malformed descriptors reach Rust for the same contract error.
    private static ReadOnlyCollection<string>? CopyKeys(IReadOnlyList<string>? keys) =>
        keys is null ? null : Array.AsReadOnly(keys.ToArray());
}

/// <summary>A permission identity and its optional host metadata. Automation on macOS requires a target application identifier.</summary>
public sealed record PermissionDescriptor(string Id, string? TargetApplication = null, CustomPermission? Custom = null)
{
    /// <summary>Compare the exact identifier and target used to identify a permission in the shared store.</summary>
    public bool HasSameIdentity(PermissionDescriptor? other) =>
        other is not null && Id == other.Id && TargetApplication == other.TargetApplication;

    public static PermissionDescriptor Accessibility { get; } = new("accessibility");
    public static PermissionDescriptor InputMonitoring { get; } = new("input_monitoring");
    public static PermissionDescriptor ScreenRecording { get; } = new("screen_recording");
    public static PermissionDescriptor Camera { get; } = new("camera");
    public static PermissionDescriptor Microphone { get; } = new("microphone");
    public static PermissionDescriptor Contacts { get; } = new("contacts");
    public static PermissionDescriptor Calendars { get; } = new("calendars");
    public static PermissionDescriptor Reminders { get; } = new("reminders");
    public static PermissionDescriptor Photos { get; } = new("photos");
    public static PermissionDescriptor SpeechRecognition { get; } = new("speech_recognition");
    public static PermissionDescriptor Notifications { get; } = new("notifications");
    public static PermissionDescriptor Location { get; } = new("location");
    public static PermissionDescriptor Bluetooth { get; } = new("bluetooth");
    public static PermissionDescriptor LocalNetwork { get; } = new("local_network");
    public static PermissionDescriptor MediaLibrary { get; } = new("media_library");
    public static PermissionDescriptor SystemAudioCapture { get; } = new("system_audio_capture");
    public static PermissionDescriptor DesktopFolder { get; } = new("desktop_folder");
    public static PermissionDescriptor DocumentsFolder { get; } = new("documents_folder");
    public static PermissionDescriptor DownloadsFolder { get; } = new("downloads_folder");
    public static PermissionDescriptor NetworkVolumes { get; } = new("network_volumes");
    public static PermissionDescriptor RemovableVolumes { get; } = new("removable_volumes");
    public static PermissionDescriptor FileProviderDomain { get; } = new("file_provider_domain");
    public static PermissionDescriptor FullDiskAccess { get; } = new("full_disk_access");
    public static PermissionDescriptor Automation(string targetApplication) => new("automation", targetApplication);
}

/// <summary>Stable SDK wire bits, independent of native platform option values.
/// Unknown raw bits round trip unchanged; they do not add native capabilities.</summary>
[Flags]
public enum NotificationRequestOptions : ulong
{
    Alert = 1,
    Badge = 2,
    Sound = 4,
    CriticalAlert = 8,
    Provisional = 16,
    ProvidesAppNotificationSettings = 32
}
public enum PhotoAccessLevel { ReadWrite, AddOnly }

public sealed record PermissionOptions(string Kind, ulong? NotificationOptions = null, PhotoAccessLevel? PhotoAccessLevel = null)
{
    public static PermissionOptions None { get; } = new("none");
    public static PermissionOptions Notifications(NotificationRequestOptions value) => new("notifications", (ulong)value);
    public static PermissionOptions Photos(PhotoAccessLevel value) => new("photos", PhotoAccessLevel: value);
}

/// <summary>A tagged result; validity and access semantics are owned by Rust.</summary>
public sealed record PermissionOperationResult(string Kind, PermissionStatus? Value = null,
    PermissionCapability? Capability = null, PermissionError? Error = null)
{
    public static PermissionOperationResult Supported(PermissionStatus status) => new("supported", status);
    public static PermissionOperationResult Unsupported(PermissionCapability capability) => new("unsupported", Capability: capability);
    public static PermissionOperationResult Failed(PermissionError error) => new("failed", Error: error);
    [JsonIgnore] public bool AllowsAccess => PermissionContract.AllowsAccess(this);
}

/// <summary>Settings launch outcome. This Boolean never represents observed authorization.</summary>
public sealed record PermissionSettingsResult(string Kind, bool? Value = null,
    PermissionCapability? Capability = null, PermissionError? Error = null)
{
    public static PermissionSettingsResult Supported(bool launched) => new("supported", launched);
    public static PermissionSettingsResult Unsupported(PermissionCapability capability) => new("unsupported", Capability: capability);
    public static PermissionSettingsResult Failed(PermissionError error) => new("failed", Error: error);
}

public sealed record PermissionMetadata(PermissionCapability Capability, IReadOnlyList<string> UsageDescriptionKeys, PermissionOptions DefaultOptions);
public sealed record PermissionValue(PermissionDescriptor Permission, PermissionOperationResult? Result);
public sealed record PermissionSnapshot(IReadOnlyList<PermissionValue> Values);
public sealed record PermissionUpdate(PermissionDescriptor Permission, ulong Token, PermissionOperationResult Result);
public sealed record PermissionApplyOutcome(bool Changed, uint Accepted);

public sealed class PermissionContractException : Exception
{
    public string? Error { get; }
    public string? IdentifierValidationReason { get; }
    internal PermissionContractException(string detail, string? error = null, string? reason = null) : base(detail)
    {
        Error = error;
        IdentifierValidationReason = reason;
    }
}
