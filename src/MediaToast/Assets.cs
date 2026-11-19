using System;
using System.IO;
using System.Reflection;

namespace MediaToast;

public static class Assets
{
    public static string Load(string name)
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (var res in asm.GetManifestResourceNames())
        {
            if (res.EndsWith("." + name, StringComparison.OrdinalIgnoreCase))
            {
                using var stream = asm.GetManifestResourceStream(res);
                if (stream == null) continue;
                using var reader = new StreamReader(stream, System.Text.Encoding.UTF8);
                return reader.ReadToEnd();
            }
        }
        throw new FileNotFoundException("asset not found: " + name);
    }
}
