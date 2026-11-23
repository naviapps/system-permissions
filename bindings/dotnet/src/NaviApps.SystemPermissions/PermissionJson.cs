using System.Text.Json.Serialization;

namespace NaviApps.SystemPermissions;

internal static class Command
{
    internal sealed record Simple(string Op);
    internal sealed record WithPermission(string Op, PermissionDescriptor Permission);
    internal sealed record WithOptions(string Op, PermissionDescriptor Permission, PermissionOptions Options);
    internal sealed record ForPlatform(string Op, PermissionDescriptor Permission, PermissionPlatform Platform, PermissionOptions Options);
    internal sealed record AdmitAccess(string Op, PermissionDescriptor Permission, PermissionPlatform Platform, bool Request, PermissionOptions? Options);
    internal sealed record WithResult<T>(string Op, T Result);
    internal sealed record WithStatus(string Op, PermissionStatus Status);
    internal sealed record UsageDescriptionKeys(string Op, string[] Keys);
    internal sealed record Track(string Op, List<PermissionDescriptor> Permissions);
    internal sealed record RecordObservation(string Op, PermissionDescriptor Permission, PermissionOperationResult Result);
    internal sealed record Apply(string Op, IReadOnlyList<PermissionUpdate> Updates, bool Cancelled);
    internal sealed record AdmitScoped(string Op, PermissionDescriptor Permission, PermissionOptions Options, string Kind, bool Cancelled);
    internal sealed record Finish(string Op, ulong Token);
}

[JsonSourceGenerationOptions(GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(Command.Simple))]
[JsonSerializable(typeof(Command.WithPermission))]
[JsonSerializable(typeof(Command.WithOptions))]
[JsonSerializable(typeof(Command.ForPlatform))]
[JsonSerializable(typeof(Command.AdmitAccess))]
[JsonSerializable(typeof(Command.WithResult<PermissionOperationResult>))]
[JsonSerializable(typeof(Command.WithResult<PermissionSettingsResult>))]
[JsonSerializable(typeof(Command.WithStatus))]
[JsonSerializable(typeof(Command.UsageDescriptionKeys))]
[JsonSerializable(typeof(Command.Track))]
[JsonSerializable(typeof(Command.RecordObservation))]
[JsonSerializable(typeof(Command.Apply))]
[JsonSerializable(typeof(Command.AdmitScoped))]
[JsonSerializable(typeof(Command.Finish))]
[JsonSerializable(typeof(PermissionDescriptor[]))]
[JsonSerializable(typeof(PermissionMetadata))]
[JsonSerializable(typeof(PermissionChecker.AccessAdmission))]
[JsonSerializable(typeof(PermissionChecker.SettingsAdmission))]
[JsonSerializable(typeof(PermissionSnapshot))]
[JsonSerializable(typeof(PermissionApplyOutcome))]
[JsonSerializable(typeof(PermissionStore.Observation))]
[JsonSerializable(typeof(PermissionStore.RefreshAdmission[]))]
[JsonSerializable(typeof(PermissionStore.ScopedAdmission))]
internal sealed partial class PermissionJson : JsonSerializerContext;
