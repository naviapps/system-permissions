using System.Text.Json.Serialization.Metadata;
using NaviApps.SystemPermissions;
using NaviApps.SystemPermissions.Windows;

// Observe apply serialization after the store has sampled the cancellation token.
Action? onUpdateSerialization = null;
Action? onDescriptorSerialization = null;
Native.Json.TypeInfoResolver = Native.Json.TypeInfoResolver!.WithAddedModifier(info =>
{
    if (info.Type == typeof(PermissionUpdate))
        info.OnSerializing = _ => Interlocked.Exchange(ref onUpdateSerialization, null)?.Invoke();
    if (info.Type == typeof(PermissionDescriptor))
        info.OnSerializing = _ => onDescriptorSerialization?.Invoke();
});
NotificationOptionsContractTests.Run();
await PermissionCheckerCancellationTests.RunAsync();
await PermissionStatusObserverTests.RunAsync();

static void Check(bool condition, string message)
{
    if (!condition) throw new System.Diagnostics.UnreachableException(message);
}
static void Rejected(Action action, string code)
{
    try { action(); }
    catch (PermissionContractException error) when (error.Error == code) { return; }
    throw new System.Diagnostics.UnreachableException("Expected shared Rust validation error: " + code);
}
static async Task Cancelled(Task task)
{
    try { await task; }
    catch (OperationCanceledException) { return; }
    throw new System.Diagnostics.UnreachableException("Expected cancellation.");
}
static async Task RejectedAsync(Task task)
{
    try { await task; }
    catch (PermissionContractException) { return; }
    throw new System.Diagnostics.UnreachableException("Expected shared Rust validation rejection.");
}

var camera = PermissionDescriptor.Camera;
var granted = PermissionOperationResult.Supported(PermissionStatus.Granted);
var denied = PermissionOperationResult.Supported(PermissionStatus.Denied);
var unknown = PermissionOperationResult.Supported(PermissionStatus.Unknown);
Check(Native.AbiVersion() == 2, "The binding must load the Windows desktop contract from ABI 2.");
Check(PermissionContract.BuiltIns.Contains(camera), "Built-in descriptors must project to managed values.");
Check(PermissionContract.AllowsAccess(PermissionStatus.Ephemeral), "A bare status must bridge to the access query.");
Check(PermissionOperationResult.Supported(PermissionStatus.Limited).AllowsAccess && !denied.AllowsAccess,
    "Supported results must project the Rust access decision.");
Check(!PermissionOperationResult.Failed(PermissionError.ApiUnavailable).AllowsAccess, "Failure cannot grant access.");
var metadata = PermissionContract.Metadata(camera, PermissionPlatform.Windows);
Check(metadata.Capability.SystemSettingsURL?.StartsWith("ms-settings:", StringComparison.Ordinal) == true,
    "Windows metadata must decode its Settings URL.");
Check(metadata.Capability.SupportsStatusCheck && !metadata.Capability.SupportsRequest,
    "Windows desktop describes its status observation and unsupported direct request.");
Check(PermissionContract.Metadata(PermissionDescriptor.Photos, PermissionPlatform.MacOS,
    PermissionOptions.Photos(PhotoAccessLevel.AddOnly)).UsageDescriptionKeys.Single() == "NSPhotoLibraryAddUsageDescription", "Option-dependent metadata.");
Check(PermissionContract.Validate(PermissionDescriptor.Automation("com.apple.TextEdit")).TargetApplication == "com.apple.TextEdit", "Target spelling must be retained.");
var portable = PermissionContract.DecodeDescriptorJson("""
    {"id":"com.example.custom","custom":{"capability":{"supportsStatusCheck":true,
      "supportsRequest":false,"systemSettingsUrl":"example:é","requiresRelaunch":false},
      "usageDescriptionKeys":["HostKey","HostKey"]}}
    """u8);
Check(portable.Custom?.Capability.SystemSettingsURL == "example:é" &&
    portable.Custom.UsageDescriptionKeys.Single() == "HostKey",
    "Portable bytes preserve host metadata after Rust canonicalization.");
Check(PermissionContract.DecodeDescriptorJson("""{"id":"automation","targetApplication":"com.example.App"}"""u8)
    == PermissionDescriptor.Automation("com.example.App"), "Portable bytes preserve scoped identity.");
