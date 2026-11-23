namespace NaviApps.SystemPermissions;

/// <summary>Shared Rust metadata and validation. Calling these methods never requests OS access.</summary>
public static class PermissionContract
{
    /// <summary>Decodes and validates one portable descriptor from its original UTF-8 JSON bytes.
    /// Rust rejects malformed objects, including duplicate fields.</summary>
    public static PermissionDescriptor DecodeDescriptorJson(ReadOnlySpan<byte> utf8Json) =>
        Native.Read<PermissionDescriptor>(Native.DecodeDescriptor(utf8Json));

    public static PermissionDescriptor Validate(PermissionDescriptor permission)
    {
        return Native.Read<PermissionDescriptor>(Native.Call(new { op = "validateDescriptor", permission }));
    }
    public static PermissionOptions Validate(PermissionDescriptor permission, PermissionOptions options)
    {
        return Native.Read<PermissionOptions>(Native.Call(new { op = "validateOptions", permission, options }));
    }
    public static PermissionOperationResult Validate(PermissionOperationResult result)
    {
        return Native.Read<PermissionOperationResult>(Native.Call(new { op = "validateResult", result }));
    }
    public static PermissionSettingsResult Validate(PermissionSettingsResult result)
        => Native.Read<PermissionSettingsResult>(Native.Call(new { op = "validateSettingsResult", result }));
    /// <summary>Validates a usage description key and preserves its exact spelling.</summary>
    public static string ValidateUsageDescriptionKey(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        return Native.Read<string[]>(Native.Call(new { op = "validateUsageDescriptionKeys", keys = new[] { key } }))[0];
    }
    public static PermissionMetadata Metadata(PermissionDescriptor permission, PermissionPlatform platform, PermissionOptions? options = null)
        => Native.Read<PermissionMetadata>(Native.Call(new { op = "metadata", permission, platform, options = options ?? PermissionOptions.None }));
    public static IReadOnlyList<PermissionDescriptor> BuiltIns
        => Native.Read<PermissionDescriptor[]>(Native.Call(new { op = "builtIns" }));
    public static bool AllowsAccess(PermissionStatus status)
        => Native.Call(new { op = "allowsAccess", status }).GetBoolean();
    public static bool AllowsAccess(PermissionOperationResult result)
        => Native.Call(new { op = "resultAllowsAccess", result }).GetBoolean();
}
