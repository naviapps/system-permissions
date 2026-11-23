using System.Runtime.CompilerServices;
using System.Threading.Channels;

namespace NaviApps.SystemPermissions;

/// <summary>Polls permissions using only status-checking capability.</summary>
public static class PermissionStatusObserver
{
    private static readonly TimeSpan MaximumTimerInterval = TimeSpan.FromMilliseconds(uint.MaxValue - 1L);

    public sealed record Update(PermissionDescriptor Permission, PermissionOperationResult Result);

    public sealed record Change(PermissionDescriptor Permission, PermissionOperationResult PreviousResult, PermissionOperationResult CurrentResult);

    /// <summary>Emits each sample, including initial and unchanged results. A slow consumer can miss samples.</summary>
    public static IAsyncEnumerable<Update> Updates(
        IEnumerable<PermissionDescriptor> permissions, IPermissionStatusChecking checker,
        TimeSpan? pollingInterval = null, Func<PermissionDescriptor, PermissionOptions?>? options = null,
        CancellationToken cancellationToken = default)
        => Observe(permissions, checker, pollingInterval, options,
            static (permission, _, current) => new Update(permission, current), cancellationToken);

    /// <summary>Emits changes between consecutive samples and skips the initial sample.
    /// The previous result describes the preceding poll, even if a slow consumer missed that event.</summary>
    public static IAsyncEnumerable<Change> Changes(
        IEnumerable<PermissionDescriptor> permissions, IPermissionStatusChecking checker,
        TimeSpan? pollingInterval = null, Func<PermissionDescriptor, PermissionOptions?>? options = null,
        CancellationToken cancellationToken = default)
        => Observe(permissions, checker, pollingInterval, options,
            static (permission, previous, current) => previous is not null
                ? new Change(permission, previous, current) : null, cancellationToken);

    private static async IAsyncEnumerable<T> Observe<T>(
        IEnumerable<PermissionDescriptor> permissions, IPermissionStatusChecking checker,
        TimeSpan? pollingInterval, Func<PermissionDescriptor, PermissionOptions?>? options,
        Func<PermissionDescriptor, PermissionOperationResult?, PermissionOperationResult, T?> sample,
        [EnumeratorCancellation] CancellationToken cancellationToken) where T : class
    {
        ArgumentNullException.ThrowIfNull(permissions);
        ArgumentNullException.ThrowIfNull(checker);
        cancellationToken.ThrowIfCancellationRequested();
        var requested = PermissionStore.CaptureBatch(permissions);
        if (requested.Count == 0) yield break;

        using var state = new PermissionStore();
        var tracked = state.TrackCaptured(requested).Values;

        var interval = pollingInterval ?? TimeSpan.FromSeconds(2);
        var minimumInterval = TimeSpan.FromMilliseconds(250);
        if (interval < minimumInterval) interval = minimumInterval;

        var events = Channel.CreateBounded<T>(new BoundedChannelOptions(tracked.Count)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true
        });
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var producer = Task.Run(PollAsync, CancellationToken.None);

        try
        {
            await foreach (var value in events.Reader.ReadAllAsync(stop.Token).ConfigureAwait(false))
            {
                stop.Token.ThrowIfCancellationRequested();
                yield return value;
            }
            stop.Token.ThrowIfCancellationRequested();
        }
        finally
        {
            try { await stop.CancelAsync().ConfigureAwait(false); }
            finally { await producer.ConfigureAwait(false); }
        }

        async Task PollAsync()
        {
            var token = stop.Token;
            try
            {
                while (true)
                {
                    foreach (var entry in tracked)
                    {
                        token.ThrowIfCancellationRequested();
                        var permission = entry.Permission;
                        var selectedOptions = options?.Invoke(permission);
                        token.ThrowIfCancellationRequested();
                        var current = await checker.StatusAsync(permission, selectedOptions, token)
                            .WaitAsync(token).ConfigureAwait(false);
                        token.ThrowIfCancellationRequested();
                        var observation = state.RecordObservation(permission, current);
                        var value = sample(permission, observation.PreviousResult, observation.Result);
                        if (value is not null) events.Writer.TryWrite(value);
                    }
                    var remaining = interval;
                    // Long polling intervals can span more than one .NET timer.
                    while (remaining > MaximumTimerInterval)
                    {
                        await Task.Delay(MaximumTimerInterval, token).ConfigureAwait(false);
                        remaining -= MaximumTimerInterval;
                    }
                    await Task.Delay(remaining, token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception error) { events.Writer.TryComplete(error); }
            finally { events.Writer.TryComplete(); }
        }
    }
}