Rejected(() => PermissionContract.DecodeDescriptorJson("""{"id":"camera","id":"microphone"}"""u8), "invalidJson");
Rejected(() => PermissionContract.DecodeDescriptorJson("""{"id":"camera"},"permission":{"id":"microphone"}"""u8), "invalidJson");
Rejected(() => PermissionContract.DecodeDescriptorJson([.. "{\"id\":\"cam"u8, 0xFF, .. "era\"}"u8]), "invalidUtf8");
Rejected(() => PermissionContract.DecodeDescriptorJson(new byte[1024 * 1024]), "inputTooLarge");
Rejected(() => PermissionContract.Validate(new PermissionDescriptor("automation")), "invalidTargetApplication");
Rejected(() => _ = new PermissionOperationResult("supported", PermissionStatus.Granted, Error: PermissionError.OpenFailed).AllowsAccess,
    "invalidJson");
Check(PermissionContract.Validate(PermissionSettingsResult.Supported(true)).Value == true, "Settings result is a Boolean launch outcome.");
var notifications = new PermissionOptions("notifications", ulong.MaxValue);
Check(PermissionContract.Validate(PermissionDescriptor.Notifications, notifications).NotificationOptions == ulong.MaxValue, "uint64 notification options must not pass through floating point.");
const string hostKey = "HostUsageKey";
const string composedKey = "Fixture\u00e9";
const string decomposedKey = "Fixturee\u0301";
Check(PermissionContract.ValidateUsageDescriptionKey("HostUsageKey😀") == "HostUsageKey😀",
    "A checked usage description key preserves its exact spelling.");
const string replacementKey = "Host\uFFFD";
const string unpairedHighKey = "Host\uD800";
const string unpairedLowKey = "Host\uDC00";
Check(PermissionContract.ValidateUsageDescriptionKey(replacementKey) == replacementKey,
    "A literal replacement character is part of a valid key.");
Rejected(() => PermissionContract.ValidateUsageDescriptionKey(unpairedHighKey), "invalidJson");
Rejected(() => PermissionContract.ValidateUsageDescriptionKey(unpairedLowKey), "invalidJson");
Rejected(() => PermissionContract.ValidateUsageDescriptionKey("Host\nUsageKey"), "invalidDescriptor");
var custom = new PermissionDescriptor("com.example.privacy", Custom: new CustomPermission(new(true, true, "example:settings", false), ["NSCameraUsageDescription", hostKey, composedKey, hostKey, decomposedKey]));
string[] expectedKeys = ["NSCameraUsageDescription", hostKey, composedKey, decomposedKey];
var validatedCustom = PermissionContract.Validate(custom);
Check(validatedCustom.Custom!.UsageDescriptionKeys.SequenceEqual(expectedKeys, StringComparer.Ordinal),
    "The native round trip keeps the first occurrence of each exact key.");
var independentCustom = PermissionContract.Validate(custom);
Check(validatedCustom == independentCustom && new HashSet<PermissionDescriptor> { validatedCustom }.Contains(independentCustom),
    "Independent native round trips must yield equal descriptor values and hash keys.");
var orderedCustom = validatedCustom.Custom!;
var reorderedCustom = validatedCustom with
{
    Custom = orderedCustom with { UsageDescriptionKeys = expectedKeys.Reverse().ToArray() }
};
Check(validatedCustom.HasSameIdentity(reorderedCustom) && validatedCustom != reorderedCustom,
    "Descriptor identity must be independent of the ordered metadata value.");
using (var store = new PermissionStore())
{
    Check(store.Track([validatedCustom, independentCustom]).Values.Count == 1,
        "Equivalent native descriptors must share one tracked entry.");
    Rejected(() => store.Track([validatedCustom, reorderedCustom]), "inconsistentMetadata");
    var malformed = custom with
    {
        Id = "com.example.invalid",
        Custom = orderedCustom with { UsageDescriptionKeys = [replacementKey, unpairedHighKey] }
    };
    Rejected(() => store.Track([camera, malformed]), "invalidJson");
    Check(store.Snapshot.Values.Single().Permission == validatedCustom,
        "Malformed Unicode must leave the tracked permission set unchanged.");
}
{
    var literal = custom with
    {
        Custom = orderedCustom with { Capability = orderedCustom.Capability with { SystemSettingsURL = "example:é" } }
    };
    var decomposed = literal with
    {
        Custom = orderedCustom with { Capability = orderedCustom.Capability with { SystemSettingsURL = "example:e\u0301" } }
    };
    var capability = PermissionContract.Metadata(literal, PermissionPlatform.MacOS).Capability;
    var equivalent = PermissionContract.Metadata(literal, PermissionPlatform.MacOS).Capability;
    Check(capability.SystemSettingsURL == "example:é" && capability == equivalent &&
        new HashSet<PermissionCapability> { capability }.Contains(equivalent),
        "Settings destination round trips must retain the original text and value.");
    Check(literal.HasSameIdentity(decomposed) &&
        capability != PermissionContract.Metadata(decomposed, PermissionPlatform.MacOS).Capability,
        "Canonically equivalent Settings text remains distinct managed metadata for the same identity.");
}
Check(PermissionDescriptor.Automation("com.apple.TextEdit").HasSameIdentity(PermissionDescriptor.Automation("com.apple.TextEdit")) &&
    !PermissionDescriptor.Automation("com.apple.TextEdit").HasSameIdentity(PermissionDescriptor.Automation("com.apple.Notes")),
    "Automation target applications are part of identity.");
