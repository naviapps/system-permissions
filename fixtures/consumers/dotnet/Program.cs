using System;
using System.Threading;
using System.Threading.Tasks;
using NaviApps.SystemPermissions;
#if WINDOWS_ADAPTER
using NaviApps.SystemPermissions.Windows;
#endif

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
var checker = new PermissionChecker(new WindowsPermissionEnvironment(new NeverDispatch()));
var request = await checker.RequestAsync(camera);
if (request.Kind != "unsupported" || request.Capability is not { SupportsRequest: false, SystemSettingsURL: "ms-settings:privacy-webcam" })
    throw new Exception("The packaged Windows checker did not report unsupported consent and retain Settings guidance.");
var settings = await checker.OpenSettingsAsync(PermissionDescriptor.Accessibility);
if (settings.Kind != "unsupported")
    throw new Exception("The packaged Windows checker did not apply Settings admission.");
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
