namespace NaviApps.SystemPermissions.Windows;

/// <summary>Dispatches an explicit request start to the host UI thread. The dispatcher
/// must keep its normal message loop running after the action returns.</summary>
public interface IWindowsPermissionDispatcher
{
    Task<T> InvokeAsync<T>(Func<T> action, CancellationToken cancellationToken);
}

/// <summary>Use a SynchronizationContext captured on the host's existing STA UI thread.</summary>
public sealed class SynchronizationContextPermissionDispatcher(SynchronizationContext context) : IWindowsPermissionDispatcher
{
    public async Task<T> InvokeAsync<T>(Func<T> action, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(action);
        cancellationToken.ThrowIfCancellationRequested();

        var source = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Func<T>? pending = action;
        // Cancellation and the UI callback each try to take the queued action.
        using var registration = cancellationToken.UnsafeRegister(_ =>
        {
            if (Interlocked.Exchange(ref pending, null) is not null)
                source.SetCanceled(cancellationToken);
        }, null);

        if (!source.Task.IsCompleted)
        {
            context.Post(_ =>
            {
                var work = Interlocked.Exchange(ref pending, null);
                if (work is null) return;
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    // Deliver a started action's result so its caller can release the native token.
                    source.SetResult(work());
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { source.SetCanceled(cancellationToken); }
                catch (Exception error) { source.SetException(error); }
            }, null);
        }
        return await source.Task.ConfigureAwait(false);
    }
}

/// <summary>Native Windows privacy effects. No OS requests are made by construction,
/// metadata, tracking or status. Unpackaged AppCapability status is conservatively unavailable.</summary>
public sealed class WindowsPermissionEnvironment(IWindowsPermissionDispatcher dispatcher) : IPermissionEnvironment
{
    public PermissionPlatform Platform => PermissionPlatform.Windows;
    private static PermissionOperationResult Unavailable() => PermissionOperationResult.Failed(PermissionError.ApiUnavailable);

    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows()) return Task.FromResult(Unavailable());
        return Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Native.Read<PermissionOperationResult>(Native.Call(new { op = "windowsStatus", permission, options }));
        }, cancellationToken);
    }

    public async Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows()) return Unavailable();
        var start = await dispatcher.InvokeAsync(() => Native.Call(new { op = "windowsRequest", permission, options }), cancellationToken).ConfigureAwait(false);
        if (start.TryGetProperty("result", out var immediate))
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Native.Read<PermissionOperationResult>(immediate);
        }
        ulong token = start.GetProperty("token").GetUInt64();
        bool consumed = false;
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var poll = await Task.Run(() => Native.Call(new { op = "windowsPollRequest", token }), cancellationToken).ConfigureAwait(false);
                if (poll.TryGetProperty("result", out var result))
                {
                    consumed = true;
                    cancellationToken.ThrowIfCancellationRequested();
                    return Native.Read<PermissionOperationResult>(result);
                }
                await Task.Delay(TimeSpan.FromMilliseconds(25), cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            if (!consumed)
            {
                // Always release the native operation, even when the caller cancelled.
                // The OS may already have shown UI; cancellation cannot retract consent.
                await Task.Run(() => Native.Call(new { op = "windowsCancelRequest", token })).ConfigureAwait(false);
            }
        }
    }

    public Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows()) return Task.FromResult(PermissionSettingsResult.Failed(PermissionError.ApiUnavailable));
        return dispatcher.InvokeAsync(() => Native.Read<PermissionSettingsResult>(Native.Call(new { op = "windowsOpenSettings", permission, options })), cancellationToken);
    }
}