string[] constructorKeys = [hostKey];
string[] assignedKeys = [decomposedKey];
var ownedCustom = new CustomPermission(orderedCustom.Capability, constructorKeys);
var copiedCustom = ownedCustom with { UsageDescriptionKeys = assignedKeys };
var ownedSet = new HashSet<CustomPermission> { ownedCustom, copiedCustom };
constructorKeys[0] = composedKey;
assignedKeys[0] = composedKey;
Check(ownedSet.Contains(new CustomPermission(orderedCustom.Capability, [hostKey])) &&
    ownedSet.Contains(new CustomPermission(orderedCustom.Capability, [decomposedKey])) &&
    !ownedSet.Contains(new CustomPermission(orderedCustom.Capability, [composedKey])),
    "Construction and with-assignment must snapshot exact keys for equality and hashing.");
Check(orderedCustom != orderedCustom with { Capability = orderedCustom.Capability with { SupportsRequest = false } },
    "Capability is part of a custom permission's metadata value.");
Check(PermissionContract.Metadata(custom, PermissionPlatform.Windows).UsageDescriptionKeys.SequenceEqual(expectedKeys, StringComparer.Ordinal),
    "Platform metadata projects the exact host keys into managed values.");
using (var store = new PermissionStore())
{
    var checker = new DeferredChecker { ImmediateResult = () => granted };
    var tracked = store.Track([custom]).Values.Single().Permission;
    _ = await store.RefreshAllAsync(checker);
    Check(checker.LastPermission == tracked, "Batch refresh must dispatch the Rust-canonical tracked descriptor.");
    _ = await store.RefreshAsync(checker, custom);
    Check(checker.LastPermission == tracked, "Scoped refresh must dispatch the Rust-canonical tracked descriptor.");
    _ = await store.RequestAsync(checker, custom);
    Check(checker.LastPermission == tracked && checker.RequestCount == 1,
        "Scoped request must dispatch the Rust-canonical tracked descriptor.");

    using var cancellation = new CancellationTokenSource();
    var cancelledChecker = new DeferredChecker { ImmediateResult = () => granted };
    int serializations = 0;
    onDescriptorSerialization = () =>
    {
        // The first serialization admits the request. The second validates the callback input.
        if (++serializations == 2) cancellation.Cancel();
    };
    try
    {
        await Cancelled(store.RequestAsync(cancelledChecker, custom, cancellationToken: cancellation.Token));
        Check(cancelledChecker.RequestCount == 0, "Cancellation during descriptor validation must prevent the callback.");
    }
    finally
    {
        onDescriptorSerialization = null;
    }
    _ = await store.RefreshAsync(cancelledChecker, custom);
    Check(cancelledChecker.LastPermission == tracked, "A cancelled request must release the scope for refresh.");
}
Rejected(() => PermissionContract.Validate(custom with
{
    Custom = custom.Custom! with { UsageDescriptionKeys = Enumerable.Repeat(hostKey, 65).ToArray() }
}), "limitExceeded");

