using System.Diagnostics;
using NaviApps.SystemPermissions;

internal static class PermissionCheckerCancellationTests
{
    internal static async Task RunAsync()
    {
        foreach (var request in new[] { false, true })
        {
            using var cancellation = new CancellationTokenSource();
            var checker = new PermissionChecker(new CancellingEnvironment(cancellation));
            try
            {
                if (request)
                    await checker.RequestAsync(PermissionDescriptor.Camera, cancellationToken: cancellation.Token);
                else
                    await checker.StatusAsync(PermissionDescriptor.Camera, cancellationToken: cancellation.Token);
            }
            catch (OperationCanceledException error) when (error.CancellationToken == cancellation.Token)
            {
                continue;
            }
            throw new UnreachableException("Cancellation during admission must prevent the permission effect.");
        }
    }

    private sealed class CancellingEnvironment(CancellationTokenSource cancellation) : IPermissionEnvironment
    {
        public PermissionPlatform Platform
        {
            get
            {
                cancellation.Cancel();
                return PermissionPlatform.Windows;
            }
        }

        public Task<PermissionOperationResult> StatusAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
            => throw new UnreachableException("Status must not start after cancellation.");

        public Task<PermissionOperationResult> RequestAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
            => throw new UnreachableException("Request must not start after cancellation.");

        public Task<PermissionSettingsResult> OpenSettingsAsync(PermissionDescriptor permission, PermissionOptions options, CancellationToken cancellationToken)
            => throw new UnreachableException("The checker must not open Settings while checking access.");
    }
}
