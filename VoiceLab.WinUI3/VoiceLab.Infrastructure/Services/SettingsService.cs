using System.Text.Json;
using VoiceLab.Infrastructure.Storage;

namespace VoiceLab.Infrastructure.Services;

public interface ISettingsService
{
    T GetSetting<T>(string key, T defaultValue);
    void SaveSetting<T>(string key, T value);
}

public sealed class SettingsService(JsonDataStore store) : ISettingsService
{
    private readonly object _gate = new();
    private Dictionary<string, JsonElement> _settings = Load(store);

    public T GetSetting<T>(string key, T defaultValue)
    {
        lock (_gate)
        {
            if (!_settings.TryGetValue(key, out var value)) return defaultValue;
            try { return value.Deserialize<T>() ?? defaultValue; }
            catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException)
            { return defaultValue; }
        }
    }

    public void SaveSetting<T>(string key, T value)
    {
        lock (_gate)
        {
            _settings[key] = JsonSerializer.SerializeToElement(value);
            store.WriteGlobalObject("settings", _settings);
        }
    }

    private static Dictionary<string, JsonElement> Load(JsonDataStore store)
    {
        try { return store.ReadGlobalObject<Dictionary<string, JsonElement>>("settings") ??
            new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase); }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        { return new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase); }
    }
}