using (var store = new PermissionStore())
{
    Check(store.Track([camera]).Values.Single() == new PermissionValue(camera, unknown), "Track projects a typed snapshot.");
    Check(store.Get(camera) == unknown && store.Get(PermissionDescriptor.Contacts) is null, "Unknown and untracked differ.");
    ulong token = store.Begin(camera)!.Value;
    Check(store.Apply([new(camera, token, denied)]).Accepted == 1 && store.Get(camera) == denied,
        "Explicit ordering bridges the token, result and accepted count.");
    Check(store.Apply([new(camera, token, granted)], cancelled: true).Accepted == 0 && store.Get(camera) == denied,
        "The managed cancellation flag must reach the native transaction.");
    Rejected(() => store.Apply([new(camera, 0, granted)]), "invalidToken");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var checker = new DeferredChecker();
    using var cancellation = new CancellationTokenSource();
    var cancelled = store.RefreshAsync(checker, camera, cancellationToken: cancellation.Token);
    cancellation.Cancel();
    await Cancelled(cancelled);
    checker.Complete(0, granted);
    Check(store.Get(camera) == unknown, "Late cancellation completion must not write.");
    var first = store.RefreshAsync(checker, camera);
    var second = store.RefreshAsync(checker, camera);
    checker.Complete(2, denied); await second;
    checker.Complete(1, granted); var staleReturn = await first;
    Check(staleReturn == denied, "Stale work returns current stored result, not its own completion.");
    Check(store.Get(camera) == denied, "Out-of-order adapter completions must use Rust begin/apply.");
    Check(checker.RequestCount == 0, "Refresh must never request.");
    var request = store.RequestAsync(checker, camera);
    checker.Complete(3, granted); await request;
    Check(store.Get(camera) == granted && checker.RequestCount == 1, "Explicit request updates through the same token boundary.");
    var older = store.RefreshAsync(checker, camera);
    using var recentCancellation = new CancellationTokenSource();
    var recent = store.RefreshAsync(checker, camera, cancellationToken: recentCancellation.Token);
    recentCancellation.Cancel(); await Cancelled(recent);
    checker.Complete(5, denied);
    checker.Complete(4, denied);
    Check(await older == granted && store.Get(camera) == granted, "A recent cancelled begin still suppresses older work.");
    int callbacks = checker.CallbackCount;
    try { await store.RequestAsync(checker, PermissionDescriptor.Contacts); throw new System.Diagnostics.UnreachableException("Untracked request must fail."); }
    catch (InvalidOperationException) { }
    Check(checker.CallbackCount == callbacks && checker.RequestCount == 1, "Untracked requests must not invoke providers.");
}

using (var store = new PermissionStore())
{
    var microphone = PermissionDescriptor.Microphone;
    store.Track([camera, microphone]);
    var checker = new DeferredChecker();
    var request = store.RequestAsync(checker, camera);
    Check(await store.RefreshAsync(checker, camera).WaitAsync(TimeSpan.FromSeconds(5)) == unknown,
        "Refresh during an explicit request must return stored status.");
    Check(checker.CallbackCount == 1, "Suppressed refresh must not invoke the checker.");
    var otherScope = store.RefreshAsync(checker, microphone);
    checker.Complete(1, denied);
    Check(await otherScope == denied, "An explicit request must not suppress another scope.");
    int callbacks = checker.CallbackCount;
    try { await store.RefreshAsync(checker, PermissionDescriptor.Contacts); throw new System.Diagnostics.UnreachableException("Untracked refresh must fail."); }
    catch (InvalidOperationException) { }
    Check(checker.CallbackCount == callbacks, "Untracked refresh must not be confused with suppression.");
    checker.Complete(0, granted);
    Check(await request == granted, "Suppressed refresh must not supersede the requested grant.");
    var afterRequest = store.RefreshAsync(checker, camera);
    checker.Complete(2, denied);
    Check(await afterRequest == denied, "Finishing a request must allow later refreshes.");
}

using (var store = new PermissionStore())
{
    var microphone = PermissionDescriptor.Microphone;
    store.Track([camera, microphone]);
    var checker = new DeferredChecker();
    var batch = store.RefreshAllAsync(checker);
    Check(checker.CallbackCount == 2 && checker.RequestCount == 0, "A batch checks all tracked scopes without requesting.");
    checker.Complete(0, granted);
    Check(store.Get(camera) == unknown, "A partial batch must not change any stored result.");
    checker.Complete(1, denied);
    var snapshot = await batch;
    Check(snapshot.Values.SequenceEqual([new PermissionValue(camera, granted), new PermissionValue(microphone, denied)]),
        "A completed batch returns the resulting Rust snapshot in tracking order.");

    var request = store.RequestAsync(checker, camera);
    batch = store.RefreshAllAsync(checker);
    Check(checker.CallbackCount == 4, "A batch skips a scope with a pending request.");
    checker.Complete(3, granted);
    snapshot = await batch;
    Check(snapshot.Values.All(value => value.Result == granted), "A batch leaves the requested scope intact and refreshes other scopes.");
    checker.Complete(2, denied);
    Check(await request == denied, "A batch must not supersede a pending request.");

    batch = store.RefreshAllAsync(checker);
    var newer = store.RefreshAsync(checker, camera);
    checker.Complete(6, denied);
    _ = await newer;
    checker.Complete(4, granted);
    checker.Complete(5, denied);
    snapshot = await batch;
    Check(snapshot.Values.All(value => value.Result == denied), "Only current tokens in a batch can change its resulting snapshot.");
}

