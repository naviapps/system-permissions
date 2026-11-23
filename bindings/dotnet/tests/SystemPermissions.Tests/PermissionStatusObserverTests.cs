using System.Diagnostics;
using System.Threading.Channels;
using NaviApps.SystemPermissions;

internal static class PermissionStatusObserverTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    private static readonly PermissionOperationResult Granted = PermissionOperationResult.Supported(PermissionStatus.Granted);
    private static readonly PermissionOperationResult Denied = PermissionOperationResult.Supported(PermissionStatus.Denied);
    private static readonly PermissionOperationResult Unavailable = PermissionOperationResult.Failed(PermissionError.ApiUnavailable);
    private static readonly PermissionOperationResult Malformed = PermissionOperationResult.Unsupported(new(false, false, "relative/path", false));

    internal static async Task RunAsync()
    {
        await OrderedUpdatesAndScopedOptionsAsync();
        await InvalidDescriptorsAreRejectedBeforePollingAsync();
        await EnumerationStopsAtFirstExcessEntryAsync();
        await BoundedBacklogAndStableSamplesAsync();
        await ChangesSkipInitialAndStableSamplesAsync();
        await CancellationStopsPendingWorkAsync();
        await CancellationDuringOptionsStopsStatusDispatchAsync();
        await LongPollingIntervalStaysCancellableAsync();
        await FailureIsDeliveredAsync();
        await MalformedProviderResultStopsUpdatesAsync();
        await MalformedProviderResultStopsChangesAsync();
    }

    private static async Task InvalidDescriptorsAreRejectedBeforePollingAsync()
    {
        var checker = new DeferredStatusChecker();
        static PermissionOptions? UnexpectedOptions(PermissionDescriptor permission)
            => throw new UnreachableException($"Rejected descriptors must not invoke the options provider for {permission.Id}.");

        var valid = PermissionDescriptor.Automation("com.example.Keyboard");
        var invalid = PermissionDescriptor.Automation("com.example.\u212Aeyboard");
        var updates = PermissionStatusObserver.Updates([valid, invalid], checker, options: UnexpectedOptions);
        await AssertRejectedAsync(updates, "invalidTargetApplication");

        var permission = new PermissionDescriptor("com.example.status", Custom: new(new(true, true, null, false), []));
        var conflicting = permission with { Custom = new(new(true, false, null, false), []) };
        var changes = PermissionStatusObserver.Changes([permission, conflicting], checker, options: UnexpectedOptions);
        await AssertRejectedAsync(changes, "inconsistentMetadata");
        Check(!checker.Checks.TryPeek(out _), "A rejected descriptor list must not start any status checks.");

    }

    private static async Task EnumerationStopsAtFirstExcessEntryAsync()
    {
        var camera = PermissionDescriptor.Camera;
        var checker = new DeferredStatusChecker();
        await AssertRejectedAsync(PermissionStatusObserver.Updates(Oversized(camera), checker), "limitExceeded");
        await AssertRejectedAsync(PermissionStatusObserver.Changes(Oversized(camera), checker), "limitExceeded");
        Check(!checker.Checks.TryPeek(out _), "An oversized list must not invoke the status provider.");

        using var store = new PermissionStore();
        const int maximumEntries = 1024;
        store.Track([camera]);
        ulong token = store.Begin(camera)!.Value;
        var update = new PermissionUpdate(camera, token, Granted);
        Reject(() => store.Track(Oversized(camera)), "limitExceeded");
        Reject(() => store.Apply(Oversized(update)), "limitExceeded");
        Reject(() => store.Track(new PermissionDescriptor[] { null! }.Concat(Oversized(camera))), "invalidJson");

        static IEnumerable<T> Oversized<T>(T value)
        {
            for (int index = 0; index <= maximumEntries; index++) yield return value;
            throw new UnreachableException("A caller enumerable was read past the first excess entry.");
        }

        static void Reject(Action command, string errorCode)
        {
            try { command(); }
            catch (PermissionContractException error) when (error.Error == errorCode) { return; }
            throw new UnreachableException("A store command must preserve the native validation error.");
        }
    }

    private static async Task AssertRejectedAsync<T>(IAsyncEnumerable<T> stream, string errorCode)
    {
        await using var iterator = stream.GetAsyncEnumerator();
        try { _ = await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout); }
        catch (PermissionContractException error) when (error.Error == errorCode) { return; }
        throw new UnreachableException("The observer must reject the entire invalid descriptor list.");
    }

    private static async Task OrderedUpdatesAndScopedOptionsAsync()
    {
        var checker = new DeferredStatusChecker();
        var camera = PermissionDescriptor.Camera;
        var photos = PermissionDescriptor.Photos;
        var addOnly = PermissionOptions.Photos(PhotoAccessLevel.AddOnly);
        await using (var empty = PermissionStatusObserver.Updates([], checker).GetAsyncEnumerator())
            Check(!await empty.MoveNextAsync(), "An empty observer must finish without a check.");
        Check(!checker.Checks.TryPeek(out _), "Empty permissions must not invoke the status provider.");

        var updates = PermissionStatusObserver.Updates([photos, photos, camera], checker,
            options: permission => permission == photos ? addOnly : null);
        await using var iterator = updates.GetAsyncEnumerator();
        var first = iterator.MoveNextAsync().AsTask();
        var photosCheck = await checker.NextAsync();
        Check(photosCheck.Permission == photos && photosCheck.Options == addOnly, "First-occurrence order and explicit scope must be retained.");
        photosCheck.Result.SetResult(Granted);
        Check(await first.WaitAsync(Timeout) && iterator.Current == new PermissionStatusObserver.Update(photos, Granted), "Initial success must be emitted.");

        var second = iterator.MoveNextAsync().AsTask();
        var cameraCheck = await checker.NextAsync();
        Check(cameraCheck.Permission == camera && cameraCheck.Options is null, "Duplicate permissions must be skipped, with unspecified options delegated to the provider.");
        cameraCheck.Result.SetResult(Unavailable);
        Check(await second.WaitAsync(Timeout) && iterator.Current == new PermissionStatusObserver.Update(camera, Unavailable), "Initial failures are also observations.");
    }

    private static async Task BoundedBacklogAndStableSamplesAsync()
    {
        var checker = new DeferredStatusChecker();
        var camera = PermissionDescriptor.Camera;
        var updates = PermissionStatusObserver.Updates([camera, camera], checker, pollingInterval: TimeSpan.Zero);
        await using var iterator = updates.GetAsyncEnumerator();
        var first = iterator.MoveNextAsync().AsTask();
        var initial = await checker.NextAsync();
        var interval = Stopwatch.StartNew();
        initial.Result.SetResult(Granted);
        Check(await first.WaitAsync(Timeout), "Initial sample must be emitted.");
        var second = await checker.NextAsync();
        Check(interval.Elapsed >= TimeSpan.FromMilliseconds(240), "Subminimum polling intervals must be clamped.");
        second.Result.SetResult(Denied);
        (await checker.NextAsync()).Result.SetResult(Unavailable);
        var repeating = await checker.NextAsync();

        Check(await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout) && iterator.Current.Result == Unavailable,
            "The one-permission backlog keeps the newest buffered sample.");
        repeating.Result.SetResult(Unavailable);
        Check(await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout) && iterator.Current.Result == Unavailable,
            "An unchanged sample must be emitted again on the next poll.");
    }

    private static async Task ChangesSkipInitialAndStableSamplesAsync()
    {
        var checker = new DeferredStatusChecker();
        var camera = PermissionDescriptor.Camera;
        var changes = PermissionStatusObserver.Changes([camera], checker, pollingInterval: TimeSpan.Zero);
        await using var iterator = changes.GetAsyncEnumerator();
        var next = iterator.MoveNextAsync().AsTask();
        (await checker.NextAsync()).Result.SetResult(Granted);
        (await checker.NextAsync()).Result.SetResult(Granted);
        var changed = await checker.NextAsync();
        Check(!next.IsCompleted, "Initial and unchanged results must not produce a change event.");
        changed.Result.SetResult(Denied);
        var expected = new PermissionStatusObserver.Change(camera, Granted, Denied);
        Check(await next.WaitAsync(Timeout) && iterator.Current == expected,
            "A change must carry the two adjacent results.");

        (await checker.NextAsync()).Result.SetResult(Granted);
        (await checker.NextAsync()).Result.SetResult(Unavailable);
        var pending = await checker.NextAsync();
        Check(await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout) &&
            iterator.Current == new PermissionStatusObserver.Change(camera, Granted, Unavailable),
            "A buffered change retains the preceding poll as its previous result.");
        await iterator.DisposeAsync().AsTask().WaitAsync(Timeout);
        Check(pending.Token.IsCancellationRequested, "Disposing an iterator must cancel pending provider work.");
        pending.Result.SetResult(Denied);
    }

    private static async Task CancellationStopsPendingWorkAsync()
    {
        var checker = new DeferredStatusChecker();
        using var cancellation = new CancellationTokenSource();
        var updates = PermissionStatusObserver.Updates([PermissionDescriptor.Camera, PermissionDescriptor.Microphone], checker);
        await using var iterator = updates.GetAsyncEnumerator(cancellation.Token);
        var next = iterator.MoveNextAsync().AsTask();
        var pending = await checker.NextAsync();
        cancellation.Cancel();
        try
        {
            await next.WaitAsync(Timeout);
            throw new UnreachableException("Cancellation must end the wait for an uncooperative status provider.");
        }
        catch (OperationCanceledException) { }
        pending.Result.SetResult(Granted);
        Check(pending.Token.IsCancellationRequested && !checker.Checks.TryPeek(out _),
            "A cancelled poll must discard the pending result and skip remaining permissions.");
    }

    private static async Task CancellationDuringOptionsStopsStatusDispatchAsync()
    {
        foreach (bool updates in new[] { true, false })
        {
            var checker = new DeferredStatusChecker();
            using var cancellation = new CancellationTokenSource();
            int optionCalls = 0;
            PermissionOptions? SelectOptions(PermissionDescriptor permission)
            {
                Check(permission == PermissionDescriptor.Camera, "Cancellation must skip the second permission's options.");
                optionCalls++;
                cancellation.Cancel();
                return PermissionOptions.None;
            }

            PermissionDescriptor[] permissions = [PermissionDescriptor.Camera, PermissionDescriptor.Microphone];
            IAsyncEnumerable<object> stream = updates
                ? PermissionStatusObserver.Updates(permissions, checker, options: SelectOptions, cancellationToken: cancellation.Token)
                : PermissionStatusObserver.Changes(permissions, checker, options: SelectOptions, cancellationToken: cancellation.Token);
            await using var iterator = stream.GetAsyncEnumerator();
            try
            {
                await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout);
                throw new UnreachableException("Cancellation from the options callback must end observation.");
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            Check(optionCalls == 1 && !checker.Checks.TryPeek(out _),
                "Cancellation during options must prevent any status check.");
        }
    }

    private static async Task LongPollingIntervalStaysCancellableAsync()
    {
        var checker = new DeferredStatusChecker();
        using var cancellation = new CancellationTokenSource();
        var updates = PermissionStatusObserver.Updates([PermissionDescriptor.Camera], checker,
            pollingInterval: TimeSpan.FromDays(60), cancellationToken: cancellation.Token);
        await using var iterator = updates.GetAsyncEnumerator();
        var initial = iterator.MoveNextAsync().AsTask();
        (await checker.NextAsync()).Result.SetResult(Granted);
        Check(await initial.WaitAsync(Timeout) &&
            iterator.Current == new PermissionStatusObserver.Update(PermissionDescriptor.Camera, Granted),
            "A long polling interval must still emit an initial sample.");

        var next = iterator.MoveNextAsync().AsTask();
        try
        {
            await next.WaitAsync(TimeSpan.FromMilliseconds(250));
            throw new UnreachableException("A long polling interval must keep waiting for the next sample.");
        }
        catch (TimeoutException) { }
        finally { cancellation.Cancel(); }
        try
        {
            await next.WaitAsync(Timeout);
            throw new UnreachableException("Cancellation must wake a poll during a long interval.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        Check(!checker.Checks.TryPeek(out _), "Cancellation must not start another status check.");
    }

    private static async Task FailureIsDeliveredAsync()
    {
        var checker = new DeferredStatusChecker();
        var updates = PermissionStatusObserver.Updates([PermissionDescriptor.Camera], checker);
        await using var iterator = updates.GetAsyncEnumerator();
        var next = iterator.MoveNextAsync().AsTask();
        (await checker.NextAsync()).Result.SetResult(new PermissionOperationResult("malformed"));
        try
        {
            await next.WaitAsync(Timeout);
            throw new UnreachableException("The observer must propagate Rust result validation failures.");
        }
        catch (PermissionContractException) { }
    }

    private static async Task MalformedProviderResultStopsUpdatesAsync()
    {
        var checker = new DeferredStatusChecker();
        var camera = PermissionDescriptor.Camera;
        var microphone = PermissionDescriptor.Microphone;
        var updates = PermissionStatusObserver.Updates([camera, microphone, PermissionDescriptor.Contacts], checker);
        await using var iterator = updates.GetAsyncEnumerator();
        var first = iterator.MoveNextAsync().AsTask();
        (await checker.NextAsync()).Result.SetResult(Granted);
        Check(await first.WaitAsync(Timeout) && iterator.Current == new PermissionStatusObserver.Update(camera, Granted),
            "A valid sample before a malformed one must still be delivered.");

        var invalid = await checker.NextAsync();
        Check(invalid.Permission == microphone, "The malformed result must come from the second permission.");
        invalid.Result.SetResult(Malformed);
        await AssertInvalidResultAsync(iterator.MoveNextAsync().AsTask());
        Check(!checker.Checks.TryPeek(out _), "A malformed result must stop checks for the remaining permissions.");
    }

    private static async Task MalformedProviderResultStopsChangesAsync()
    {
        var checker = new DeferredStatusChecker();
        var camera = PermissionDescriptor.Camera;
        var changes = PermissionStatusObserver.Changes([camera], checker, pollingInterval: TimeSpan.Zero);
        await using var iterator = changes.GetAsyncEnumerator();
        var first = iterator.MoveNextAsync().AsTask();
        (await checker.NextAsync()).Result.SetResult(Granted);
        (await checker.NextAsync()).Result.SetResult(Denied);
        Check(await first.WaitAsync(Timeout) && iterator.Current == new PermissionStatusObserver.Change(camera, Granted, Denied),
            "A malformed result must not erase an earlier valid transition.");

        (await checker.NextAsync()).Result.SetResult(Malformed);
        await AssertInvalidResultAsync(iterator.MoveNextAsync().AsTask());
        Check(!checker.Checks.TryPeek(out _), "A malformed result must stop later polls.");
    }

    private static async Task AssertInvalidResultAsync(Task<bool> next)
    {
        try
        {
            _ = await next.WaitAsync(Timeout);
            throw new UnreachableException("A malformed provider result must terminate the observer with a Rust contract error.");
        }
        catch (PermissionContractException error) when (error.Error == "invalidResult") { }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new UnreachableException(message);
    }

    private sealed record StatusCheck(PermissionDescriptor Permission, PermissionOptions? Options, CancellationToken Token)
    {
        internal TaskCompletionSource<PermissionOperationResult> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class DeferredStatusChecker : IPermissionStatusChecking
    {
        private readonly Channel<StatusCheck> checks = Channel.CreateUnbounded<StatusCheck>();
        internal ChannelReader<StatusCheck> Checks => checks.Reader;

        public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default)
        {
            var check = new StatusCheck(permission, options, cancellationToken);
            if (!checks.Writer.TryWrite(check)) throw new UnreachableException("Could not record a status check.");
            return check.Result.Task;
        }

        internal Task<StatusCheck> NextAsync() => checks.Reader.ReadAsync().AsTask().WaitAsync(Timeout);
    }
}
