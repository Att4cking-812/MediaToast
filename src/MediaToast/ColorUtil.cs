using Color = System.Windows.Media.Color;
using System;
using System.Collections.Generic;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MediaToast;

public static class ColorUtil
{
    public static Color Secondary(Color c)
    {
        return Color.FromRgb(
            (byte)Math.Min(255, c.R * 0.72 + c.B * 0.28),
            (byte)Math.Min(255, c.G * 0.72 + c.R * 0.28),
            (byte)Math.Min(255, c.B * 0.72 + c.G * 0.28));
    }

    public static Color GetArtColor(BitmapSource source)
    {
        try
        {
            if (source == null) return Color.FromRgb(111, 216, 255);

            BitmapSource bmp = source;
            if (bmp.Format != PixelFormats.Bgra32)
            {
                bmp = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            }

            int w = bmp.PixelWidth;
            int h = bmp.PixelHeight;
            if (w <= 0 || h <= 0) return Color.FromRgb(111, 216, 255);

            int stride = w * 4;
            var pixels = new byte[stride * h];
            bmp.CopyPixels(pixels, stride, 0);

            var buckets = new double[12, 4]; // weight, r, g, b
            int stepX = Math.Max(1, w / 16);
            int stepY = Math.Max(1, h / 16);

            for (int y = 0; y < h; y += stepY)
            {
                for (int x = 0; x < w; x += stepX)
                {
                    int i = y * stride + x * 4;
                    double b = pixels[i];
                    double g = pixels[i + 1];
                    double r = pixels[i + 2];
                    double max = Math.Max(r, Math.Max(g, b));
                    double min = Math.Min(r, Math.Min(g, b));
                    if (max <= 12) continue;
                    double sat = (max - min) / max;
                    if (sat < 0.15) continue;

                    double delta = max - min;
                    if (delta <= 0) continue;
                    double hue;
                    if (max == r) hue = 60.0 * (((g - b) / delta) % 6.0);
                    else if (max == g) hue = 60.0 * (((b - r) / delta) + 2.0);
                    else hue = 60.0 * (((r - g) / delta) + 4.0);
                    if (hue < 0) hue += 360.0;

                    int bucket = ((int)Math.Floor(hue / 30.0)) % 12;
                    double weight = sat * (max / 255.0);
                    buckets[bucket, 0] += weight;
                    buckets[bucket, 1] += r * weight;
                    buckets[bucket, 2] += g * weight;
                    buckets[bucket, 3] += b * weight;
                }
            }

            int best = -1;
            double bestW = 0;
            for (int i = 0; i < 12; i++)
            {
                if (buckets[i, 0] > bestW) { bestW = buckets[i, 0]; best = i; }
            }

            if (best < 0 || bestW <= 0) return Color.FromRgb(196, 214, 232);

            int rr = (int)Math.Round(buckets[best, 1] / bestW);
            int gg = (int)Math.Round(buckets[best, 2] / bestW);
            int bb = (int)Math.Round(buckets[best, 3] / bestW);

            int maxC = Math.Max(rr, Math.Max(gg, bb));
            int minC = Math.Min(rr, Math.Min(gg, bb));
            double satC = maxC <= 0 ? 0 : (maxC - minC) / (double)maxC;

            if (satC < 0.22)
            {
                double lum = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;
                if (lum > 190) return Color.FromRgb(226, 236, 246);
                if (lum < 90) return Color.FromRgb(146, 166, 188);
                return Color.FromRgb(196, 214, 232);
            }

            if (maxC > 185)
            {
                double k = 185.0 / maxC;
                rr = (int)(rr * k);
                gg = (int)(gg * k);
                bb = (int)(bb * k);
            }
            else if (maxC < 125)
            {
                double k = 150.0 / Math.Max(1, maxC);
                rr = (int)Math.Min(255, rr * k);
                gg = (int)Math.Min(255, gg * k);
                bb = (int)Math.Min(255, bb * k);
            }

            return Color.FromRgb((byte)rr, (byte)gg, (byte)bb);
        }
        catch
        {
            return Color.FromRgb(111, 216, 255);
        }
    }
}