using (var store = new PermissionStore())
{
    var microphone = PermissionDescriptor.Microphone;
    store.Track([camera, microphone]);
    using var cancellation = new CancellationTokenSource();
    var checker = new DeferredChecker();
    var batch = store.RefreshAllAsync(checker, cancellation.Token);
    checker.Complete(0, granted);
    cancellation.Cancel();
    await Cancelled(batch.WaitAsync(TimeSpan.FromSeconds(5)));
    checker.Complete(1, denied);
    Check(store.Snapshot.Values.All(value => value.Result == unknown), "A cancelled batch must discard every result.");

    batch = store.RefreshAllAsync(checker);
    checker.Complete(2, granted);
    checker.Complete(3, new PermissionOperationResult("invented"));
    await RejectedAsync(batch);
    Check(store.Snapshot.Values.All(value => value.Result == unknown), "A rejected batch must discard every result.");

    var statusOnly = new StatusOnlyChecker(granted);
    Check((await store.RefreshAllAsync(statusOnly)).Values.All(value => value.Result == granted),
        "A status-only provider can refresh tracked permissions after a rejected batch.");
    Check(await store.RefreshAsync(statusOnly, camera) == granted, "A single refresh accepts a status-only provider.");
}

using (var store = new PermissionStore())
{
    store.Track([custom]);
    var checker = new DeferredChecker();
    var request = store.RequestAsync(checker, custom);
    var conflicting = custom with { Custom = custom.Custom! with { UsageDescriptionKeys = ["ChangedFixture"] } };
    await RejectedAsync(store.RefreshAsync(checker, conflicting));
    await RejectedAsync(store.RefreshAsync(checker, new PermissionDescriptor("automation")));
    Check(await store.RefreshAsync(checker, custom).WaitAsync(TimeSpan.FromSeconds(5)) == unknown,
        "Rejected descriptors must not clear a pending request.");
    Check(checker.CallbackCount == 1, "Descriptor and metadata validation must precede suppression and checker calls.");
    checker.Complete(0, granted);
    Check(await request == granted, "Invalid refresh input must not supersede a request.");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var checker = new DeferredChecker();
    var earlier = store.RequestAsync(checker, camera);
    var later = store.RequestAsync(checker, camera);
    checker.Complete(0, denied);
    Check(await earlier == unknown, "An older request must not publish over a newer request.");
    Check(await store.RefreshAsync(checker, camera).WaitAsync(TimeSpan.FromSeconds(5)) == unknown,
        "An older request's cleanup must not clear a newer request's admission.");
    Check(checker.CallbackCount == 2, "Stale cleanup must leave the newer request protected from refresh.");
    checker.Complete(1, granted);
    Check(await later == granted, "Latest request must retain its result.");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var checker = new DeferredChecker();
    var older = store.RefreshAsync(checker, camera);
    using var cancellation = new CancellationTokenSource();
    var request = store.RequestAsync(checker, camera, cancellationToken: cancellation.Token);
    cancellation.Cancel();
    await Cancelled(request);
    checker.Complete(0, granted);
    Check(await older == unknown, "Cancelling a request must not restore an older refresh token.");
    var afterCancellation = store.RefreshAsync(checker, camera);
    Check(checker.CallbackCount == 3, "Cancelled request cleanup must allow another refresh.");
    checker.Complete(2, denied);
    Check(await afterCancellation == denied, "New refresh must publish after request cancellation.");
    checker.Complete(1, granted);
    Check(store.Get(camera) == denied, "Late completion of the cancelled checker must not publish.");
}

foreach (var invalidResult in new[] { false, true })
{
    using var store = new PermissionStore();
    store.Track([camera]);
    var checker = new DeferredChecker();
    var older = store.RefreshAsync(checker, camera);
    var request = store.RequestAsync(checker, camera);
    if (invalidResult)
    {
        checker.Complete(1, new PermissionOperationResult("invented"));
        await RejectedAsync(request);
    }
    else
    {
        checker.Fail(1, new InvalidOperationException("Fixture checker failure."));
        try { await request; throw new System.Diagnostics.UnreachableException("Checker failure must propagate."); }
        catch (InvalidOperationException) { }
    }
    checker.Complete(0, granted);
    Check(await older == unknown, "Failed request cleanup must not restore an older refresh token.");
    var afterFailure = store.RefreshAsync(checker, camera);
    Check(checker.CallbackCount == 3, "Checker and result-validation failures must retire request admission.");
    checker.Complete(2, denied);
    Check(await afterFailure == denied, "A refresh must recover after a failed request.");
}

