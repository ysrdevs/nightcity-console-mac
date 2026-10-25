using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

// The catalog contains only the tested compatibility deltas and their MIT
// notices. No mod archive, store pack or full mod script bundle is distributed.
public static class NightCityModCompatibility
{
    static readonly Regex Tokens = new("\"(?:\\\\.|[^\"\\\\])*\"|//[^\\r\\n]*|/\\*[\\s\\S]*?\\*/|\\s+|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|.", RegexOptions.Compiled);
    public static string Normalize(string text) => text.TrimStart('\uFEFF').Replace("\r\n", "\n").Replace('\r', '\n');
    static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    public static string TokenHash(string text) => Hash(string.Join("\n", Tokens.Matches(Normalize(text)).Cast<Match>()
        .Select(m => m.Value).Where(t => !string.IsNullOrWhiteSpace(t) && !t.StartsWith("//") && !t.StartsWith("/*"))));
    static JsonDocument Catalog() => JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "nightcity-mod-compat.json")));

    public static bool IsGame25(string game)
    {
        var info = Path.Combine(game, "Cyberpunk2077.app", "Contents", "Info.plist");
        if (!File.Exists(info)) throw new InvalidOperationException("Game Info.plist is missing; select the Cyberpunk 2077 folder.");
        var start = new ProcessStartInfo("/usr/bin/plutil") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var arg in new[] { "-extract", "CFBundleShortVersionString", "raw", "-o", "-", info }) start.ArgumentList.Add(arg);
        using var process = Process.Start(start)!;
        var version = process.StandardOutput.ReadToEnd().Trim();
        process.StandardError.ReadToEnd(); process.WaitForExit();
        if (process.ExitCode != 0) throw new InvalidOperationException("Cannot read the game's version; reinstall or select a complete game folder.");
        return version == "2.5.0";
    }

    static void RequireRegularPath(string file, string root)
    {
        for (FileSystemInfo item = new FileInfo(file); item != null; item = item is FileInfo f ? f.Directory : ((DirectoryInfo)item).Parent)
        {
            if (item.LinkTarget != null) throw new InvalidOperationException("A compatibility target is a symlink; install an ordinary mod copy before applying compatibility updates.");
            if (item.FullName == Path.GetFullPath(root)) break;
        }
    }

    public sealed class CompatibilityPlan : Dictionary<string, byte[]>
    {
        public string Root { get; }
        internal Dictionary<string, byte[]> Originals { get; } = new(StringComparer.Ordinal);
        public CompatibilityPlan(string root) : base(StringComparer.Ordinal) { Root = Path.GetFullPath(root); }
    }

    public static CompatibilityPlan Plan(string directory)
    {
        var result = new CompatibilityPlan(directory);
        if (!Directory.Exists(directory)) return result;
        var scripts = Directory.EnumerateFiles(directory, "*.reds", SearchOption.AllDirectories).ToDictionary(p => p, p => {
            RequireRegularPath(p, directory);
            var bytes = File.ReadAllBytes(p); result.Originals[p] = bytes;
            using var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, true);
            return reader.ReadToEnd();
        }, StringComparer.Ordinal);
        using var catalog = Catalog();
        foreach (var mod in catalog.RootElement.GetProperty("mods").EnumerateArray())
        {
            var name = mod.GetProperty("name").GetString()!;
            var version = mod.GetProperty("version").GetString()!;
            var facade = new Regex(@"public\s+abstract\s+class\s+" + Regex.Escape(name) + @"\s*\{\s*public\s+static\s+func\s+Version\s*\(\s*\)\s*->\s*String\s*=\s*""([^""]+)""");
            var versions = scripts.SelectMany(p => facade.Matches(Normalize(p.Value)).Cast<Match>().Select(m => m.Groups[1].Value)).ToArray();
            var modFiles = scripts.Where(p => Regex.IsMatch(p.Value, @"(?m)^\s*(?:module|import)\s+" + Regex.Escape(name) + @"(?:\W|$)")).ToArray();
            // Optional integrations may import another mod without installing
            // that mod (VA does this for Equipment). Imports alone are not cores.
            var declaresCore = scripts.Any(p => Regex.IsMatch(p.Value, @"(?m)^\s*module\s+" + Regex.Escape(name) + @"(?:\W|$)")
                || Regex.IsMatch(p.Value, @"\bclass\s+" + Regex.Escape(name) + @"\s*\{"));
            if (versions.Length == 0 && !declaresCore) continue;
            if (versions.Length != 1 || versions[0] != version)
                throw new InvalidOperationException($"{name}: install the supported {version} core package once. Unknown or duplicate versions were left unchanged.");
            if (mod.TryGetProperty("methods", out var methods))
            {
                foreach (var method in methods.EnumerateArray())
                {
                    var methodName = method.GetProperty("name").GetString()!;
                    var found = new List<(string file, int start, int length, string body)>();
                    foreach (var entry in modFiles)
                    {
                        var text = result.TryGetValue(entry.Key, out var pending) ? Encoding.UTF8.GetString(pending) : entry.Value;
                        var pattern = new Regex(@"(?m)^(?:@[^\r\n]+\r?\n)+[^\r\n]*\bfunc\s+" + Regex.Escape(methodName) + @"\s*\(");
                        foreach (Match match in pattern.Matches(text))
                        {
                            if (!match.Value.Contains("Method(EquipmentSystemPlayerData)")) continue;
                            var depth = 0; var opened = false; var end = -1;
                            foreach (Match token in Tokens.Matches(text, match.Index))
                            {
                                if (token.Value == "{") { opened = true; depth++; }
                                else if (token.Value == "}" && opened && --depth == 0) { end = token.Index + token.Length; break; }
                            }
                            if (end < 0) throw new InvalidOperationException($"{name}: malformed {methodName}; restore the supported core package.");
                            found.Add((entry.Key, match.Index, end - match.Index, text.Substring(match.Index, end - match.Index)));
                        }
                    }
                    if (found.Count != 1) throw new InvalidOperationException($"{name}: expected one {methodName}; remove duplicate core scripts or restore {version}.");
                    var target = found[0]; var actual = TokenHash(target.body);
                    if (actual == method.GetProperty("after_token_sha256").GetString()) continue;
                    if (actual != method.GetProperty("before_token_sha256").GetString())
                        throw new InvalidOperationException($"{name}: {methodName} differs from the supported {version} code. Your edits were preserved; restore the core package before playing on 2.5.");
                    var original = result.TryGetValue(target.file, out var bytes) ? Encoding.UTF8.GetString(bytes) : scripts[target.file];
                    var replacement = method.GetProperty("replacement").GetString()!;
                    if (target.body.Contains("\r\n")) replacement = replacement.Replace("\n", "\r\n");
                    result[target.file] = Encoding.UTF8.GetBytes(original[..target.start] + replacement + original[(target.start + target.length)..]);
                }
            }
            else
            {
                var variants = mod.GetProperty("files").EnumerateArray().ToArray();
                var candidates = modFiles.Where(p => variants.Any(v => v.GetProperty("filename").GetString() == Path.GetFileName(p.Key))).ToArray();
                if (candidates.Length != 1) throw new InvalidOperationException($"{name}: expected one original core file; remove duplicates or restore {version}.");
                var target = candidates[0]; var actual = Hash(Normalize(target.Value));
                var known = false;
                foreach (var variant in variants)
                {
                    if (actual == variant.GetProperty("after_sha256").GetString()) { known = true; break; }
                    if (actual != variant.GetProperty("before_sha256").GetString()) continue;
                    var before = variant.GetProperty("before").GetString()!; var after = variant.GetProperty("after").GetString()!;
                    var normalized = Normalize(target.Value);
                    if (normalized.Split(before).Length != 2) throw new InvalidOperationException($"{name}: ambiguous compatibility target.");
                    var updated = normalized.Replace(before, after);
                    if (Hash(updated) != variant.GetProperty("after_sha256").GetString()) throw new InvalidOperationException($"{name}: compatibility output failed validation.");
                    if (target.Value.Contains("\r\n")) updated = updated.Replace("\n", "\r\n");
                    result[target.Key] = Encoding.UTF8.GetBytes(updated); known = true; break;
                }
                if (!known) throw new InvalidOperationException($"{name}: modified or unsupported {version} core file was preserved. Restore the supported core package before playing on 2.5.");
            }
        }
        return result;
    }

    public static void Validate(CompatibilityPlan plan)
    {
        foreach (var item in plan)
        {
            RequireRegularPath(item.Key, plan.Root);
            if (!File.ReadAllBytes(item.Key).SequenceEqual(plan.Originals[item.Key]))
                throw new IOException("A mod changed during compatibility preparation; retry when editing is finished.");
        }
    }

    public static void Apply(CompatibilityPlan plan)
    {
        Validate(plan); // Compare with the bytes actually validated by Plan, before any write.
        var originals = plan.Originals;
        var changed = new List<string>();
        try
        {
            foreach (var item in plan)
            {
                RequireRegularPath(item.Key, plan.Root);
                if (!File.ReadAllBytes(item.Key).SequenceEqual(originals[item.Key])) throw new IOException("A mod changed during compatibility preparation; retry when editing is finished.");
                AtomicWrite(item.Key, item.Value); changed.Add(item.Key);
            }
        }
        catch
        {
            foreach (var path in changed.AsEnumerable().Reverse()) AtomicWrite(path, originals[path]);
            throw;
        }
    }
    static void AtomicWrite(string path, byte[] bytes)
    {
        var temp = path + ".nightcity-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllBytes(temp, bytes); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public static int UpgradeGame(string game)
    {
        try
        {
            if (!IsGame25(game)) return 0;
            var plan = Plan(Path.Combine(game, "r6", "scripts"));
            Apply(plan);
            Console.WriteLine($"[COMPAT] 2.5 compatibility ready ({plan.Count} files updated).");
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine("[COMPAT] " + e.Message); return 2; }
    }

    static string FileHash(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    public static bool IsKnownNativeArchive(string path)
    {
        using var catalog = Catalog();
        var hash = FileHash(path);
        return catalog.RootElement.GetProperty("native_archives").EnumerateArray().Any(v => v.GetString() == hash);
    }

    public static Dictionary<string, string>? KnownRepackResources(string path)
    {
        using var catalog = Catalog();
        var hash = FileHash(path);
        foreach (var input in catalog.RootElement.GetProperty("verified_repacks").EnumerateArray())
            if (input.GetProperty("input_sha256").GetString() == hash)
                return input.GetProperty("resources").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!, StringComparer.Ordinal);
        return null;
    }
}
