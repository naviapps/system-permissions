namespace NaviApps.SystemPermissions;

/// <summary>Host scheduling and effects. Implementations must never prompt from StatusAsync.</summary>
public interface IPermissionEnvironment
{
    PermissionPlatform Platform { get; }
    Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken);
    Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken);
    Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken);
}

/// <summary>Read-only capability. A status check never requests access or opens Settings.</summary>
public interface IPermissionStatusChecking
{
    Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default);
}

public interface IPermissionChecking : IPermissionStatusChecking
{
    new Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default);
    Task<PermissionOperationResult> IPermissionStatusChecking.StatusAsync(PermissionDescriptor permission, PermissionOptions? options, CancellationToken cancellationToken)
        => StatusAsync(permission, options, cancellationToken);

    Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default);
    Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default);
}

/// <summary>Rust validates values and metadata before any host effect is invoked.</summary>
public sealed class PermissionChecker(IPermissionEnvironment environment) : IPermissionChecking
{
    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => Execute(permission, options, request: false, cancellationToken);
    public Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => Execute(permission, options, request: true, cancellationToken);
    public async Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        permission = PermissionContract.Validate(permission);
        options ??= PermissionOptions.None;
        try { options = PermissionContract.Validate(permission, options); }
        catch (PermissionContractException) { return PermissionSettingsResult.Failed(PermissionError.InvalidOptions); }
        var admission = Native.Read<SettingsAdmission>(
            Native.Call(new { op = "admitSettings", permission, platform = environment.Platform, options }));
        cancellationToken.ThrowIfCancellationRequested();
        if (admission.Result is { } completed) return completed;
        if (admission.Capability?.SystemSettingsURL is null)
            throw new PermissionContractException("Missing Settings destination.", "invalidResult");
        var result = await environment.OpenSettingsAsync(permission, options, cancellationToken).WaitAsync(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return PermissionContract.Validate(result);
    }

    private sealed record SettingsAdmission(PermissionCapability? Capability, PermissionSettingsResult? Result);

    private sealed record AccessAdmission(PermissionOptions? Options, PermissionOperationResult? Result);

    private async Task<PermissionOperationResult> Execute(PermissionDescriptor permission, PermissionOptions? options, bool request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        permission = PermissionContract.Validate(permission);
        PermissionOptions validatedOptions;
        try { validatedOptions = PermissionContract.Validate(permission, options ?? PermissionOptions.None); }
        catch (PermissionContractException) { return PermissionOperationResult.Failed(PermissionError.InvalidOptions); }
        var admission = Native.Read<AccessAdmission>(Native.Call(
            new { op = "admitAccess", permission, platform = environment.Platform, request, options = options is null ? null : validatedOptions }));
        cancellationToken.ThrowIfCancellationRequested();
        if (admission.Result is { } completed) return completed;
        var effectiveOptions = admission.Options ?? throw new PermissionContractException("Missing admitted options.", "invalidResult");
        var work = request
            ? environment.RequestAsync(permission, effectiveOptions, cancellationToken)
            : environment.StatusAsync(permission, effectiveOptions, cancellationToken);
        var result = await work.WaitAsync(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return PermissionContract.Validate(result);
    }
}