using (var store = new PermissionStore())
{
    using var cancellation = new CancellationTokenSource();
    var permission = PermissionDescriptor.Camera;
    store.Track([permission]);
    int callbacks = 0;
    var checker = new DeferredChecker
    {
        ImmediateResult = () =>
        {
            onUpdateSerialization = () => { callbacks++; cancellation.Cancel(); };
            return granted;
        }
    };
    PermissionOperationResult? delivered = null;
    try { delivered = await store.RequestAsync(checker, permission, cancellationToken: cancellation.Token); }
    catch (OperationCanceledException) { }
    Check(callbacks == 1 && cancellation.IsCancellationRequested, "Fixture must cancel during apply serialization.");
    Check(store.Get(permission) == granted, "Cancellation after apply entry must not undo the committed result.");
    Check(delivered == granted, "A committed result must not be reported as cancellation.");
    checker.ImmediateResult = null;
    var afterRequest = store.RefreshAsync(checker, permission);
    Check(checker.CallbackCount == 1, "Late cancellation must still retire request admission.");
    checker.Complete(0, denied);
    Check(await afterRequest == denied, "Refresh must proceed after the committed request finishes.");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var checker = new DeferredChecker();
    var request = store.RequestAsync(checker, camera);
    store.Dispose();
    checker.Complete(0, granted);
    try { await request; throw new System.Diagnostics.UnreachableException("Disposed store must reject the late result."); }
    catch (ObjectDisposedException) { }
}

using (var store = new PermissionStore())
{
    var photos = PermissionDescriptor.Photos;
    store.Track([photos]);
    var checker = new DeferredChecker();
    var addOnly = PermissionOptions.Photos(PhotoAccessLevel.AddOnly);
    var readWrite = store.RefreshAsync(checker, photos);

    var scopedRequest = store.RequestAsync(checker, photos, addOnly);
    checker.Complete(1, granted);
    Check(await scopedRequest == granted && store.Get(photos) == unknown,
        "An add-only request returns its grant without publishing read/write access.");

    var scopedRefresh = store.RefreshAsync(checker, photos, addOnly);
    checker.Complete(2, granted);
    Check(await scopedRefresh == granted && store.Get(photos) == unknown,
        "An add-only status check leaves stored read/write access unchanged.");

    checker.Complete(0, denied);
    Check(await readWrite == denied && store.Get(photos) == denied,
        "Add-only operations must not supersede a pending read/write refresh.");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var checker = new DeferredChecker();
    var valid = store.RefreshAsync(checker, camera);
    var wrongOptions = PermissionOptions.Photos(PhotoAccessLevel.AddOnly);
    var expected = PermissionOperationResult.Failed(PermissionError.InvalidOptions);
    int invalidCalls = 0;
    checker.ImmediateResult = () => { invalidCalls++; return granted; };
    Check(await store.RefreshAsync(checker, camera, wrongOptions) == expected, "The store must reject mismatched refresh options.");
    Check(await store.RequestAsync(checker, camera, wrongOptions) == expected, "The store must reject mismatched request options.");
    Check(invalidCalls == 0 && store.Get(camera) == unknown, "Invalid options must neither invoke providers nor publish state.");
    checker.Complete(0, denied);
    Check(await valid == denied && store.Get(camera) == denied, "Invalid options must not supersede a valid refresh.");
}

using (var store = new PermissionStore())
{
    store.Track([camera]);
    var tokens = new System.Collections.Concurrent.ConcurrentBag<ulong>();
    Parallel.For(0, 32, _ => tokens.Add(store.Begin(camera)!.Value));
    Check(tokens.Distinct().Count() == 32, "Adapter locks must serialize each native store.");
    Check(store.Apply(tokens.Select(t => new PermissionUpdate(camera, t, granted)).Take(1)).Accepted <= 1, "Concurrent store remains valid.");
}
var environment = new RecordingEnvironment();
var managed = new PermissionChecker(environment);
var invalidOptions = await managed.RequestAsync(camera, PermissionOptions.Photos(PhotoAccessLevel.ReadWrite));
Check(invalidOptions.Error == PermissionError.InvalidOptions && environment.Calls == 0, "Rust option validation precedes effects.");
var unsupported = await managed.RequestAsync(PermissionDescriptor.Accessibility);
Check(unsupported.Kind == "unsupported" && environment.Calls == 0, "Metadata prevents unsupported effects.");
var checkerWithUnreachablePlatform = new PermissionChecker(new UnreachablePermissionEnvironment());
foreach (var options in new[] {
    PermissionOptions.Photos(PhotoAccessLevel.AddOnly),
    new PermissionOptions("none", NotificationOptions: 1),
    new PermissionOptions("\ud800"),
})
{
    Check(await checkerWithUnreachablePlatform.StatusAsync(camera, options) == PermissionOperationResult.Failed(PermissionError.InvalidOptions),
        "Invalid options must be rejected before the host platform is read.");
}
try
{
    await checkerWithUnreachablePlatform.RequestAsync(
        PermissionDescriptor.Automation("invalid target"), new PermissionOptions("\ud800"));
    throw new System.Diagnostics.UnreachableException("Malformed descriptor was accepted.");
}
catch (PermissionContractException error) when (error.Error == "invalidTargetApplication") { }
var macEnvironment = new RecordingEnvironment { Platform = PermissionPlatform.MacOS };
var macChecker = new PermissionChecker(macEnvironment);
_ = await macChecker.RequestAsync(PermissionDescriptor.Notifications);
Check(macEnvironment.LastOptions == PermissionContract.Metadata(PermissionDescriptor.Notifications, PermissionPlatform.MacOS).DefaultOptions,
    "Omitted options use the shared default for the selected platform.");
