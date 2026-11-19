using System;
using System.IO;
using System.Text.Json;

namespace MediaToast;

public sealed class Settings
{
    public static readonly string DataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MediaToast");

    public static readonly string FilePath = Path.Combine(DataDir, "settings.json");

    public double CardLeft { get; set; } = 24;
    public double CardTop { get; set; } = 24;
    public double CardWidth { get; set; } = 384;
    public double BreathSeconds { get; set; } = 3.2;
    public double GlowSensitivity { get; set; } = 0.12;
    public string GlowPreset { get; set; } = "neon-universal";
    public string CardTheme { get; set; } = "neon";
    public string GlowStyle { get; set; } = "sectors";
    public string GlowSource { get; set; } = "system";
    public bool GlowOn { get; set; } = true;
    public bool ToastOn { get; set; } = true;
    public bool ToastPinned { get; set; } = false;
    public bool VinylOn { get; set; } = false;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static string NormalizePreset(string value)
    {
        switch ((value ?? "").Trim().ToLowerInvariant())
        {
            case "neon-calm":
            case "calm":
                return "neon-calm";
            case "neon-hard":
            case "fire":
            case "hard":
                return "neon-hard";
            default:
                return "neon-universal";
        }
    }

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath, System.Text.Encoding.UTF8);
                var s = JsonSerializer.Deserialize<Settings>(json, Options);
                if (s != null)
                {
                    var preset = NormalizePreset(s.GlowPreset);
                    if (preset != s.GlowPreset)
                    {
                        s.GlowPreset = preset;
                        s.Save();
                    }
                    return s;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Write("settings load: " + ex.Message);
        }

        // перенос настроек из PowerShell-версии (v2)
        try
        {
            var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "MediaToast", "settings.json");
            if (File.Exists(legacy))
            {
                var json = File.ReadAllText(legacy, System.Text.Encoding.UTF8);
                var s = JsonSerializer.Deserialize<Settings>(json, Options);
                if (s != null)
                {
                    s.ToastOn = true;
                    s.GlowPreset = NormalizePreset(s.GlowPreset);
                    s.Save();
                    Log.Write("settings migrated from v2");
                    return s;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Write("settings migrate: " + ex.Message);
        }

        var fresh = new Settings();
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options), new System.Text.UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            Log.Write("settings save: " + ex.Message);
        }
    }
}
