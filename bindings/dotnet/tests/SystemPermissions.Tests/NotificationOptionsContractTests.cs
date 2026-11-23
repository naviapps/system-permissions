using System.Text.Json;
using NaviApps.SystemPermissions;

internal static class NotificationOptionsContractTests
{
    internal static void Run()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "notification-options.json")));
        var root = fixture.RootElement;
        var named = root.GetProperty("namedOptions");
        foreach (var item in named.EnumerateArray())
        {
            string name = item.GetProperty("name").GetString()!;
            var option = Enum.Parse<NotificationRequestOptions>(name, ignoreCase: true);
            CheckWire(option, item.GetProperty("rawValue").GetUInt64());
        }
        Check(named.GetArrayLength() == Enum.GetNames<NotificationRequestOptions>().Length, "Named option coverage drift.");
        foreach (var item in root.GetProperty("combinations").EnumerateArray())
        {
            NotificationRequestOptions options = 0;
            foreach (var name in item.GetProperty("names").EnumerateArray())
                options |= Enum.Parse<NotificationRequestOptions>(name.GetString()!, ignoreCase: true);
            CheckWire(options, item.GetProperty("rawValue").GetUInt64());
        }
        foreach (var mask in root.GetProperty("rawMasks").EnumerateArray())
        {
            ulong value = mask.GetUInt64();
            CheckWire((NotificationRequestOptions)value, value);
        }
    }

    private static void CheckWire(NotificationRequestOptions options, ulong expected)
    {
        var payload = JsonSerializer.SerializeToElement(PermissionOptions.Notifications(options), Native.TypeInfo<PermissionOptions>());
        Check(payload.GetProperty("kind").GetString() == "notifications", "Notification option kind drift.");
        ulong actual = payload.GetProperty("notificationOptions").GetUInt64();
        Check(actual == expected, $"Notification mask drift: expected {expected}, received {actual}.");
        Check(Native.Read<PermissionOptions>(payload).NotificationOptions == expected, "Raw mask round trip drift.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new System.Diagnostics.UnreachableException(message);
    }
}