_ = await macChecker.RequestAsync(PermissionDescriptor.Notifications, PermissionOptions.None);
Check(macEnvironment.LastOptions == PermissionOptions.None, "Explicit options retain their validated wire value.");
var everyNotificationBit = PermissionOptions.Notifications((NotificationRequestOptions)ulong.MaxValue);
_ = await macChecker.StatusAsync(PermissionDescriptor.Notifications, everyNotificationBit);
Check(macEnvironment.LastOptions == everyNotificationBit, "All notification bits must reach the provider after admission.");
using (var store = new PermissionStore())
{
    store.Track([camera]);
    var settings = await managed.OpenSettingsAsync(camera);
    Check(settings.Value == true && store.Get(camera) == unknown, "Settings launch is not permission observation.");
}
var settingsEnvironment = new RecordingEnvironment();
var settingsChecker = new PermissionChecker(settingsEnvironment);
var invalidSettingsOption = PermissionOptions.Photos(PhotoAccessLevel.AddOnly);
foreach (var options in new[] { invalidSettingsOption, new PermissionOptions("none", NotificationOptions: 1), new PermissionOptions("\ud800") })
{
    Check(await settingsChecker.OpenSettingsAsync(camera, options) == PermissionSettingsResult.Failed(PermissionError.InvalidOptions),
        "Settings must reject options before starting effects.");
}
try
{
    await settingsChecker.OpenSettingsAsync(new PermissionDescriptor("automation"), invalidSettingsOption);
    throw new System.Diagnostics.UnreachableException("Invalid Settings descriptors must throw before evaluating options.");
}
catch (PermissionContractException error) when (error.Error == "invalidTargetApplication") { }
Check((await settingsChecker.OpenSettingsAsync(PermissionDescriptor.Accessibility)).Kind == "unsupported" && settingsEnvironment.Calls == 0,
    "Settings must not invoke an effect for an unsupported destination.");
using (var settingsCancellation = new CancellationTokenSource())
{
    settingsCancellation.Cancel();
    await Cancelled(settingsChecker.OpenSettingsAsync(camera, cancellationToken: settingsCancellation.Token));
    Check(settingsEnvironment.Calls == 0, "A cancelled Settings call must not start an effect.");
}
using (var settingsCancellation = new CancellationTokenSource())
{
    settingsEnvironment.SettingsResult = () =>
    {
        settingsCancellation.Cancel();
        return PermissionSettingsResult.Supported(true);
    };
    await Cancelled(settingsChecker.OpenSettingsAsync(camera, cancellationToken: settingsCancellation.Token));
    Check(settingsEnvironment.Calls == 1, "Cancellation after effect entry must discard the acknowledgement.");
}
settingsEnvironment.SettingsResult = () => new PermissionSettingsResult("supported");
await RejectedAsync(settingsChecker.OpenSettingsAsync(camera));
using (var cancelled = new CancellationTokenSource())
{
    cancelled.Cancel();
    await Cancelled(managed.RequestAsync(camera, cancellationToken: cancelled.Token));
    Check(environment.Calls == 1, "Pre-cancelled work must not start native effects.");
}
var context = new QueuedContext();
var dispatcher = new SynchronizationContextPermissionDispatcher(context);
using (var cancelled = new CancellationTokenSource())
{
    int effects = 0;
    Task<int> queued;
    var priorContext = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(context);
    try { queued = dispatcher.InvokeAsync(() => ++effects, cancelled.Token); }
    finally { SynchronizationContext.SetSynchronizationContext(priorContext); }
    Check(context.PendingCount == 1 && !queued.IsCompleted, "Fixture must hold the request on the UI queue.");
    cancelled.Cancel();
    await Cancelled(queued.WaitAsync(TimeSpan.FromSeconds(2)));
    Check(context.PendingCount == 1 && effects == 0, "Cancellation must finish before the UI queue is drained.");
    context.Run();
    Check(effects == 0, "Draining a cancelled UI callback must not start a request.");

    await Cancelled(dispatcher.InvokeAsync(() => ++effects, cancelled.Token).WaitAsync(TimeSpan.FromSeconds(2)));
    Check(context.PendingCount == 0 && effects == 0, "Already-cancelled work must not post to the UI queue.");
}
using (var lateCancellation = new CancellationTokenSource())
{
    var started = dispatcher.InvokeAsync(() =>
    {
        lateCancellation.Cancel();
        return 42UL;
    }, lateCancellation.Token);
    context.Run();
    Check(lateCancellation.IsCancellationRequested && await started.WaitAsync(TimeSpan.FromSeconds(2)) == 42,
        "Once a UI action starts, its native result must remain available for cleanup.");
}
if (OperatingSystem.IsWindows())
{
    var native = new WindowsPermissionEnvironment(new NeverDispatch());
    var result = await native.StatusAsync(camera, PermissionOptions.None, default);
    Check(result == PermissionOperationResult.Failed(PermissionError.ApiUnavailable), "Unpackaged access must not be inferred granted.");
    var request = await native.RequestAsync(camera, PermissionOptions.None, default);
    Check(request == PermissionOperationResult.Unsupported(metadata.Capability), "Direct consent must be unsupported without UI dispatch.");
    Console.WriteLine("Windows unpackaged nonprompting status and unsupported direct request passed.");
}
Console.WriteLine(".NET Rust boundary, metadata, uint64 options, ownership, cancellation and stale-write contracts passed.");

