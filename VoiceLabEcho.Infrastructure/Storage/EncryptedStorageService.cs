using System.Text;
using System.Text.Json;
using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Infrastructure.Security;

namespace VoiceLabEcho.Infrastructure.Storage;

public class EncryptedStorageService : IStorageService
{
    private readonly IEncryptionProvider _encryptionProvider;
    private readonly ICredentialManager _credentialManager;
    private readonly string _storageBasePath;
    private byte[]? _encryptionKey;
    private string? _currentAccountId;

    public EncryptedStorageService(
        IEncryptionProvider encryptionProvider,
        ICredentialManager credentialManager)
    {
        _encryptionProvider = encryptionProvider;
        _credentialManager = credentialManager;

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _storageBasePath = Path.Combine(appData, "VoiceLabEcho");

        Directory.CreateDirectory(_storageBasePath);
    }

    public async Task InitializeForAccountAsync(string accountId)
    {
        _currentAccountId = accountId;

        // Try to load existing encryption key
        var keyBase64 = await _credentialManager.GetCredentialAsync($"EncryptionKey:{accountId}");

        if (keyBase64 != null)
        {
            _encryptionKey = Convert.FromBase64String(keyBase64);
        }
        else
        {
            // Generate new encryption key
            _encryptionKey = _encryptionProvider.GenerateKey();
            var newKeyBase64 = Convert.ToBase64String(_encryptionKey);
            await _credentialManager.SaveCredentialAsync($"EncryptionKey:{accountId}", newKeyBase64);
        }
    }

    public async Task<T?> LoadAsync<T>(string key) where T : class
    {
        EnsureInitialized();

        var filePath = GetFilePath(key);

        if (!File.Exists(filePath))
            return null;

        try
        {
            var encryptedData = await File.ReadAllBytesAsync(filePath);
            var decryptedData = _encryptionProvider.Decrypt(encryptedData, _encryptionKey!);
            var json = Encoding.UTF8.GetString(decryptedData);

            return JsonSerializer.Deserialize<T>(json);
        }
        catch
        {
            return null;
        }
    }

    public async Task SaveAsync<T>(string key, T data) where T : class
    {
        EnsureInitialized();

        var filePath = GetFilePath(key);
        var directory = Path.GetDirectoryName(filePath);

        if (!string.IsNullOrEmpty(directory))
            Directory.CreateDirectory(directory);

        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions
        {
            WriteIndented = false
        });

        var plainData = Encoding.UTF8.GetBytes(json);
        var encryptedData = _encryptionProvider.Encrypt(plainData, _encryptionKey!);

        // Atomic write: write to temp file, then replace
        var tempPath = filePath + ".tmp";
        await File.WriteAllBytesAsync(tempPath, encryptedData);
        File.Move(tempPath, filePath, overwrite: true);
    }

    public Task<bool> DeleteAsync(string key)
    {
        EnsureInitialized();

        var filePath = GetFilePath(key);

        if (File.Exists(filePath))
        {
            try
            {
                File.Delete(filePath);
                return Task.FromResult(true);
            }
            catch
            {
                return Task.FromResult(false);
            }
        }

        return Task.FromResult(false);
    }

    public Task<bool> ExistsAsync(string key)
    {
        EnsureInitialized();

        var filePath = GetFilePath(key);
        return Task.FromResult(File.Exists(filePath));
    }

    private string GetFilePath(string key)
    {
        if (_currentAccountId == null)
            throw new InvalidOperationException("Storage not initialized for account");

        return Path.Combine(_storageBasePath, _currentAccountId, $"{key}.encrypted.json");
    }

    private void EnsureInitialized()
    {
        if (_encryptionKey == null || _currentAccountId == null)
            throw new InvalidOperationException("Storage not initialized. Call InitializeForAccountAsync first.");
    }
}
