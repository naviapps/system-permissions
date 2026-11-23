using System.Text.Json;

namespace NaviApps.SystemPermissions;

/// <summary>Owned Rust state. This adapter serializes native calls; Rust owns identity,
/// tracking, tokens, stale-result rejection, batch validation and access semantics.</summary>
public sealed class PermissionStore : IDisposable
{
    private static readonly Lazy<int> BatchLimit = new(
        () =>
        {
            int limit = Native.Call(new Command.Simple("storeBatchLimit")).GetInt32();
            if (limit < 1) throw new PermissionContractException("Invalid native permission batch limit.", "invalidResult");
            return limit;
        }, LazyThreadSafetyMode.PublicationOnly);

    private readonly object gate = new();
    private readonly StoreHandle handle = new();
    private bool disposed;
    internal sealed record RefreshAdmission(PermissionDescriptor Permission, ulong Token);
    internal sealed record ScopedAdmission(AdmissionKind Kind, ulong? Token);
    internal sealed record Observation(PermissionOperationResult Result, PermissionOperationResult? PreviousResult);
    internal enum AdmissionKind { Untracked, InvalidOptions, Isolated, Suppressed, Stored }

    private JsonElement Call<T>(T command)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return Native.Call(handle, command);
    }
    // Consume host input before taking the store lock. Keeping the first excess
    // entry lets Rust apply its normal wire checks and reject the count.
    internal static List<T> CaptureBatch<T>(IEnumerable<T> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        using var iterator = values.GetEnumerator();
        var batch = new List<T>();
        if (!iterator.MoveNext()) return batch;

        int limit = BatchLimit.Value;
        do { batch.Add(iterator.Current); }
        while (batch.Count <= limit && iterator.MoveNext());
        return batch;
    }

    public PermissionSnapshot Track(IEnumerable<PermissionDescriptor> permissions) =>
        TrackCaptured(CaptureBatch(permissions));

    internal PermissionSnapshot TrackCaptured(List<PermissionDescriptor> permissions)
    {
        lock (gate) return Native.Read<PermissionSnapshot>(Call(new Command.Track("track", permissions)));
    }

    internal Observation RecordObservation(PermissionDescriptor permission, PermissionOperationResult result)
    {
        lock (gate) return Native.Read<Observation>(Call(new Command.RecordObservation("recordObservation", permission, result)));
    }

    public PermissionOperationResult? Get(PermissionDescriptor permission)
    {
        lock (gate) return ReadStatus(permission);
    }
    public ulong? Begin(PermissionDescriptor permission)
    {
        lock (gate)
        {
            var value = Call(new Command.WithPermission("begin", permission)).GetProperty("token");
            return value.ValueKind == JsonValueKind.Null ? null : value.GetUInt64();
        }
    }
    public PermissionApplyOutcome Apply(IEnumerable<PermissionUpdate> updates, bool cancelled = false)
    {
        var values = CaptureBatch(updates);
        lock (gate) return Native.Read<PermissionApplyOutcome>(Call(new Command.Apply("apply", values, cancelled)));
    }
    public PermissionSnapshot Snapshot
    {
        get { lock (gate) return ReadSnapshot(); }
    }

    /// <summary>Checks only. A pending request for this scope returns stored status without invoking the checker.</summary>
    public Task<PermissionOperationResult> RefreshAsync(IPermissionStatusChecking checker, PermissionDescriptor permission,
        PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => RunAsync(checker.StatusAsync, permission, options, "refresh", cancellationToken);

    /// <summary>Checks only, using the status capability of an interactive checker.</summary>
    public Task<PermissionOperationResult> RefreshAsync(IPermissionChecking checker, PermissionDescriptor permission,
        PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => RefreshAsync((IPermissionStatusChecking)checker, permission, options, cancellationToken);

    /// <summary>Checks currently tracked permissions and commits their results together.
    /// Pending requests are skipped. Cancellation before commit leaves stored results unchanged.</summary>
    public async Task<PermissionSnapshot> RefreshAllAsync(IPermissionStatusChecking checker, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RefreshAdmission[] admissions;
        lock (gate) admissions = Native.Read<RefreshAdmission[]>(Call(new Command.Simple("admitAllRefreshes")));
        try
        {
            var updates = await Task.WhenAll(admissions.Select(async admission =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                var result = await checker.StatusAsync(admission.Permission, cancellationToken: cancellationToken)
                    .WaitAsync(cancellationToken).ConfigureAwait(false);
                return new PermissionUpdate(admission.Permission, admission.Token, result);
            })).ConfigureAwait(false);

            lock (gate)
            {
                ApplyChecked(updates, cancellationToken);
                return ReadSnapshot();
            }
        }
        finally
        {
            lock (gate)
            {
                foreach (var admission in admissions) Finish(admission.Token);
            }
        }
    }

    /// <summary>Explicit user request. New requests supersede older work; pending requests suppress refresh admission.</summary>
    public Task<PermissionOperationResult> RequestAsync(IPermissionChecking checker, PermissionDescriptor permission,
        PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => RunAsync(checker.RequestAsync, permission, options, "request", cancellationToken);

    private async Task<PermissionOperationResult> RunAsync(
        Func<PermissionDescriptor, PermissionOptions?, CancellationToken, Task<PermissionOperationResult>> check,
        PermissionDescriptor permission, PermissionOptions? options, string kind, CancellationToken cancellationToken)
    {
        Task<PermissionOperationResult> CheckAsync()
        {
            cancellationToken.ThrowIfCancellationRequested();
            var canonical = permission.Custom is null ? permission : PermissionContract.Validate(permission);
            cancellationToken.ThrowIfCancellationRequested();
            return check(canonical, options, cancellationToken).WaitAsync(cancellationToken);
        }

        ScopedAdmission admission;
        lock (gate)
        {
            cancellationToken.ThrowIfCancellationRequested();
            admission = Native.Read<ScopedAdmission>(Call(new Command.AdmitScoped(
                "admitScoped", permission, options ?? PermissionOptions.None, kind, Cancelled: false)));
            switch (admission.Kind)
            {
                case AdmissionKind.Untracked:
                    throw new InvalidOperationException("Permission is not tracked by this store.");
                case AdmissionKind.InvalidOptions:
                    return PermissionOperationResult.Failed(PermissionError.InvalidOptions);
                case AdmissionKind.Suppressed:
                    cancellationToken.ThrowIfCancellationRequested();
                    return ReadStatus(permission) ?? PermissionOperationResult.Supported(PermissionStatus.Unknown);
            }
        }

        if (admission.Kind == AdmissionKind.Isolated)
        {
            var scopedResult = await CheckAsync().ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return PermissionContract.Validate(scopedResult);
        }

        ulong token = admission.Token ?? throw new PermissionContractException("Missing admission token.", "invalidResult");
        try
        {
            var result = await CheckAsync().ConfigureAwait(false);
            lock (gate)
            {
                ApplyChecked([new PermissionUpdate(permission, token, result)], cancellationToken);
                return ReadStatus(permission) ?? PermissionOperationResult.Supported(PermissionStatus.Unknown);
            }
        }
        finally
        {
            lock (gate) Finish(token);
        }
    }

    private PermissionSnapshot ReadSnapshot() => Native.Read<PermissionSnapshot>(Call(new Command.Simple("snapshot")));

    private PermissionOperationResult? ReadStatus(PermissionDescriptor permission)
    {
        var value = Call(new Command.WithPermission("get", permission));
        return value.ValueKind == JsonValueKind.Null ? null : Native.Read<PermissionOperationResult>(value);
    }

    private void ApplyChecked(PermissionUpdate[] updates, CancellationToken cancellationToken)
    {
        var cancelled = cancellationToken.IsCancellationRequested;
        Call(new Command.Apply("apply", updates, cancelled));
        if (cancelled) cancellationToken.ThrowIfCancellationRequested();
    }

    private void Finish(ulong token)
    {
        // Disposal already destroys all work.
        if (!disposed) Call(new Command.Finish("finish", token));
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            handle.Dispose();
        }
    }
}