sealed class DeferredChecker : IPermissionChecking
{
    private readonly List<TaskCompletionSource<PermissionOperationResult>> pending = [];
    public Func<PermissionOperationResult>? ImmediateResult;
    public int RequestCount { get; private set; }
    public PermissionDescriptor? LastPermission { get; private set; }
    public int CallbackCount => pending.Count;
    private Task<PermissionOperationResult> Add(PermissionDescriptor permission)
    {
        LastPermission = permission;
        if (ImmediateResult is { } result) return Task.FromResult(result());
        var source = new TaskCompletionSource<PermissionOperationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending.Add(source); return source.Task;
    }
    public void Complete(int index, PermissionOperationResult result) => pending[index].SetResult(result);
    public void Fail(int index, Exception error) => pending[index].SetException(error);
    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default) => Add(permission);
    public Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default) { RequestCount++; return Add(permission); }
    public Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default) => throw new System.Diagnostics.UnreachableException("Unexpected Settings call.");
}
sealed class StatusOnlyChecker(PermissionOperationResult result) : IPermissionStatusChecking
{
    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions? options = null, CancellationToken cancellationToken = default)
        => Task.FromResult(result);
}
sealed class UnreachablePermissionEnvironment : IPermissionEnvironment
{
    public PermissionPlatform Platform => throw new System.Diagnostics.UnreachableException("Invalid input read the host platform.");
    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
        => throw new System.Diagnostics.UnreachableException("Invalid input ran the status provider.");
    public Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
        => throw new System.Diagnostics.UnreachableException("Invalid input ran the request provider.");
    public Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
        => throw new System.Diagnostics.UnreachableException("Invalid input ran the Settings provider.");
}
sealed class RecordingEnvironment : IPermissionEnvironment
{
    public int Calls { get; private set; }
    public PermissionPlatform Platform { get; init; } = PermissionPlatform.Windows;
    public PermissionOptions? LastOptions { get; private set; }
    public Func<PermissionSettingsResult>? SettingsResult { get; set; }
    public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
    {
        Calls++;
        LastOptions = options;
        return Task.FromResult(PermissionOperationResult.Supported(PermissionStatus.Unknown));
    }
    public Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken) => StatusAsync(permission, options, cancellationToken);
    public Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
    {
        Calls++;
        return Task.FromResult(SettingsResult?.Invoke() ?? PermissionSettingsResult.Supported(true));
    }
}
sealed class QueuedContext : SynchronizationContext
{
    private readonly Queue<(SendOrPostCallback Callback, object? State)> actions = new();
    public int PendingCount => actions.Count;
    public override void Post(SendOrPostCallback callback, object? state) => actions.Enqueue((callback, state));
    public void Run() { while (actions.TryDequeue(out var action)) action.Callback(action.State); }
}
sealed class NeverDispatch : IWindowsPermissionDispatcher
{
    public Task<T> InvokeAsync<T>(Func<T> action, CancellationToken cancellationToken) => throw new System.Diagnostics.UnreachableException("Nonprompting fixture attempted UI dispatch.");
}
