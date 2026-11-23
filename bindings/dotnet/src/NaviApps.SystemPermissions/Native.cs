using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

[assembly: InternalsVisibleTo("NaviApps.SystemPermissions.Windows")]
[assembly: InternalsVisibleTo("SystemPermissions.Tests")]

namespace NaviApps.SystemPermissions;

internal sealed class StoreHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    internal StoreHandle() : base(true)
    {
        SetHandle(Native.StoreNew());
        if (IsInvalid) throw new PermissionContractException("Native store allocation failed.");
    }
    protected override bool ReleaseHandle() { Native.StoreFree(handle); return true; }
}

internal static class Native
{
    private const string Library = "system_permissions";
    internal static readonly JsonSerializerOptions Json = CreateOptions();
    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
        };
        options.Converters.Add(new ExactStringConverter());
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }

    private sealed class ExactStringConverter : JsonConverter<string>
    {
        private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

        public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.GetString();

        public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
        {
            // The default JSON encoder replaces unpaired surrogates with a different scalar.
            try { _ = StrictUtf8.GetByteCount(value); }
            catch (EncoderFallbackException)
            {
                throw new PermissionContractException("Permission data contains an unpaired Unicode surrogate.", "invalidJson");
            }
            writer.WriteStringValue(value);
        }
    }

    [DllImport(Library, EntryPoint = "system_permissions_call", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr Dispatch(byte[] data, nuint length);
    [DllImport(Library, EntryPoint = "system_permissions_store_new", CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr StoreNew();
    [DllImport(Library, EntryPoint = "system_permissions_store_free", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void StoreFree(IntPtr handle);
    [DllImport(Library, EntryPoint = "system_permissions_store_call", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr StoreDispatch(StoreHandle handle, byte[] data, nuint length);
    [DllImport(Library, EntryPoint = "system_permissions_result_status", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint Status(IntPtr result);
    [DllImport(Library, EntryPoint = "system_permissions_result_data", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr Data(IntPtr result);
    [DllImport(Library, EntryPoint = "system_permissions_result_len", CallingConvention = CallingConvention.Cdecl)]
    private static extern nuint Length(IntPtr result);
    [DllImport(Library, EntryPoint = "system_permissions_result_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void Free(IntPtr result);

    private static JsonElement Consume(IntPtr owner)
    {
        if (owner == IntPtr.Zero) throw new PermissionContractException("Missing native result.");
        try
        {
            var size = Length(owner);
            var pointer = Data(owner);
            if (pointer == IntPtr.Zero || size > 4 * 1024 * 1024)
                throw new PermissionContractException("Invalid native result buffer.");
            var bytes = new byte[checked((int)size)];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            using var document = JsonDocument.Parse(bytes);
            if (Status(owner) != 0)
            {
                string code = document.RootElement.GetProperty("error").GetString() ?? "invalidResult";
                string? reason = document.RootElement.TryGetProperty("reason", out var value) ? value.GetString() : null;
                throw new PermissionContractException("Native permission contract rejected the call: " + code, code, reason);
            }
            return document.RootElement.Clone();
        }
        finally { Free(owner); }
    }
    internal static JsonElement Call(object command)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(command, Json);
        return Consume(Dispatch(bytes, (nuint)bytes.Length));
    }

    internal static JsonElement DecodeDescriptor(ReadOnlySpan<byte> utf8Json)
    {
        ReadOnlySpan<byte> prefix = """{"op":"validateDescriptor","permission":"""u8;
        if (utf8Json.Length > 1024 * 1024 - prefix.Length - 1)
            throw new PermissionContractException("Permission input exceeds the native JSON limit.", "inputTooLarge");
        // Rust validates the entire closed command, retaining the descriptor's original JSON bytes.
        var bytes = new byte[prefix.Length + utf8Json.Length + 1];
        prefix.CopyTo(bytes);
        utf8Json.CopyTo(bytes.AsSpan(prefix.Length));
        bytes[^1] = (byte)'}';
        return Consume(Dispatch(bytes, (nuint)bytes.Length));
    }

    internal static JsonElement Call(StoreHandle store, object command)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(command, Json);
        return Consume(StoreDispatch(store, bytes, (nuint)bytes.Length));
    }
    internal static T Read<T>(JsonElement value) => value.Deserialize<T>(Json) ?? throw new PermissionContractException("Missing native value.");
}
