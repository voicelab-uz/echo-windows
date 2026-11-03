using System.Collections.Concurrent;
using System.Text.Json;
using System.Security.Cryptography;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VoiceLab.Infrastructure.Storage;

/// <summary>Atomic, account-scoped local data protected by Windows DPAPI.</summary>
public sealed class JsonDataStore
{
    private static readonly byte[] EncryptedHeader = "VLE1"u8.ToArray();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Locks = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _root;
    private string? _accountDirectory;

    public JsonDataStore()
        : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoiceLab", "Echo"))
    {
    }

    public JsonDataStore(string root)
    {
        _root = root;
        Directory.CreateDirectory(_root);
    }

    public async Task<List<T>> ReadListAsync<T>(string name, CancellationToken cancellationToken = default,
        string? expectedAccountScope = null)
    {
        var path = GetPath(name, expectedAccountScope);
        var gate = Locks.GetOrAdd(path, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(path)) return new List<T>();
            var bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
            if (bytes.AsSpan().StartsWith(EncryptedHeader))
            {
                var plaintext = Unprotect(bytes.AsSpan(EncryptedHeader.Length).ToArray(), Entropy(path));
                try { return JsonSerializer.Deserialize<List<T>>(WithoutUtf8Bom(plaintext), JsonOptions) ?? []; }
                finally { CryptographicOperations.ZeroMemory(plaintext); }
            }
            // Files written by earlier Windows previews were plain JSON. Migrate only
            // after a successful parse; the atomic replacement preserves the old file
            // if encryption or writing fails.
            try
            {
                var legacy = JsonSerializer.Deserialize<List<T>>(WithoutUtf8Bom(bytes), JsonOptions) ?? [];
                await WriteEncryptedAsync(path, bytes, cancellationToken).ConfigureAwait(false);
                return legacy;
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { gate.Release(); }
    }

    public async Task WriteListAsync<T>(string name, IReadOnlyCollection<T> items, CancellationToken cancellationToken = default,
        string? expectedAccountScope = null)
    {
        var path = GetPath(name, expectedAccountScope);
        var gate = Locks.GetOrAdd(path, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(items, JsonOptions);
            try { await WriteEncryptedAsync(path, bytes, cancellationToken).ConfigureAwait(false); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { gate.Release(); }
    }

    public string RootDirectory => _root;
    public string CurrentAccountScope => _accountDirectory ?? throw new InvalidOperationException("Sign in before accessing VoiceLab data.");

    public T? ReadGlobalObject<T>(string name)
    {
        var path = GetGlobalPath(name);
        if (!File.Exists(path)) return default;
        var bytes = File.ReadAllBytes(path);
        if (bytes.AsSpan().StartsWith(EncryptedHeader))
        {
            var plaintext = Unprotect(bytes.AsSpan(EncryptedHeader.Length).ToArray(), Entropy(path));
            try { return JsonSerializer.Deserialize<T>(WithoutUtf8Bom(plaintext), JsonOptions); }
            finally { CryptographicOperations.ZeroMemory(plaintext); }
        }
        try
        {
            var legacy = JsonSerializer.Deserialize<T>(WithoutUtf8Bom(bytes), JsonOptions);
            if (legacy is not null) WriteGlobalObject(name, legacy);
            return legacy;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public void WriteGlobalObject<T>(string name, T value)
    {
        var path = GetGlobalPath(name);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        var tempPath = path + ".tmp";
        try
        {
            var encrypted = Protect(plaintext, Entropy(path));
            using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(EncryptedHeader);
                stream.Write(encrypted);
                stream.Flush(flushToDisk: true);
            }
            File.Move(tempPath, path, true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (File.Exists(tempPath)) File.Delete(tempPath);
        }
    }

    public void SetAccountId(string? accountId)
    {
        if (string.IsNullOrWhiteSpace(accountId)) { _accountDirectory = null; return; }
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(accountId));
        var directory = Path.Combine(_root, "accounts", Convert.ToHexString(digest).ToLowerInvariant());
        Directory.CreateDirectory(directory);
        _accountDirectory = directory;
    }

    private string GetPath(string name, string? expectedAccountScope)
    {
        ValidateName(name);
        var directory = _accountDirectory ?? throw new InvalidOperationException("Sign in before accessing VoiceLab data.");
        if (expectedAccountScope is not null &&
            !string.Equals(directory, expectedAccountScope, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The VoiceLab account changed before local data could be accessed.");
        return Path.Combine(directory, name + ".json");
    }

    private string GetGlobalPath(string name)
    {
        ValidateName(name);
        return Path.Combine(_root, name + ".json");
    }

    private static ReadOnlySpan<byte> WithoutUtf8Bom(byte[] bytes) =>
        bytes.AsSpan().StartsWith("\uFEFF"u8) ? bytes.AsSpan(3) : bytes;

    private static void ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("Invalid data store name.", nameof(name));
    }

    private static async Task WriteEncryptedAsync(string path, byte[] plaintext, CancellationToken cancellationToken)
    {
        var encrypted = Protect(plaintext, Entropy(path));
        var tempPath = path + ".tmp";
        try
        {
            await using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 4096, true))
            {
                await stream.WriteAsync(EncryptedHeader, cancellationToken).ConfigureAwait(false);
                await stream.WriteAsync(encrypted, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            File.Move(tempPath, path, true);
        }
        finally { if (File.Exists(tempPath)) File.Delete(tempPath); }
    }

    private static byte[] Entropy(string path) => SHA256.HashData(Encoding.UTF8.GetBytes(
        "VoiceLab Echo account data v1/" + Path.GetFileName(Path.GetDirectoryName(path)) + "/" + Path.GetFileName(path)));

    private static byte[] Protect(byte[] data, byte[] entropy) => Transform(data, entropy, encrypt: true);
    private static byte[] Unprotect(byte[] data, byte[] entropy) => Transform(data, entropy, encrypt: false);

    private static byte[] Transform(byte[] data, byte[] entropy, bool encrypt)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Echo account storage requires Windows.");
        var input = new DataBlob { Size = data.Length, Data = Marshal.AllocHGlobal(data.Length) };
        var extra = new DataBlob { Size = entropy.Length, Data = Marshal.AllocHGlobal(entropy.Length) };
        DataBlob output = default;
        try
        {
            Marshal.Copy(data, 0, input.Data, data.Length);
            Marshal.Copy(entropy, 0, extra.Data, entropy.Length);
            var success = encrypt
                ? CryptProtectData(ref input, null, ref extra, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, ref extra, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(),
                encrypt ? "Windows could not protect Echo account data." : "Windows could not open Echo account data.");
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        finally
        {
            if (output.Data != IntPtr.Zero) LocalFree(output.Data);
            ZeroAndFree(input);
            ZeroAndFree(extra);
        }
    }

    private static void ZeroAndFree(DataBlob blob)
    {
        if (blob.Data == IntPtr.Zero) return;
        var zeros = new byte[4096];
        for (var offset = 0; offset < blob.Size; offset += zeros.Length)
            Marshal.Copy(zeros, 0, IntPtr.Add(blob.Data, offset), Math.Min(zeros.Length, blob.Size - offset));
        Marshal.FreeHGlobal(blob.Data);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
