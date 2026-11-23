using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using NaviApps.SystemPermissions;
#if WINDOWS_ADAPTER
using NaviApps.SystemPermissions.Windows;
#endif

AppContext.SetSwitch("System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault", false);
if (JsonSerializer.IsReflectionEnabledByDefault)
    throw new Exception("The package fixture requires reflection-based JSON serialization to be disabled.");

var camera = PermissionContract.DecodeDescriptorJson("{\"id\":\"camera\"}"u8);
if (camera != PermissionDescriptor.Camera ||
    !PermissionContract.Metadata(camera, PermissionPlatform.Windows).Capability.SupportsStatusCheck)
    throw new Exception("The packaged native contract did not load.");
using var store = new PermissionStore();
store.Track([camera]);
var token = store.Begin(camera) ?? throw new Exception("Native store admission failed.");
store.Apply([new PermissionUpdate(camera, token, PermissionOperationResult.Supported(PermissionStatus.Denied))]);
if (store.Get(camera)?.Value != PermissionStatus.Denied)
    throw new Exception("The packaged native store did not retain its result.");
#if WINDOWS_ADAPTER
var environment = new WindowsPermissionEnvironment(new NeverDispatch());
var checker = new PermissionChecker(environment);
var request = await checker.RequestAsync(camera);
if (request.Kind != "unsupported" || request.Capability is not { SupportsRequest: false, SystemSettingsURL: "ms-settings:privacy-webcam" })
    throw new Exception("The packaged Windows checker did not report unsupported consent and retain Settings guidance.");
var settings = await checker.OpenSettingsAsync(PermissionDescriptor.Accessibility);
if (settings.Kind != "unsupported")
    throw new Exception("The packaged Windows checker did not apply Settings admission.");
if (OperatingSystem.IsWindows())
{
    var status = await environment.StatusAsync(camera, PermissionOptions.None, default);
    if (status != PermissionOperationResult.Failed(PermissionError.ApiUnavailable))
        throw new Exception("The unpackaged Windows adapter did not report unavailable status.");
    var directRequest = await environment.RequestAsync(camera, PermissionOptions.None, default);
    if (directRequest != request)
        throw new Exception("The native Windows adapter changed the unsupported request result.");
}
Console.WriteLine("Clean NuGet consumer loaded the packaged native code and Windows adapter.");
#else
Console.WriteLine("Clean NuGet consumer loaded the packaged native code.");
#endif

#if WINDOWS_ADAPTER
sealed class NeverDispatch : IWindowsPermissionDispatcher
{
    public Task<T> InvokeAsync<T>(Func<T> action, CancellationToken token) =>
        throw new Exception("The package fixture must not dispatch native effects.");
}
#endif
