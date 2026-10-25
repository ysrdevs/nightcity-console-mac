using WolvenKit.Common;
using WolvenKit.Common.Services;
using WolvenKit.Core.Interfaces;
using WolvenKit.RED4.Archive;
using WolvenKit.RED4.Archive.CR2W;
using WolvenKit.RED4.Archive.IO;
using WolvenKit.RED4.Types;
using ArchiveErr = WolvenKit.RED4.Archive.IO.EFileReadErrorCodes;

if (args.Length < 1)
{
    Console.Error.WriteLine("usage:");
    Console.Error.WriteLine("  nctool unpack <archive> <looseDir>");
    Console.Error.WriteLine("  nctool pack <looseDir> <out.archive>");
    Console.Error.WriteLine("  nctool roundtrip <archive> <looseDir> <out.archive>");
    Console.Error.WriteLine("  nctool trackA <srcArchive> <looseDir> <outArchive>");
    Console.Error.WriteLine("  nctool rawrepack <archive> <looseDir> <outArchive>   (general: re-serialize all meshes raw)");
    Console.Error.WriteLine("  nctool factories <archive> <looseDir> <outConfig>    (dump factory CSV entityName->root.ent pairs)");
    Console.Error.WriteLine("  nctool loc <archive> <looseDir> <outJson>            (dump onscreens localization secondaryKey->text, fnv32+fnv64 keyed; merges)");
    Console.Error.WriteLine("  nctool install <mod .zip|folder> <gameDir>          (one-step: rawrepack + deploy a mod to the macOS game dirs)");
    Console.Error.WriteLine("  nctool regen <gameDir>                               (self-contained: regenerate all 5 /tmp handoffs from installed mods)");
    Console.Error.WriteLine("  nctool stageplugins <gameDir>                        (copy each plugin's Scripts/*.reds into r6/scripts; run before every compile)");
    Console.Error.WriteLine("  nctool compat25 <gameDir>                            (apply tested mod script compatibility for native game 2.5)");
    return 1;
}

var hash = new StubHashService();
var log = new ConsoleLog();
var mode = args[0];
var _matValFilter = "";  // meshmatarc: dump full material values for entries whose name contains this
// Progress emitter: when set, the long loops (rawrepack unpack + mesh re-serialize) report a 0..1 fraction.
// Install sets this per-archive to map the archive's local 0..1 into its global slice; the sink prints a
// "[PROGRESS] <fraction> <label>" line the NightCity Console app parses to drive a determinate progress bar.
Action<double, string> progressSink = null;
void Prog(double f, string label) => Console.WriteLine($"[PROGRESS] {f:0.000} {label}");

switch (mode)
{
    case "unpack":
        Unpack(args[1], args[2]);
        break;
    case "pack":
        Pack(args[1], args[2]);
        break;
    case "meshmat":
        MeshMat(args[1]);
        break;
    case "meshmatarc":
        _matValFilter = args.Length > 3 ? args[3] : "";
        MeshMatArc(args[1], args.Length > 2 ? args[2] : "");
        break;
    case "install":
        return Install(args[1], args[2], args.Length > 3 ? args[3] : null);
    case "compat25":
        return NightCityModCompatibility.UpgradeGame(args[1]);
    case "regen":
        return Regen(args[1]);
    case "stageplugins":
        // Cheap, idempotent, and safe to run on EVERY launch. Kept separate from `regen` because the launcher
        // only runs regen when /tmp/cp2077_xl_items.txt is missing, i.e. almost never within a session - so
        // staging folded into regen silently never ran and plugin reds (TweakXL/ArchiveXL) never reached scc.
        StagePluginScripts(args[1]);
        return 0;
    case "trackA":
        return TrackA(args[1], args[2], args[3]);
    case "replacer":
        return Replacer(args[1], args[2], args[3]);
    case "rawrepack":
        return RawRepack(args[1], args[2], args[3]);
    case "factories":
        return Factories(args[1], args[2], args[3]);
    case "loc":
        return Loc(args[1], args[2], args[3]);
    case "roundtrip":
    {
        var arc = args[1]; var loose = args[2]; var outArc = args[3];
        int n = Unpack(arc, loose);
        Pack(loose, outArc);
        // re-read to validate
        var r2 = new ArchiveReader();
        if (r2.ReadArchive(outArc, hash, out var ar2) != ArchiveErr.NoError)
        {
            Console.WriteLine("[FAIL] could not re-read packed archive");
            return 2;
        }
        Console.WriteLine($"[ROUNDTRIP] original={n} files, repacked re-read={ar2.FileCount} files, size={new FileInfo(outArc).Length} bytes");
        Console.WriteLine(n == ar2.FileCount ? "[ OK ] file count preserved" : "[WARN] file count differs");
        break;
    }
    default:
        Console.Error.WriteLine($"unknown mode {mode}");
        return 1;
}
return 0;

int Unpack(string archivePath, string looseDir)
{
    var reader = new ArchiveReader();
    if (reader.ReadArchive(archivePath, hash, out var ar) != ArchiveErr.NoError)
        throw new Exception("failed to read archive " + archivePath);
    Directory.CreateDirectory(looseDir);
    int count = 0, fail = 0;
    foreach (var f in ar.Files.Values.OfType<FileEntry>())
    {
        var rel = f.Name.Replace('\\', '/');                 // depot path
        var outPath = Path.Combine(looseDir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        try
        {
            using var fs = File.Create(outPath);
            f.Extract(fs);
            count++;
        }
        catch (Exception e)
        {
            fail++;
            if (fail <= 3) Console.WriteLine($"  [extract-fail] {rel}: {e.GetType().Name} {e.Message}");
        }
        progressSink?.Invoke((double)(count + fail) / Math.Max(1, (int)ar.FileCount) * 0.45, "Unpacking");
    }
    Console.WriteLine($"[UNPACK] {archivePath}\n  -> {looseDir}\n  extracted={count} failed={fail} total={ar.FileCount}");
    return count;
}

void Pack(string looseDir, string outArchive)
{
    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outArchive))!);
    using var fs = File.Create(outArchive);
    var writer = new ArchiveWriter(hash, log);
    var ok = writer.WriteArchive(new DirectoryInfo(looseDir), fs);
    fs.Flush();
    Console.WriteLine($"[PACK] {looseDir} -> {outArchive}  WriteArchive={ok}  size={fs.Length}");
}

// ---------------------------------------------------------------------------
// rawrepack: GENERAL, mod-agnostic. Unpack any archive, RE-SERIALIZE every mesh
// (read CR2WReader -> write CR2WWriter, no edits) so its internal render buffers are
// written RAW (the CR2WWriter raw-buffer patch: non-inplace buffers written
// uncompressed, diskSize==memSize -> the engine memcpy's instead of running the
// render-blob decompressor, which SIGTRAPs on KARK). Then pack. This is the keystone
// fix the bikini needed, applied to ANY clothing mod's meshes.
// ---------------------------------------------------------------------------
int RawRepack(string srcArchive, string looseDir, string outArchive)
{
    Unpack(srcArchive, looseDir);

    // Render-buffer-bearing resource types. Meshes are the SIGTRAP source for clothing;
    // morphtargets carry GPU blobs too. Other CR2W (.ent/.app/.mi) are loaded by the
    // entity/material systems, not the render-blob decompressor, so we leave them as-is.
    var exts = new[] { ".mesh", ".morphtarget" };
    int reser = 0, skipped = 0, failed = 0;
    var renderFiles = Directory.EnumerateFiles(looseDir, "*", SearchOption.AllDirectories)
                               .Where(p => exts.Any(e => p.EndsWith(e, StringComparison.OrdinalIgnoreCase))).ToList();
    int renderTotal = renderFiles.Count;
    foreach (var path in renderFiles)
    {
        progressSink?.Invoke(0.45 + (double)(reser + skipped + failed) / Math.Max(1, renderTotal) * 0.45, "Optimizing meshes");
        try
        {
            CR2WFile file;
            using (var ms = new MemoryStream(File.ReadAllBytes(path)))
            using (var cr = new CR2WReader(ms))
            {
                cr.ParsingError += a => true;
                if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf == null) { skipped++; continue; }
                file = cf;
            }
            using var outMs = new MemoryStream();
            using (var cw = new CR2WWriter(outMs) { LoggerService = log }) cw.WriteFile(file);
            File.WriteAllBytes(path, outMs.ToArray());
            reser++;
        }
        catch (Exception e)
        {
            failed++;
            if (failed <= 8) Console.WriteLine($"  [reser-fail] {Path.GetFileName(path)}: {e.GetType().Name} {e.Message}");
        }
    }
    Console.WriteLine($"[RAWREPACK] re-serialized {reser} render file(s) (skipped {skipped}, failed {failed})");

    // verify: no mesh in the loose tree still carries a KARK internal buffer
    int karkLeft = 0, meshCount = 0;
    foreach (var path in Directory.EnumerateFiles(looseDir, "*.mesh", SearchOption.AllDirectories))
    {
        meshCount++;
        if (ContainsKark(File.ReadAllBytes(path))) karkLeft++;
    }
    Console.WriteLine($"[RAWREPACK] {meshCount} mesh(es); still KARK after re-serialize: {karkLeft} (want 0)");

    progressSink?.Invoke(0.95, "Packing");
    Pack(looseDir, outArchive);
    progressSink?.Invoke(1.0, "Packing");
    return (failed > 0 && reser == 0) ? 2 : 0;
}

static bool ContainsKark(byte[] b)
{
    for (int i = 0; i + 4 <= b.Length; i++)
        if (b[i] == 0x4B && b[i + 1] == 0x41 && b[i + 2] == 0x52 && b[i + 3] == 0x4B) return true; // "KARK"
    return false;
}

// ---------------------------------------------------------------------------
// regen: GENERAL, self-contained (NO python, NO shell) regeneration of ALL five
// macOS handoffs from every installed mod, so the notarized NightCity Console app
// can regenerate them with just the bundled nctool binary. Mirrors regen-handoffs.sh
// but in-process: factories + loc reuse the existing modes; paths + meshalias walk
// the archives via WolvenKit (the port of _tools/mkpreload.py + mkmeshalias.py);
// names expands the deployed r6/tweaks yaml (the port of _tools/dump-xl-names.py).
//   items.txt  <- factory CSV entityName->path        (FXRESEAL reseal reads it)
//   loc.json   <- onscreens secondaryKey->text        (CMN loc hook reads it)
//   paths.txt  <- every resource-path string          (ResourcePathRegistry preload)
//   meshalias.txt <- dynamic mesh template->literal    (installMeshRedirect)
//   names.txt  <- <hexhash>\t<name> CName side-table    (CNamePool-inl.hpp)
// ---------------------------------------------------------------------------
int Regen(string gameDir)
{
    // Restore the /tmp runtime enable-flags the macOS compatibility layer is gated on. macOS wipes /tmp on
    // reboot, and without these the launch runs with the whole layer off (no binder patch, no Codeware native
    // registration) -> instant "Failed to initialize scripts data" panic. Regen runs exactly when /tmp state
    // is missing (the launcher checks /tmp/cp2077_xl_items.txt), so this is the natural restore point.
    foreach (var flag in new[] { "/tmp/cp2077_codeware_real", "/tmp/cp2077_bindpatch",
                                 "/tmp/cp2077_bindreject", "/tmp/cp2077_binderr", "/tmp/cp2077_reglog" })
        try { if (!File.Exists(flag)) File.Create(flag).Dispose(); } catch { }

    StagePluginScripts(gameDir);

    var modDir = Path.Combine(gameDir, "archive", "Mac", "mod");
    if (!Directory.Exists(modDir)) { Console.Error.WriteLine($"[REGEN] no mod dir: {modDir}"); return 2; }

    var items = "/tmp/cp2077_xl_items.txt";
    var loc   = "/tmp/cp2077_xl_loc.json";
    var paths = "/tmp/cp2077_xl_paths.txt";
    var alias = "/tmp/cp2077_xl_meshalias.txt";
    var names = "/tmp/cp2077_xl_names.txt";
    foreach (var f in new[] { items, loc, paths, alias, names })
        try { File.Delete(f); } catch { }

    var archives = Directory.EnumerateFiles(modDir, "*.archive", SearchOption.TopDirectoryOnly)
                            .Where(p => !p.EndsWith(".bak", StringComparison.OrdinalIgnoreCase))
                            .OrderBy(p => p, StringComparer.Ordinal).ToList();

    var pathSet  = new SortedSet<string>(StringComparer.Ordinal);  // paths.txt: sorted-unique
    var aliasSeen = new HashSet<string>();                          // meshalias.txt: first-seen dedup
    var aliasOut = new List<string>();
    var tmpRoot = Path.Combine(Path.GetTempPath(), "nctool_regen_" + Path.GetRandomFileName());

    int regenDone = 0;
    foreach (var arc in archives)
    {
        Prog((double)regenDone / Math.Max(1, archives.Count) * 0.9, "Updating game data");
        regenDone++;
        Console.WriteLine($"[REGEN] === {Path.GetFileName(arc)} ===");
        var loose = Path.Combine(tmpRoot, Path.GetFileNameWithoutExtension(arc));
        // factories + loc (existing modes; both merge into their out file).
        try { Factories(arc, Path.Combine(loose, "fac"), items); } catch (Exception e) { Console.WriteLine($"  [factories-fail] {e.Message}"); }
        try { Loc(arc, Path.Combine(loose, "loc"), loc); }        catch (Exception e) { Console.WriteLine($"  [loc-fail] {e.Message}"); }
        try { Directory.Delete(loose, true); } catch { }

        // paths + meshalias: walk the archive directly.
        try
        {
            var reader = new ArchiveReader();
            if (reader.ReadArchive(arc, hash, out var ar) != ArchiveErr.NoError) continue;
            foreach (var fe in ar.Files.Values.OfType<FileEntry>())
            {
                pathSet.Add(fe.Name.Replace('/', '\\'));   // resource-list row -> backslash form
                if (!(fe.Name.EndsWith(".app", StringComparison.OrdinalIgnoreCase) ||
                      fe.Name.EndsWith(".ent", StringComparison.OrdinalIgnoreCase))) continue;
                var ms = new MemoryStream();
                try { fe.Extract(ms); } catch { continue; }
                ms.Position = 0;
                using var cr = new CR2WReader(ms);
                cr.ParsingError += a => true;
                if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk == null) continue;
                CollectComponentMeshPaths(cf.RootChunk, new HashSet<object>(ReferenceEqualityComparer.Instance),
                                          pathSet, aliasSeen, aliasOut);
            }
        }
        catch (Exception e) { Console.WriteLine($"  [walk-fail] {e.Message}"); }
    }
    try { if (Directory.Exists(tmpRoot)) Directory.Delete(tmpRoot, true); } catch { }

    Prog(0.95, "Finalizing");
    aliasOut.Sort(StringComparer.Ordinal);   // match regen-handoffs.sh's final `sort -u` on the mesh-alias file
    File.WriteAllText(paths, pathSet.Count == 0 ? "\n" : string.Join("\n", pathSet) + "\n");
    File.WriteAllText(alias, aliasOut.Count == 0 ? "" : string.Join("\n", aliasOut) + "\n");
    RegenNames(gameDir, names);
    Prog(1.0, "Done");

    Console.WriteLine($"[REGEN] DONE  archives={archives.Count} paths={pathSet.Count} meshalias={aliasOut.Count}");
    Console.WriteLine($"  {items}  ({(File.Exists(items) ? File.ReadAllLines(items).Length : 0)} rows)");
    Console.WriteLine($"  {paths}  ({pathSet.Count} path strings)");
    Console.WriteLine($"  {alias}  ({aliasOut.Count} mesh aliases)");
    return 0;
}

// Walk a CR2W chunk graph collecting garment/mesh component mesh DepotPaths (as stored, incl. a leading
// '*' + {..} tokens for dynamic templates). Adds each to pathSet (verbatim) and, if dynamic ('{'), to the
// meshalias list (template -> expanded). Ports archdump's WalkForComponents + mkmeshalias's expand().
static void CollectComponentMeshPaths(object node, HashSet<object> seen,
    SortedSet<string> pathSet, HashSet<string> aliasSeen, List<string> aliasOut)
{
    if (node == null || !seen.Add(node)) return;

    string meshPath = null;
    if (node is entSkinnedMeshComponent smc) meshPath = smc.Mesh.DepotPath.GetResolvedText();
    else if (node is entMeshComponent mc)    meshPath = mc.Mesh.DepotPath.GetResolvedText();
    if (meshPath != null)
    {
        if (meshPath.Length > 0) pathSet.Add(meshPath);            // verbatim (keeps '*' + {..})
        if (meshPath.Contains('{') && aliasSeen.Add(meshPath))
            aliasOut.Add(meshPath + "\t" + ExpandMeshTemplate(meshPath));
        return;
    }

    if (node is RedBaseClass rbc)
        foreach (var prop in rbc.GetType().GetProperties())
        {
            object val; try { val = prop.GetValue(rbc); } catch { continue; }
            CollectWalkValue(val, seen, pathSet, aliasSeen, aliasOut);
        }
    else CollectWalkValue(node, seen, pathSet, aliasSeen, aliasOut);
}

static void CollectWalkValue(object val, HashSet<object> seen,
    SortedSet<string> pathSet, HashSet<string> aliasSeen, List<string> aliasOut)
{
    if (val == null) return;
    if (val is RedBaseClass) { CollectComponentMeshPaths(val, seen, pathSet, aliasSeen, aliasOut); return; }
    var chunkProp = val.GetType().GetProperty("Chunk");
    if (chunkProp != null)
    {
        try { var c = chunkProp.GetValue(val); if (c is RedBaseClass) CollectComponentMeshPaths(c, seen, pathSet, aliasSeen, aliasOut); } catch { }
        return;
    }
    if (val is System.Collections.IEnumerable en && val is not string)
        foreach (var item in en) CollectWalkValue(item, seen, pathSet, aliasSeen, aliasOut);
}

// Ports mkmeshalias.py expand(): strip a single leading '*', then substitute the mesh-PATH tokens with the
// common macOS defaults (the runtime per-color bridge resolves {variant} separately).
static string ExpandMeshTemplate(string s)
{
    if (s.StartsWith("*")) s = s.Substring(1);
    s = s.Replace("{gender}", "w").Replace("{body}", "base_body").Replace("{feet}", "flat").Replace("{variant}", "black");
    if (s.Contains('{')) Console.Error.WriteLine("WARN: unresolved token(s) in mesh path -> " + s);
    return s;
}

static ulong Fnv1a64(string s)
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 0x100000001b3UL; }
    return h;
}

// Stage every RED4ext plugin's shipped reds into r6/scripts so scc can see them.
//
// On Windows redscript loads plugin-provided reds straight out of each plugin's own Scripts/ dir. On macOS scc
// only compiles r6/scripts, so a plugin's reds are invisible unless they are copied in. Codeware's were staged
// by hand long ago and then quietly relied on; TweakXL's (TweakDBManager, TweakXL, TweakDBBatch,
// ScriptableTweak, ...) and ArchiveXL's (Facade, DynamicAppearance, Module) never were. Any mod referencing
// TweakDBManager or ArchiveXL.Require() therefore failed to compile with "unresolved reference", and staging
// them by hand does not survive a launch (Play rebuilds r6/scripts from the install manifests and drops
// untracked dirs). Doing it here makes it automatic and idempotent, and keeps the plugin dir the single source
// of truth - matching the Windows layout.
//
// Pairs with the native side: the reds only BIND if the plugin also registers its RTTI natives at the
// CBaseEngine::InitScripts window (codeware_registerNatives / cybermodman_registerNatives /
// tweakxl_registerNatives, driven by the cet Frida hook). Staging reds for a plugin that does not register its
// natives produces a bundle the binder cannot satisfy, which crashes the game while it builds its own
// "Missing native function" message - so keep the two in sync.
//
// The plugin's Scripts/ dir is the SINGLE SOURCE OF TRUTH and is copied verbatim. Codeware's stock
// Codeware.Global.reds is a dump of the WINDOWS RTTI (~351 types that do not exist on macOS), which the eager
// binder rejects wholesale; the macOS-correct regeneration must therefore live IN the plugin dir, not be
// patched in downstream. If Codeware is ever reinstalled, re-copy
// cybermodman/docs/Codeware.Global.macos.CORRECTED.reds over
// red4ext/plugins/Codeware/Scripts/Codeware.Global.reds (the stock file is kept alongside as
// .windows-dump.bak) - otherwise this function will faithfully stage the broken Windows dump.
void StagePluginScripts(string gameDir)
{
    var pluginsDir = Path.Combine(gameDir, "red4ext", "plugins");
    if (!Directory.Exists(pluginsDir)) return;

    int plugins = 0, copied = 0;
    foreach (var pluginDir in Directory.EnumerateDirectories(pluginsDir).OrderBy(p => p, StringComparer.Ordinal))
    {
        var srcDir = Path.Combine(pluginDir, "Scripts");
        if (!Directory.Exists(srcDir)) continue;

        var reds = Directory.EnumerateFiles(srcDir, "*.reds", SearchOption.AllDirectories).ToList();
        if (reds.Count == 0) continue;

        var name = Path.GetFileName(pluginDir);
        var dstDir = Path.Combine(gameDir, "r6", "scripts", name);
        Directory.CreateDirectory(dstDir);
        plugins++;

        foreach (var src in reds)
        {
            var rel = Path.GetRelativePath(srcDir, src);
            var dst = Path.Combine(dstDir, rel);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                // Copy only when changed, so a rebuilt plugin propagates but untouched files keep their mtime.
                if (!File.Exists(dst) || File.GetLastWriteTimeUtc(src) != File.GetLastWriteTimeUtc(dst) ||
                    new FileInfo(src).Length != new FileInfo(dst).Length)
                {
                    File.Copy(src, dst, true);
                    File.SetLastWriteTimeUtc(dst, File.GetLastWriteTimeUtc(src));
                    copied++;
                }
            }
            catch (Exception e) { Console.WriteLine($"  [pluginscripts-fail] {name}/{rel}: {e.Message}"); }
        }
        Console.WriteLine($"[REGEN] plugin reds staged: {name} ({reds.Count} file(s)) -> r6/scripts/{name}");
    }

    if (plugins > 0)
        Console.WriteLine($"[REGEN] plugin reds: {plugins} plugin(s), {copied} file(s) updated");
}

// Ports dump-xl-names.py: expand every deployed r6/tweaks appearanceName template over its $instances,
// add each full name + its base (everything before the first !%& marker), dedup by name, sort by name,
// write "<016x hash>\t<name>". (The .app/.ent harvest in the python is a no-op `pass`, so yaml is the source.)
// PLUS two general sources for the Codeware WidgetSpawningService "Item:Controller.Class" colon-override
// (CName::ToString on macOS resolves ONLY through this side-table, and the colon-split needs the string):
//   1. every n"..." name literal in the staged r6/scripts reds (page spawns like
//      n"AtelierStores:VirtualAtelier.UI.AtelierStoresListController" come from script literals), and
//   2. every colon-pattern string inside mod .inkwidget buffers in archive/Mac/mod (grid row/card template
//      names like "AtelierStoreItem:..." are baked into the widget-library CR2W data, not scripts).
void RegenNames(string gameDir, string outFile)
{
    var tweaks = Path.Combine(gameDir, "r6", "tweaks");
    var nameSet = new SortedSet<string>(StringComparer.Ordinal);
    if (Directory.Exists(tweaks))
        foreach (var yml in Directory.EnumerateFiles(tweaks, "*.yaml", SearchOption.AllDirectories))
        {
            string text; try { text = File.ReadAllText(yml); } catch { continue; }
            foreach (var (appearanceName, instances) in ParseYamlRecords(text))
            {
                if (string.IsNullOrEmpty(appearanceName)) continue;
                var insts = instances.Count > 0 ? instances : new List<Dictionary<string, string>> { new() };
                foreach (var inst in insts)
                {
                    var full = appearanceName;
                    foreach (var kv in inst) full = full.Replace("${" + kv.Key + "}", kv.Value);
                    if (full.Contains("${")) continue;   // unexpanded var
                    nameSet.Add(full);
                    var b = BaseOfName(full);
                    if (b.Length > 0) nameSet.Add(b);
                }
            }
        }

    int redsNames = 0, widgetNames = 0;

    // Source 2: n"..." literals from every staged reds file.
    var scripts = Path.Combine(gameDir, "r6", "scripts");
    if (Directory.Exists(scripts))
    {
        var nLit = new System.Text.RegularExpressions.Regex("n\"([^\"\\\\\r\n]+)\"");
        foreach (var reds in Directory.EnumerateFiles(scripts, "*.reds", SearchOption.AllDirectories))
        {
            string text; try { text = File.ReadAllText(reds); } catch { continue; }
            foreach (System.Text.RegularExpressions.Match m in nLit.Matches(text))
            {
                var v = m.Groups[1].Value;
                if (v.Length == 0 || v.Length > 512) continue;
                if (nameSet.Add(v)) redsNames++;
                // The colon-split spawns the BASE item name and hashes the controller suffix separately;
                // record both so any later ToString on them round-trips too.
                var colon = v.IndexOf(':');
                if (colon > 0)
                {
                    if (nameSet.Add(v.Substring(0, colon))) redsNames++;
                    if (colon + 1 < v.Length && nameSet.Add(v.Substring(colon + 1))) redsNames++;
                }
            }
        }
    }

    // Source 3: colon-pattern ASCII strings from mod .inkwidget buffers (decompressed scan; the template
    // names live in the CR2W CName table as plain length-prefixed strings, so a byte scan finds them).
    var modDir2 = Path.Combine(gameDir, "archive", "Mac", "mod");
    if (Directory.Exists(modDir2))
        foreach (var arc in Directory.EnumerateFiles(modDir2, "*.archive", SearchOption.TopDirectoryOnly))
        {
            try
            {
                var reader = new ArchiveReader();
                if (reader.ReadArchive(arc, hash, out var ar) != ArchiveErr.NoError) continue;
                foreach (var fe in ar.Files.Values.OfType<FileEntry>())
                {
                    if (!fe.Name.EndsWith(".inkwidget", StringComparison.OrdinalIgnoreCase)) continue;
                    var ms = new MemoryStream();
                    try { fe.Extract(ms); } catch { continue; }
                    foreach (var s in ScanColonNames(ms.ToArray()))
                    {
                        if (nameSet.Add(s)) widgetNames++;
                        var colon = s.IndexOf(':');
                        if (colon > 0)
                        {
                            if (nameSet.Add(s.Substring(0, colon))) widgetNames++;
                            if (colon + 1 < s.Length && nameSet.Add(s.Substring(colon + 1))) widgetNames++;
                        }
                    }
                }
            }
            catch (Exception e) { Console.WriteLine($"  [names-walk-fail] {Path.GetFileName(arc)}: {e.Message}"); }
        }

    var sb = new System.Text.StringBuilder();
    sb.Append("# ArchiveXL macOS CName side-table handoff: <hexhash>\\t<name>. Loaded by CNamePool-inl.hpp.\n");
    foreach (var n in nameSet) sb.Append(Fnv1a64(n).ToString("x16")).Append('\t').Append(n).Append('\n');
    File.WriteAllText(outFile, sb.ToString());
    Console.WriteLine($"[REGEN] names -> {outFile} ({nameSet.Count} names; +{redsNames} reds literals, +{widgetNames} inkwidget colon-names)");
}

// Scan a decompressed CR2W buffer for ASCII strings of the form "Word.Word:Word.Word" (library item name +
// controller class override). Conservative charset ([A-Za-z0-9_.]) with exactly one ':', both sides
// non-empty, total length 3..256 - template names and class paths never need more.
static IEnumerable<string> ScanColonNames(byte[] buf)
{
    var found = new HashSet<string>();
    int i = 0;
    while (i < buf.Length)
    {
        // start of a candidate run
        if (!IsNameByte(buf[i])) { i++; continue; }
        int start = i;
        int colons = 0;
        while (i < buf.Length && (IsNameByte(buf[i]) || buf[i] == (byte)':'))
        {
            if (buf[i] == (byte)':') colons++;
            i++;
        }
        int len = i - start;
        if (colons == 1 && len >= 3 && len <= 256)
        {
            var s = System.Text.Encoding.ASCII.GetString(buf, start, len);
            var colon = s.IndexOf(':');
            if (colon > 0 && colon < s.Length - 1)
                found.Add(s);
        }
    }
    return found;
}

static bool IsNameByte(byte b) =>
    (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_' || b == '.';

static string BaseOfName(string name)
{
    for (int i = 0; i < name.Length; i++)
        if (name[i] == '!' || name[i] == '%' || name[i] == '&') return name.Substring(0, i);
    return name;
}

// Python str whitespace parity: str.strip()/splitlines() treat FS/GS/RS/US (0x1c-0x1f) as whitespace/line
// separators, which .NET char.IsWhiteSpace does NOT. Match python so a stray control char in a TweakXL yaml
// (or classic-Mac \r line endings) produces the SAME names handoff (adversarial-verify confirmed divergences).
static bool IsPySpace(char c) => char.IsWhiteSpace(c) || (c >= '\x1c' && c <= '\x1f');
static string PyStrip(string s)
{
    int i = 0, j = s.Length;
    while (i < j && IsPySpace(s[i])) i++;
    while (j > i && IsPySpace(s[j - 1])) j--;
    return s.Substring(i, j - i);
}
static string PyStripStart(string s) { int i = 0; while (i < s.Length && IsPySpace(s[i])) i++; return s.Substring(i); }
static string PyStripEnd(string s) { int j = s.Length; while (j > 0 && IsPySpace(s[j - 1])) j--; return s.Substring(0, j); }
// python str.splitlines() boundary set (superset of \n / \r\n / \r).
static string[] PyLineSeps() => new[] { "\r\n", "\n", "\r", "\u000b", "\u000c", "\u001c", "\u001d", "\u001e", "\u0085", "\u2028", "\u2029" };

// Permissive line-based YAML reader matching dump-xl-names.py parse_yaml_records: captures top-level
// "Key:" blocks, their "appearanceName:", and "$instances:" lists of "- { k: v, ... }" inline maps.
// Deliberately NOT a full YAML parser (TweakXL yaml uses !append tags that break strict parsers).
static List<(string appearanceName, List<Dictionary<string, string>> instances)> ParseYamlRecords(string text)
{
    var records = new List<(string, List<Dictionary<string, string>>)>();
    string curAppearance = null;
    List<Dictionary<string, string>> curInstances = null;
    bool have = false, instMode = false;
    void Flush() { if (have) records.Add((curAppearance, curInstances)); }
    foreach (var raw in text.Split(PyLineSeps(), StringSplitOptions.None))
    {
        var line = PyStripEnd(raw);                       // python raw.rstrip()
        var lstripped = PyStripStart(line);               // python line.lstrip()
        if (lstripped.Length == 0 || lstripped.StartsWith("#")) continue;
        int indent = line.Length - lstripped.Length;
        var s = PyStrip(line);
        if (indent == 0 && s.EndsWith(":"))
        {
            Flush();
            curAppearance = null; curInstances = new List<Dictionary<string, string>>(); have = true; instMode = false;
            continue;
        }
        if (!have) continue;
        if (s.StartsWith("appearanceName:")) { curAppearance = PyStrip(s.Substring("appearanceName:".Length)).Trim('"', '\''); instMode = false; continue; }
        if (s.StartsWith("$instances:")) { instMode = true; continue; }
        if (instMode && s.StartsWith("- {") && s.EndsWith("}"))
        {
            var body = s.Substring(3, s.Length - 4);
            var d = new Dictionary<string, string>();
            foreach (var pair in body.Split(','))
            {
                int c = pair.IndexOf(':');
                if (c >= 0) d[PyStrip(pair.Substring(0, c))] = PyStrip(pair.Substring(c + 1)).Trim('"', '\'');
            }
            curInstances.Add(d); continue;
        }
        if (instMode && !s.StartsWith("-")) instMode = false;
    }
    Flush();
    return records;
}

// ---------------------------------------------------------------------------
// install: GENERAL, mod-agnostic ONE-STEP installer. Takes a mod .zip OR folder
// (standard Windows mod layout) + the macOS game dir, and deploys everything to the
// right Mac locations, rawrepacking mesh archives on the way (the KARK fix). This is
// the engine the NightCity Console app's "Install Mod" drag-drop calls. Layout is
// detected by MARKER path segments (archive/, r6/tweaks/, r6/scripts/, red4ext/plugins/)
// so it works whether the mod is at the root or nested under a mod-name folder.
// Handoff regeneration (factory/loc/etc.) is a SEPARATE step - the app regenerates
// from ALL installed archives on Play (mirrors regen-handoffs.sh), because a handoff
// must reflect every deployed mod, not just the one being installed.
// ---------------------------------------------------------------------------
int Install(string src, string gameDir, string manifestOut)
{
    if (!Directory.Exists(gameDir))
    {
        Console.Error.WriteLine($"[INSTALL] game dir not found: {gameDir}");
        return 2;
    }
    var modName = Path.GetFileNameWithoutExtension(src.TrimEnd('/', '\\'));
    var deployed = new List<string>();   // absolute dest paths, for the app's per-mod manifest (accurate uninstall)

    // 1) Resolve a source directory: unzip to a temp dir if src is a .zip.
    string srcDir;
    string? tmpUnzip = null;
    if (File.Exists(src) && src.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
    {
        tmpUnzip = Path.Combine(Path.GetTempPath(), "nightcity_install_" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmpUnzip);
        System.IO.Compression.ZipFile.ExtractToDirectory(src, tmpUnzip);
        srcDir = tmpUnzip;
        Console.WriteLine($"[INSTALL] unzipped {Path.GetFileName(src)} -> {tmpUnzip}");
    }
    else if (Directory.Exists(src))
    {
        srcDir = src;
    }
    else
    {
        Console.Error.WriteLine($"[INSTALL] source not found (need a .zip or a folder): {src}");
        return 2;
    }

    // Validate the entire incoming compatibility plan before deploying anything.
    // Source folders and ZIPs remain unchanged; only destination bytes adapt.
    bool native25;
    NightCityModCompatibility.CompatibilityPlan compatibility;
    try
    {
        native25 = NightCityModCompatibility.IsGame25(gameDir);
        compatibility = native25 ? NightCityModCompatibility.Plan(srcDir) : new(srcDir);
        if (native25) NightCityModCompatibility.Plan(Path.Combine(gameDir, "r6", "scripts"));
        NightCityModCompatibility.Validate(compatibility);
    }
    catch (Exception e)
    {
        Console.Error.WriteLine("[COMPAT] " + e.Message);
        if (tmpUnzip != null) Directory.Delete(tmpUnzip, true);
        return 2;
    }

    // Destination roots on macOS.
    var modArchiveDir = Path.Combine(gameDir, "archive", "Mac", "mod");
    var xlBundleDir   = Path.Combine(gameDir, "red4ext", "plugins", "ArchiveXL", "Bundle");
    Directory.CreateDirectory(modArchiveDir);
    Directory.CreateDirectory(xlBundleDir);

    int archives = 0, xls = 0, tweaks = 0, scripts = 0, plugins = 0, skipped = 0;
    var tmpRoot = Path.Combine(Path.GetTempPath(), "nightcity_raw_" + Path.GetRandomFileName());

    // Count the archives up front so each rawrepack maps into its own slice of the 0..1 install bar.
    int nArch = Directory.EnumerateFiles(srcDir, "*.archive", SearchOption.AllDirectories).Count(p =>
    {
        var l = p.Substring(srcDir.Length).Replace('\\', '/').TrimStart('/').ToLowerInvariant();
        return l.Contains("/archive/") || l.StartsWith("archive/");
    });

    // 2) Walk the whole source tree and classify by MARKER path segment.
    foreach (var path in Directory.EnumerateFiles(srcDir, "*", SearchOption.AllDirectories))
    {
        var rel = path.Substring(srcDir.Length).Replace('\\', '/').TrimStart('/');
        var lower = rel.ToLowerInvariant();
        var name = Path.GetFileName(path);

        // a) content archives -> rawrepack -> archive/Mac/mod/
        if (lower.Contains("/archive/") || lower.StartsWith("archive/"))
        {
            if (name.EndsWith(".archive", StringComparison.OrdinalIgnoreCase))
            {
                var outArc = Path.Combine(modArchiveDir, name);
                if (native25 && NightCityModCompatibility.IsKnownNativeArchive(path))
                {
                    File.Copy(path, outArc, true);
                    Console.WriteLine($"[INSTALL] archive {name} -> archive/Mac/mod/ (verified native resource)");
                    deployed.Add(outArc); archives++; continue;
                }
                var loose = Path.Combine(tmpRoot, "arc_" + archives);
                Console.WriteLine($"[INSTALL] archive {name} -> rawrepack -> archive/Mac/mod/");
                double bse = (double)archives / Math.Max(1, nArch), spn = 1.0 / Math.Max(1, nArch);
                progressSink = (f, lbl) => Prog(bse + f * spn, lbl);
                var expectedResources = native25 ? NightCityModCompatibility.KnownRepackResources(path) : null;
                var repacked = expectedResources != null ? Path.Combine(tmpRoot, name) : outArc;
                if (RawRepack(path, loose, repacked) != 0)
                    throw new InvalidOperationException($"{name}: archive conversion failed; restore the original mod package.");
                if (expectedResources != null)
                {
                    // ArchiveWriter uses current timestamps, so verify the actual
                    // unpacked resources against the accepted game's content.
                    var reader = new ArchiveReader();
                    if (reader.ReadArchive(repacked, hash, out var verified) != ArchiveErr.NoError || verified.FileCount != expectedResources.Count)
                        throw new InvalidOperationException($"{name}: converted archive failed its resource count check.");
                    foreach (var entry in verified.Files.Values.OfType<FileEntry>())
                    {
                        var resource = entry.Name.Replace('\\', '/');
                        using var extracted = new MemoryStream();
                        entry.Extract(extracted);
                        extracted.Position = 0;
                        var actual = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(extracted)).ToLowerInvariant();
                        if (!expectedResources.TryGetValue(resource, out var expected) || actual != expected)
                            throw new InvalidOperationException($"{name}: converted resource differs from the tested version ({resource}).");
                    }
                    verified.ReleaseFileHandle();
                    File.Move(repacked, outArc, true);
                    Console.WriteLine($"[INSTALL] verified {expectedResources.Count} resources against the tested native archive");
                }
                progressSink = null;
                try { Directory.Delete(loose, true); } catch { }
                deployed.Add(outArc);
                archives++;
                continue;
            }
            if (name.EndsWith(".xl", StringComparison.OrdinalIgnoreCase))
            {
                var pairedArchive = path.Substring(0, path.Length - 3);
                var nativePair = native25 && File.Exists(pairedArchive) && (NightCityModCompatibility.IsKnownNativeArchive(pairedArchive) || NightCityModCompatibility.KnownRepackResources(pairedArchive) != null);
                var xlDst = Path.Combine(nativePair ? modArchiveDir : xlBundleDir, name);
                File.Copy(path, xlDst, true);
                Console.WriteLine($"[INSTALL] xl {name} -> {(nativePair ? "archive/Mac/mod/" : "ArchiveXL/Bundle/")}");
                deployed.Add(xlDst);
                xls++;
                continue;
            }
        }

        // b) r6/tweaks/** and r6/scripts/** -> preserve the sub-tree under r6/
        int mt = lower.IndexOf("r6/tweaks/", StringComparison.Ordinal);
        if (mt >= 0)
        {
            var subRel = rel.Substring(mt + "r6/tweaks/".Length);
            var dst = Path.Combine(gameDir, "r6", "tweaks", subRel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(path, dst, true);
            deployed.Add(dst);
            tweaks++;
            continue;
        }
        int ms = lower.IndexOf("r6/scripts/", StringComparison.Ordinal);
        if (ms >= 0)
        {
            var subRel = rel.Substring(ms + "r6/scripts/".Length);
            var dst = Path.Combine(gameDir, "r6", "scripts", subRel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            if (compatibility.TryGetValue(path, out var adapted)) File.WriteAllBytes(dst, adapted);
            else File.Copy(path, dst, true);
            deployed.Add(dst);
            scripts++;
            continue;
        }

        int mh = lower.IndexOf("r6/config/redsuserhints/", StringComparison.Ordinal);
        if (mh >= 0)
        {
            var dst = Path.Combine(gameDir, "r6", "config", "redsUserHints", rel.Substring(mh + "r6/config/redsuserhints/".Length));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(path, dst, true); deployed.Add(dst); scripts++; continue;
        }

        // c) red4ext/plugins/** CONFIG (not native binaries - mods ship Windows .dll, useless on mac).
        int mp = lower.IndexOf("red4ext/plugins/", StringComparison.Ordinal);
        if (mp >= 0)
        {
            var pluginPath = rel.Substring(mp + "red4ext/plugins/".Length);
            var pluginName = pluginPath.Split('/')[0];
            if (native25 && new[] { "Codeware", "ArchiveXL", "TweakXL" }.Contains(pluginName, StringComparer.OrdinalIgnoreCase))
            {
                Console.WriteLine($"[INSTALL] {pluginName} is supplied by NightCity Console for native 2.5; preserving its tested files.");
                skipped++; continue;
            }
            if (name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
                name.EndsWith(".dylib", StringComparison.OrdinalIgnoreCase) ||
                name.EndsWith(".so", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"[INSTALL] skip native plugin binary (not macOS): {rel}");
                skipped++;
                continue;
            }
            var subRel = rel.Substring(mp + "red4ext/plugins/".Length);
            var dst = Path.Combine(gameDir, "red4ext", "plugins", subRel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(path, dst, true);
            deployed.Add(dst);
            plugins++;
            continue;
        }

        // Everything else (readmes, screenshots, bin/x64 CET lua, etc.) is not auto-installed here.
        skipped++;
    }

    try { if (Directory.Exists(tmpRoot)) Directory.Delete(tmpRoot, true); } catch { }
    try { if (tmpUnzip != null) Directory.Delete(tmpUnzip, true); } catch { }
    Prog(1.0, "Deploying files");

    Console.WriteLine($"[INSTALL] DONE  archives={archives} xl={xls} tweaks={tweaks} scripts={scripts} pluginCfg={plugins} skipped={skipped}");
    if (archives == 0 && tweaks == 0 && xls == 0 && scripts == 0 && plugins == 0)
    {
        Console.Error.WriteLine("[INSTALL] nothing installed - is this a standard mod (archive/ + r6/tweaks/ ...)?");
        return 1;
    }

    // Per-mod manifest (the app tracks installed mods + does accurate uninstall from this file list).
    if (!string.IsNullOrEmpty(manifestOut))
    {
        var opts = new System.Text.Json.JsonSerializerOptions { WriteIndented = true };
        var manifest = new Dictionary<string, object>
        {
            ["name"] = modName,
            ["source"] = Path.GetFileName(src.TrimEnd('/', '\\')),
            ["files"] = deployed,
        };
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(manifestOut))!);
        File.WriteAllText(manifestOut, System.Text.Json.JsonSerializer.Serialize(manifest, opts));
        Console.WriteLine($"[INSTALL] manifest -> {manifestOut} ({deployed.Count} files)");
    }
    return 0;
}

// ---------------------------------------------------------------------------
// factories: GENERAL, mod-agnostic. Unpack any archive, find every factory CSV
// (a C2dArray with name/path columns - the ArchiveXL FactoryIndex source), and dump
// its (entityName -> root.ent path) rows to a flat config the gadget reseal reads.
// Output: one "entityName<TAB>rootEntPath" per line, depot paths VERBATIM (backslash,
// as stored) so the reseal's FNV1a64(lower(path)) ResourcePath matches the engine.
// This replaces the bikini-hardcoded WANT/ROOTENT so ANY mod's new items resolve.
// ---------------------------------------------------------------------------
int Factories(string srcArchive, string looseDir, string outConfig)
{
    Unpack(srcArchive, looseDir);

    var rows = new List<(string name, string path)>();
    int csvCount = 0, factoryCsv = 0;
    foreach (var csvPath in Directory.EnumerateFiles(looseDir, "*.csv", SearchOption.AllDirectories))
    {
        csvCount++;
        C2dArray? arr = null;
        try
        {
            using var ms = new MemoryStream(File.ReadAllBytes(csvPath));
            using var cr = new CR2WReader(ms);
            cr.ParsingError += a => true;
            if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk is not C2dArray c2d) continue;
            arr = c2d;
        }
        catch (Exception e) { Console.WriteLine($"  [csv-skip] {Path.GetFileName(csvPath)}: {e.GetType().Name} {e.Message}"); continue; }

        // Locate the name/path columns. ArchiveXL factory CSVs use headers "name","path";
        // fall back to the first two columns if headers are absent/oddly named.
        // On-disk binary C2dArray populates CompiledHeaders/CompiledData (read via the
        // appendix); the Headers/Data props are only filled by the text CSV importer.
        var headers = (arr.CompiledHeaders ?? new()).Select(h => ((string)h ?? "").Trim().ToLowerInvariant()).ToList();
        int nameCol = headers.FindIndex(h => h == "name");
        int pathCol = headers.FindIndex(h => h == "path");
        if (nameCol < 0 || pathCol < 0)
        {
            // Not obviously a factory CSV by headers. Only treat as one if exactly 2 columns.
            if (headers.Count == 2) { nameCol = 0; pathCol = 1; }
            else { Console.WriteLine($"  [csv-nonfactory] {Path.GetFileName(csvPath)} headers=[{string.Join(",", headers)}]"); continue; }
        }

        int rowsHere = 0;
        foreach (var row in arr.CompiledData ?? new())
        {
            if (row == null || row.Count <= Math.Max(nameCol, pathCol)) continue;
            var nm = ((string)row[nameCol] ?? "").Trim();
            var rp = ((string)row[pathCol] ?? "").Trim();
            if (string.IsNullOrEmpty(nm) || string.IsNullOrEmpty(rp)) continue;
            rows.Add((nm, rp));
            rowsHere++;
        }
        factoryCsv++;
        Console.WriteLine($"  [factory-csv] {csvPath.Substring(looseDir.Length).TrimStart('/','\\')}  rows={rowsHere}");
    }

    // De-dupe (keep first), MERGE with any existing config so several mods accumulate.
    var seen = new HashSet<string>();
    var outLines = new List<string>();
    if (File.Exists(outConfig))
        foreach (var line in File.ReadAllLines(outConfig))
        {
            var nm = line.Split('\t', 2)[0].Trim();
            if (nm.Length > 0 && seen.Add(nm)) outLines.Add(line);
        }
    foreach (var (nm, rp) in rows)
        if (seen.Add(nm)) outLines.Add($"{nm}\t{rp}");

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outConfig))!);
    File.WriteAllLines(outConfig, outLines);

    Console.WriteLine();
    Console.WriteLine($"[FACTORIES] scanned {csvCount} csv ({factoryCsv} factory), {rows.Count} row(s) -> {outLines.Count} unique");
    foreach (var l in outLines) Console.WriteLine($"  {l.Replace("\t", "  ->  ")}");
    Console.WriteLine($"[OUT] {outConfig}");
    return outLines.Count > 0 ? 0 : 2;
}

// ---------------------------------------------------------------------------
// loc: GENERAL, mod-agnostic. Unpack any archive, find every onscreens localization
// TextResource (a localizationPersistenceOnScreenEntries - the ArchiveXL .xl
// "localization.onscreens" source), and dump its (LocKey -> display text) entries to a
// flat JSON the cet-mac loc Frida hook reads (/tmp/cp2077_xl_loc.json).
// WHY this exists on macOS: ArchiveXL's native LoadTexts merge cannot be caught after
// the engine's one-time onscreens load (late bring-up); the engine resolves a string
// displayName by FNV1a32/FNV1a64 of the secondaryKey, so we precompute BOTH (the cet
// hook reads a uint32 key, so we emit the 32-bit fnv32 AND the low-32 of fnv64) and
// serve them at the loc-map resolver. Mirrors the factories handoff. MERGES into the
// out file so several mods accumulate. Output: { "<uint32-key>": "<text>", ... }.
// ---------------------------------------------------------------------------
int Loc(string srcArchive, string looseDir, string outJson)
{
    static uint Fnv1a32(string s)
    {
        uint h = 0x811c9dc5;
        foreach (char c in s) { h ^= (byte)c; h *= 0x01000193; }
        return h;
    }
    static ulong Fnv1a64(string s)
    {
        ulong h = 0xcbf29ce484222325;
        foreach (char c in s) { h ^= (byte)c; h *= 0x100000001b3; }
        return h;
    }

    Unpack(srcArchive, looseDir);

    // Start from the existing handoff (merge) so multiple mods accumulate into one file.
    var map = new Dictionary<string, string>();
    if (File.Exists(outJson))
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(outJson));
            foreach (var p in doc.RootElement.EnumerateObject())
                map[p.Name] = p.Value.GetString() ?? "";
        }
        catch (Exception e) { Console.WriteLine($"  [merge-skip] existing {outJson} unreadable: {e.Message}"); }
    }

    int jsonCount = 0, locRes = 0, entries = 0, added = 0;
    foreach (var jp in Directory.EnumerateFiles(looseDir, "*.json", SearchOption.AllDirectories))
    {
        jsonCount++;
        localizationPersistenceOnScreenEntries onscreens;
        try
        {
            using var ms = new MemoryStream(File.ReadAllBytes(jp));
            using var cr = new CR2WReader(ms);
            cr.ParsingError += a => true;
            if (cr.ReadFile(out var cf) != ArchiveErr.NoError) continue;
            // Onscreens are a JsonResource whose `root` handle holds the entries class.
            var os = (cf?.RootChunk as JsonResource)?.Root?.Chunk as localizationPersistenceOnScreenEntries
                     ?? cf?.RootChunk as localizationPersistenceOnScreenEntries;
            if (os == null) continue;
            onscreens = os;
        }
        catch { continue; }

        int here = 0;
        foreach (var e in onscreens.Entries ?? new())
        {
            if (e == null) continue;
            var sk = ((string)e.SecondaryKey ?? "").Trim();
            var text = (string)e.FemaleVariant;
            if (string.IsNullOrEmpty(text)) text = (string)e.MaleVariant;
            if (string.IsNullOrEmpty(text)) continue;

            // Skip ArchiveXL comment rows (secondaryKey beginning '-' or '=').
            if (sk.Length > 0 && (sk[0] == '-' || sk[0] == '=')) continue;

            var keys = new List<uint>();
            if (sk.Length > 0)
            {
                keys.Add(Fnv1a32(sk));                          // 32-bit displayName lookup hash
                keys.Add((uint)(Fnv1a64(sk) & 0xffffffff));     // low-32 of the 64-bit hash (engine key is uint64)
            }
            ulong pk = (ulong)e.PrimaryKey;
            if (pk != 0) keys.Add((uint)(pk & 0xffffffff));     // an explicit numeric primaryKey (rare for mods)
            if (keys.Count == 0) continue;

            foreach (var k in keys)
            {
                var ks = k.ToString();
                if (!map.ContainsKey(ks)) added++;
                map[ks] = text;
            }
            entries++; here++;
        }
        locRes++;
        Console.WriteLine($"  [loc-res] {jp.Substring(looseDir.Length).TrimStart('/','\\')}  entries={here}");
    }

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outJson))!);
    var opts = new System.Text.Json.JsonSerializerOptions
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    File.WriteAllText(outJson, System.Text.Json.JsonSerializer.Serialize(map, opts));

    Console.WriteLine();
    Console.WriteLine($"[LOC] scanned {jsonCount} json ({locRes} onscreens), {entries} entr(ies) -> {added} new key(s), {map.Count} total");
    Console.WriteLine($"[OUT] {outJson}");
    return entries > 0 ? 0 : 2;
}

// ---------------------------------------------------------------------------
// Track A: surgical literal-color edit without ArchiveXL DynamicAppearance.
//   Edit A (.ent): entGarmentSkinnedMeshComponent
//        Mesh.DepotPath -> "base\melgardens\swim_string\mesh\top_base_body.mesh"
//        MeshAppearance -> "black"
//   Edit B (.mesh): meshMeshAppearance Name=="black"
//        ChunkMaterials  "black@dynamic" -> "@dynamic" (binds local material idx 0)
// ---------------------------------------------------------------------------
int TrackA(string srcArchive, string looseDir, string outArchive)
{
    const string EntRel  = "base/melgardens/swim_string/paperwork/melgardens_swim_string_top.ent";
    const string MeshRel = "base/melgardens/swim_string/mesh/top_base_body.mesh";
    const string TargetMesh = "base\\melgardens\\swim_string\\mesh\\top_base_body.mesh";
    const string TargetApp  = "black";
    const string OldChunk   = "black@dynamic";
    const string NewChunk   = "dynamic";        // strip BOTH the variant prefix AND the ArchiveXL '@' marker
    const string OldMatEntry = "@dynamic";       // local materialEntry name carries the '@' SpecialMaterialMarker
    const string NewMatEntry = "dynamic";

    // 1) unpack
    Unpack(srcArchive, looseDir);

    var entPath  = Path.Combine(looseDir, EntRel.Replace('/', Path.DirectorySeparatorChar));
    var meshPath = Path.Combine(looseDir, MeshRel.Replace('/', Path.DirectorySeparatorChar));
    if (!File.Exists(entPath))  { Console.WriteLine("[FAIL] missing " + entPath);  return 2; }
    if (!File.Exists(meshPath)) { Console.WriteLine("[FAIL] missing " + meshPath); return 2; }

    // 2) Edit A — entEntityTemplate component lives in CompiledData (a RedPackage).
    // The entEntityTemplateReader populates entityTemplate.Components with the live
    // parsed component chunks; the entEntityTemplatePreProcessor rebuilds CompiledData
    // from Components on write, so mutating the live component + WriteFile persists it.
    {
        CR2WFile entFile;
        using (var ms = new MemoryStream(File.ReadAllBytes(entPath)))
        using (var cr = new CR2WReader(ms))
        {
            cr.ParsingError += a => true;
            if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk is not entEntityTemplate)
            { Console.WriteLine("[FAIL] .ent not an entEntityTemplate"); return 2; }
            entFile = cf;
        }
        var ent = (entEntityTemplate)entFile.RootChunk!;
        var comp = FindGarmentComponent(ent);
        if (comp == null) { Console.WriteLine("[FAIL] entGarmentSkinnedMeshComponent not found in Components"); return 2; }

        Console.WriteLine($"[EditA] before: mesh=\"{comp.Mesh.DepotPath.GetResolvedText()}\" meshApp=\"{comp.MeshAppearance.GetResolvedText()}\"");
        comp.Mesh = new CResourceAsyncReference<CMesh>((ResourcePath)TargetMesh);
        comp.MeshAppearance = (CName)TargetApp;
        Console.WriteLine($"[EditA] after : mesh=\"{comp.Mesh.DepotPath.GetResolvedText()}\" meshApp=\"{comp.MeshAppearance.GetResolvedText()}\"");

        using var outMs = new MemoryStream();
        using (var cw = new CR2WWriter(outMs) { LoggerService = log }) cw.WriteFile(entFile);
        File.WriteAllBytes(entPath, outMs.ToArray());
    }

    // 3) Edit B — mesh black appearance ChunkMaterials.
    {
        CR2WFile meshFile;
        using (var ms = new MemoryStream(File.ReadAllBytes(meshPath)))
        using (var cr = new CR2WReader(ms))
        {
            cr.ParsingError += a => true;
            if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk is not CMesh)
            { Console.WriteLine("[FAIL] .mesh not a CMesh"); return 2; }
            meshFile = cf;
        }
        var mesh = (CMesh)meshFile.RootChunk!;
        var black = mesh.Appearances.Select(h => h?.Chunk)
                        .FirstOrDefault(a => a != null && a.Name.GetResolvedText() == TargetApp);
        if (black == null) { Console.WriteLine("[FAIL] black appearance not found"); return 2; }

        Console.WriteLine($"[EditB] before: black.ChunkMaterials=[{string.Join(", ", black.ChunkMaterials.Select(c => c.GetResolvedText()))}]");
        for (int i = 0; i < black.ChunkMaterials.Count; i++)
            if (black.ChunkMaterials[i].GetResolvedText() == OldChunk)
                black.ChunkMaterials[i] = (CName)NewChunk;
        Console.WriteLine($"[EditB] after : black.ChunkMaterials=[{string.Join(", ", black.ChunkMaterials.Select(c => c.GetResolvedText()))}]");

        // Edit C — literalize the @dynamic material's BaseColor texture (ArchiveXL token
        // *...d_{material}.xbm -> the shipped literal d_black.xbm) so the black chunk renders
        // its real color print, not grey. The material lives in the same mesh's
        // LocalMaterialBuffer, so it re-serializes through the same WriteFile flush.
        const string BaseColorLiteral = "base\\melgardens\\swim_string\\mesh_tx\\top\\d_black.xbm";
        int matPatched = EditBaseColor(mesh, BaseColorLiteral);
        Console.WriteLine($"[EditC] BaseColor params literalized: {matPatched}");

        // Edit E — drop the ArchiveXL '@' SpecialMaterialMarker: rename the local materialEntry
        // "@dynamic" -> "dynamic" so the stock engine binds chunkMaterials "dynamic" -> local
        // material instance index 0 (the index->localMaterialBuffer link is by index, preserved).
        int meRenamed = 0;
        foreach (var me in mesh.MaterialEntries)
            if (me.Name.GetResolvedText() == OldMatEntry) { me.Name = (CName)NewMatEntry; meRenamed++; }
        Console.WriteLine($"[EditE] materialEntry '@dynamic' -> 'dynamic': {meRenamed}");

        using var outMs = new MemoryStream();
        using (var cw = new CR2WWriter(outMs) { LoggerService = log }) cw.WriteFile(meshFile);
        File.WriteAllBytes(meshPath, outMs.ToArray());
    }

    // 3b) Edit D — _root.ent: set each template-appearance entry's AppearanceName explicitly to its
    // own Name. The shipped entries have AppearanceName="None" (empty CName); ArchiveXL works around
    // that, but the STOCK engine needs an explicit .app-appearance key to pick the appearance. So
    // entry Name="melgardens_swim_string_top_" -> AppearanceName="melgardens_swim_string_top_".
    {
        var rootRel = "base/melgardens/swim_string/paperwork/melgardens_swim_string_root.ent";
        var rootPath = Path.Combine(looseDir, rootRel.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(rootPath))
        {
            CR2WFile rootFile;
            using (var ms = new MemoryStream(File.ReadAllBytes(rootPath)))
            using (var cr = new CR2WReader(ms))
            {
                cr.ParsingError += a => true;
                cr.ReadFile(out var cf);
                rootFile = cf;
            }
            if (rootFile?.RootChunk is entEntityTemplate root)
            {
                foreach (var ta in root.Appearances ?? new())
                {
                    var nm = ta.Name.GetResolvedText();
                    var an = ta.AppearanceName.GetResolvedText();
                    if (!string.IsNullOrEmpty(nm) && (string.IsNullOrEmpty(an) || an == "None"))
                    {
                        ta.AppearanceName = ta.Name;
                        Console.WriteLine($"[EditD] _root.ent entry \"{nm}\": AppearanceName \"{an}\" -> \"{nm}\"");
                    }
                }
                using var outMs = new MemoryStream();
                using (var cw = new CR2WWriter(outMs) { LoggerService = log }) cw.WriteFile(rootFile);
                File.WriteAllBytes(rootPath, outMs.ToArray());
            }
        }
    }

    // 4) repack
    Pack(looseDir, outArchive);

    // 5) VALIDATE — re-open the packed archive and re-parse both files from it.
    bool pass = true;
    var details = new System.Text.StringBuilder();
    var vr = new ArchiveReader();
    if (vr.ReadArchive(outArchive, hash, out var var) != ArchiveErr.NoError)
    { Console.WriteLine("TRACKA-VALIDATE: FAIL (could not re-read packed archive)"); return 2; }

    var files = var.Files.Values.OfType<FileEntry>().ToList();

    // ---- validate Edit A from packed archive ----
    {
        var fe = files.FirstOrDefault(f => f.Name.Replace('\\','/').EndsWith(EntRel));
        if (fe == null) { pass = false; details.AppendLine("  .ent missing from packed archive"); }
        else
        {
            var ms = new MemoryStream(); fe.Extract(ms); ms.Position = 0;
            using var cr = new CR2WReader(ms); cr.ParsingError += a => true;
            cr.ReadFile(out var cf);
            var ent = cf?.RootChunk as entEntityTemplate;
            var comp = ent != null ? FindGarmentComponent(ent) : null;
            var mp = comp?.Mesh.DepotPath.GetResolvedText();
            var ma = comp?.MeshAppearance.GetResolvedText();
            details.AppendLine($"  .ent component: Mesh.DepotPath=\"{mp}\"  MeshAppearance=\"{ma}\"");
            if (mp != TargetMesh) { pass = false; details.AppendLine($"    EXPECTED Mesh.DepotPath=\"{TargetMesh}\""); }
            if (ma != TargetApp)  { pass = false; details.AppendLine($"    EXPECTED MeshAppearance=\"{TargetApp}\""); }
        }
    }

    // ---- validate Edit B from packed archive ----
    {
        var fe = files.FirstOrDefault(f => f.Name.Replace('\\','/').EndsWith(MeshRel));
        if (fe == null) { pass = false; details.AppendLine("  .mesh missing from packed archive"); }
        else
        {
            var ms = new MemoryStream(); fe.Extract(ms); ms.Position = 0;
            using var cr = new CR2WReader(ms); cr.ParsingError += a => true;
            cr.ReadFile(out var cf);
            var mesh = cf?.RootChunk as CMesh;
            var black = mesh?.Appearances.Select(h => h?.Chunk)
                            .FirstOrDefault(a => a != null && a.Name.GetResolvedText() == TargetApp);
            var cms = black?.ChunkMaterials.Select(c => c.GetResolvedText()).ToList() ?? new();
            details.AppendLine($"  .mesh black.ChunkMaterials=[{string.Join(", ", cms)}]");
            if (cms.Count == 0 || cms.Any(c => c != NewChunk))
            { pass = false; details.AppendLine($"    EXPECTED all == \"{NewChunk}\""); }

            // ALSO: crack open the @dynamic local material for the texture report.
            ReportLocalMaterial(mesh);

            // validate Edit C — BaseColor must be a literal (no ArchiveXL * or {} token) after repack.
            var baseColor = ReadBaseColor(mesh);
            details.AppendLine($"  .mesh @dynamic BaseColor=\"{baseColor}\"");
            if (baseColor == null || baseColor.Contains('*') || baseColor.Contains('{'))
            { pass = false; details.AppendLine("    EXPECTED literal BaseColor (no * / {token})"); }
        }
    }

    Console.WriteLine();
    Console.WriteLine($"TRACKA-VALIDATE: {(pass ? "PASS" : "FAIL")}");
    Console.Write(details.ToString());
    Console.WriteLine($"[OUT] {outArchive}  size={new FileInfo(outArchive).Length} bytes");
    return pass ? 0 : 3;
}

// REPLACER: build a mesh-override archive that swaps the bikini top mesh onto a base-game pushup-tank
// item (Items.Undershirt_02_*). Equipping the vanilla item then renders the bikini via the stock garment
// pipeline (no ArchiveXL/factory/new-item needed). Literalize the mesh + add the meshAppearance names the
// target component requests + pack at the target depot path with the bikini textures.
int Replacer(string srcArchive, string looseDir, string outArchive)
{
    // base-game pushup tank (t1_undershirt_02) mesh path + the meshAppearance names its component requests
    const string TargetMeshRel = "base/characters/garment/player_equipment/torso/t1_047_tank__pushup/t1_047_pwa_tank__pushup.mesh";
    string[] TargetApps = { "default", "black_gold", "purple_yellow", "panther", "black_pink", "black" };
    var BikiniMeshRel = "base/melgardens/swim_string/mesh/top_base_body.mesh";
    var TexRel = new[] {
        "base/melgardens/swim_string/mesh_tx/top/d_black.xbm",
        "base/melgardens/swim_string/mesh_tx/top/top_n.xbm",
        "base/melgardens/swim_string/mesh_tx/top/top_m.xbm",
        "base/melgardens/swim_string/mesh_tx/top/top_r.xbm",
    };

    Unpack(srcArchive, looseDir);
    var bikiniMeshPath = Path.Combine(looseDir, BikiniMeshRel.Replace('/', Path.DirectorySeparatorChar));
    if (!File.Exists(bikiniMeshPath)) { Console.WriteLine("[FAIL] bikini mesh missing: " + bikiniMeshPath); return 2; }

    // load + literalize the bikini mesh (same edits as trackA EditB/C/E) and ADD the target appearance names
    CR2WFile meshFile;
    using (var ms = new MemoryStream(File.ReadAllBytes(bikiniMeshPath)))
    using (var cr = new CR2WReader(ms))
    {
        cr.ParsingError += a => true;
        if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk is not CMesh) { Console.WriteLine("[FAIL] not a CMesh"); return 2; }
        meshFile = cf;
    }
    var mesh = (CMesh)meshFile.RootChunk!;
    // rename materialEntry @dynamic -> dynamic
    foreach (var me in mesh.MaterialEntries) if (me.Name.GetResolvedText() == "@dynamic") me.Name = (CName)"dynamic";
    // black appearance: chunkMaterials -> dynamic
    var black = mesh.Appearances.Select(h => h?.Chunk).FirstOrDefault(a => a != null && a.Name.GetResolvedText() == "black");
    if (black == null) { Console.WriteLine("[FAIL] black appearance not found"); return 2; }
    for (int i = 0; i < black.ChunkMaterials.Count; i++)
        if (black.ChunkMaterials[i].GetResolvedText() != "dynamic") black.ChunkMaterials[i] = (CName)"dynamic";
    EditBaseColor(mesh, "base\\melgardens\\swim_string\\mesh_tx\\top\\d_black.xbm");
    // ADD an appearance per target name (clone black's chunkMaterials = ["dynamic","dynamic"])
    int added = 0;
    foreach (var name in TargetApps)
    {
        if (mesh.Appearances.Any(h => h?.Chunk?.Name.GetResolvedText() == name)) continue;
        var app = new meshMeshAppearance { Name = (CName)name };
        app.ChunkMaterials = new CArray<CName>();
        foreach (var cm in black.ChunkMaterials) app.ChunkMaterials.Add((CName)(cm.GetResolvedText() ?? "dynamic"));
        mesh.Appearances.Add(new CHandle<meshMeshAppearance>(app));
        added++;
    }
    Console.WriteLine($"[Replacer] literalized + added {added} target appearances (chunkMaterials per app = {black.ChunkMaterials.Count})");

    // write the edited mesh into a pack folder, AT THE TARGET DEPOT PATH
    var packDir = looseDir + "_pack";
    if (Directory.Exists(packDir)) Directory.Delete(packDir, true);
    var outMeshPath = Path.Combine(packDir, TargetMeshRel.Replace('/', Path.DirectorySeparatorChar));
    Directory.CreateDirectory(Path.GetDirectoryName(outMeshPath)!);
    using (var outMs = new MemoryStream())
    {
        using (var cw = new CR2WWriter(outMs) { LoggerService = log }) cw.WriteFile(meshFile);
        File.WriteAllBytes(outMeshPath, outMs.ToArray());
    }
    Console.WriteLine($"[Replacer] wrote bikini mesh -> {TargetMeshRel}");

    // copy the bikini textures the material references (NOT in base game) into the pack folder
    int tex = 0;
    foreach (var tr in TexRel)
    {
        var src = Path.Combine(looseDir, tr.Replace('/', Path.DirectorySeparatorChar));
        var dst = Path.Combine(packDir, tr.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(src)) { Directory.CreateDirectory(Path.GetDirectoryName(dst)!); File.Copy(src, dst, true); tex++; }
        else Console.WriteLine($"  [warn] texture missing in bikini archive: {tr}");
    }
    Console.WriteLine($"[Replacer] copied {tex}/{TexRel.Length} textures");

    Pack(packDir, outArchive);
    Console.WriteLine($"[Replacer] DONE -> {outArchive}");
    Console.WriteLine("  give+equip a base-game pushup tank: Items.Undershirt_02_basic_01 / _basic_02 / _rich_01 / _rich_02");
    return 0;
}

entGarmentSkinnedMeshComponent? FindGarmentComponent(entEntityTemplate ent)
{
    foreach (var c in ent.Components ?? new())
        if (c is entGarmentSkinnedMeshComponent g) return g;
    return null;
}

// Read the BaseColor texture path from the first embedded CMaterialInstance (for validation).
string? ReadBaseColor(CMesh? mesh)
{
    var mats = mesh?.LocalMaterialBuffer?.Materials;
    if (mats == null) return null;
    foreach (var mobj in mats)
    {
        if (mobj is not CMaterialInstance mi) continue;
        var vals = mi.GetType().GetProperty("Values")?.GetValue(mi) as System.Collections.IEnumerable;
        if (vals == null) continue;
        foreach (var kv in vals)
        {
            if (kv == null) continue;
            var key = kv.GetType().GetProperty("Key")?.GetValue(kv);
            var keyStr = key?.GetType().GetMethod("GetResolvedText")?.Invoke(key, null) as string ?? key?.ToString();
            if (keyStr != "BaseColor") continue;
            var val = kv.GetType().GetProperty("Value")?.GetValue(kv);
            var dp = val?.GetType().GetProperty("DepotPath")?.GetValue(val);
            return dp?.GetType().GetMethod("GetResolvedText")?.Invoke(dp, null) as string;
        }
    }
    return null;
}

// Replace the BaseColor texture param of every embedded CMaterialInstance with a literal path.
// Values is surfaced via reflection (same as ReportLocalMaterial); the param value is a resource
// reference type whose DepotPath is a readonly struct getter, so we reconstruct the ref via its
// own runtime ctor(ResourcePath). Returns the count of params patched.
int EditBaseColor(CMesh mesh, string literalPath)
{
    int patched = 0;
    var mats = mesh.LocalMaterialBuffer?.Materials;
    if (mats == null) return 0;
    foreach (var mobj in mats)
    {
        if (mobj is not CMaterialInstance mi) continue;
        var vals = mi.GetType().GetProperty("Values")?.GetValue(mi) as System.Collections.IEnumerable;
        if (vals == null) continue;
        foreach (var kv in vals)
        {
            if (kv == null) continue;
            var keyProp = kv.GetType().GetProperty("Key");
            var valProp = kv.GetType().GetProperty("Value");
            var key = keyProp?.GetValue(kv);
            var keyStr = key?.GetType().GetMethod("GetResolvedText")?.Invoke(key, null) as string ?? key?.ToString();
            if (keyStr != "BaseColor") continue;
            var existing = valProp?.GetValue(kv);
            if (existing == null || valProp == null) continue;
            var vt = existing.GetType();                       // e.g. CResourceReference<ITexture>
            var newRef = System.Activator.CreateInstance(vt, (ResourcePath)literalPath);
            valProp.SetValue(kv, newRef);
            patched++;
        }
    }
    return patched;
}

void ReportLocalMaterial(CMesh? mesh)
{
    Console.WriteLine();
    Console.WriteLine("## LOCAL @dynamic MATERIAL REPORT");
    var lmb = mesh?.LocalMaterialBuffer;
    var mats = lmb?.Materials;
    if (mats == null || mats.Count == 0)
    {
        Console.WriteLine("  (no parsed materials in LocalMaterialBuffer.Materials)");
        return;
    }
    foreach (var m in mats)
    {
        if (m is not CMaterialInstance mi) { Console.WriteLine($"  material is {m?.GetType().Name}, not CMaterialInstance"); continue; }
        var bm = mi.BaseMaterial.DepotPath.GetResolvedText();
        Console.WriteLine($"  CMaterialInstance baseMaterial=\"{bm}\"");
        // Values is a dynamic property added at parse time -> reflect it.
        var valsProp = mi.GetType().GetProperty("Values");
        var vals = valsProp?.GetValue(mi) as System.Collections.IEnumerable;
        int n = 0;
        if (vals != null)
        {
            foreach (var kv in vals)
            {
                n++;
                var keyProp = kv?.GetType().GetProperty("Key");
                var valProp = kv?.GetType().GetProperty("Value");
                var key = keyProp?.GetValue(kv);
                var val = valProp?.GetValue(kv);
                string keyStr = key?.ToString() ?? "?";
                string valStr = DescribeParam(val);
                Console.WriteLine($"    param[{n - 1}] {keyStr} = {valStr}");
            }
        }
        if (n == 0) Console.WriteLine("    (no Values params -> empty template; chunk renders untextured/grey)");
    }
}

string DescribeParam(object? val)
{
    if (val == null) return "null";
    var t = val.GetType();
    // rRef<*> / resource refs expose DepotPath
    var dp = t.GetProperty("DepotPath");
    if (dp != null)
    {
        try
        {
            var path = dp.GetValue(val);
            var resolved = path?.GetType().GetMethod("GetResolvedText")?.Invoke(path, null) as string;
            return $"{t.Name}(\"{resolved}\")";
        }
        catch { }
    }
    return $"{t.Name}({val})";
}

void MeshMat(string meshFile)
{
    using var ms = File.OpenRead(meshFile);
    MeshMatStream(ms, meshFile);
}

// Extract every mesh from an archive whose depot name contains nameSubstr and dump its materials.
void MeshMatArc(string archivePath, string nameSubstr)
{
    var reader = new ArchiveReader();
    if (reader.ReadArchive(archivePath, hash, out var ar) != ArchiveErr.NoError)
        throw new Exception("failed to read archive " + archivePath);
    foreach (var f in ar.Files.Values.OfType<FileEntry>())
    {
        if (!f.Name.EndsWith(".mesh", StringComparison.OrdinalIgnoreCase)) continue;
        if (nameSubstr.Length > 0 && !f.Name.Contains(nameSubstr, StringComparison.OrdinalIgnoreCase)) continue;
        var ms = new MemoryStream();
        f.Extract(ms);
        ms.Position = 0;
        MeshMatStream(ms, f.Name);
        Console.WriteLine();
    }
}

void MeshMatStream(Stream ms, string meshFile)
{
    using var cr = new CR2WReader(ms);
    cr.ParsingError += a => true;
    if (cr.ReadFile(out var cf) != ArchiveErr.NoError || cf?.RootChunk is not WolvenKit.RED4.Types.CMesh mesh)
    {
        Console.WriteLine("not a CMesh: " + (cf?.RootChunk?.GetType().Name ?? "null"));
        return;
    }
    Console.WriteLine($"# MESH: {meshFile}");
    Console.WriteLine($"appearances: {mesh.Appearances.Count}");
    foreach (var h in mesh.Appearances)
    {
        var a = h?.Chunk; if (a == null) continue;
        var cms = (a.ChunkMaterials ?? new()).Select(c => c.GetResolvedText() ?? c.ToString());
        Console.WriteLine($"  [{a.Name.GetResolvedText()}] chunkMaterials=[{string.Join(", ", cms)}]");
    }
    Console.WriteLine($"materialEntries: {mesh.MaterialEntries.Count}");
    foreach (var me in mesh.MaterialEntries)
        Console.WriteLine($"  name=\"{me.Name.GetResolvedText()}\" index={me.Index} isLocalInstance={me.IsLocalInstance}");
    Console.WriteLine($"externalMaterials: {mesh.ExternalMaterials.Count}");
    foreach (var em in mesh.ExternalMaterials)
        Console.WriteLine($"  ext -> {em.DepotPath.GetResolvedText()}");
    Console.WriteLine($"preloadExternalMaterials: {mesh.PreloadExternalMaterials.Count}");
    foreach (var em in mesh.PreloadExternalMaterials)
        Console.WriteLine($"  preExt -> {em.DepotPath.GetResolvedText()}");
    Console.WriteLine($"localMaterialInstances: {mesh.LocalMaterialInstances.Count}");
    foreach (var lm in mesh.LocalMaterialInstances)
        Console.WriteLine($"  local -> {lm?.Chunk?.GetType().Name} baseMat={(lm?.Chunk as WolvenKit.RED4.Types.CMaterialInstance)?.BaseMaterial.DepotPath.GetResolvedText()}");
    Console.WriteLine($"preloadLocalMaterialInstances: {mesh.PreloadLocalMaterialInstances.Count}");
    foreach (var lm in mesh.PreloadLocalMaterialInstances)
        Console.WriteLine($"  preLocal -> {lm?.Chunk?.GetType().Name} baseMat={(lm?.Chunk as WolvenKit.RED4.Types.CMaterialInstance)?.BaseMaterial.DepotPath.GetResolvedText()}");
    var lmb = mesh.LocalMaterialBuffer;
    Console.WriteLine($"localMaterialBuffer: {(lmb == null ? "null" : "present")} headers={lmb?.RawDataHeaders?.Count} materials={lmb?.Materials?.Count}");
    // Map buffer index -> materialEntry name (materialEntries.Index points into the buffer).
    var idxToName = new Dictionary<int, string>();
    foreach (var me in mesh.MaterialEntries)
        if (me.IsLocalInstance) idxToName[(int)me.Index] = me.Name.GetResolvedText() ?? "";
    if (lmb?.Materials != null)
    {
        for (int i = 0; i < lmb.Materials.Count; i++)
        {
            var nm = idxToName.TryGetValue(i, out var n) ? n : "?";
            if (lmb.Materials[i] is WolvenKit.RED4.Types.CMaterialInstance mi)
            {
                Console.WriteLine($"  MAT[{i}] name=\"{nm}\" base={mi.BaseMaterial.DepotPath.GetResolvedText()} mask={mi.EnableMask} values={mi.Values.Count}");
                bool dumpVals = _matValFilter.Length > 0 && nm.Contains(_matValFilter, StringComparison.OrdinalIgnoreCase);
                if (dumpVals)
                    foreach (var kv in mi.Values)
                    {
                        var v = kv.Value;
                        string vs = v switch
                        {
                            WolvenKit.RED4.Types.IRedResourceReference rr => "res:" + rr.DepotPath.GetResolvedText(),
                            _ => v?.ToString() ?? "null"
                        };
                        Console.WriteLine($"       {kv.Key} = {vs}");
                    }
            }
            else Console.WriteLine($"  MAT[{i}] name=\"{nm}\" {lmb.Materials[i]?.GetType().Name ?? "null"}");
        }
    }
}

sealed class StubHashService : IHashService
{
    public Task Loaded => Task.CompletedTask;
    public void Load() { }
    public bool Contains(ulong key, bool checkUserHashes = true) => false;
    public string? Get(ulong key) => null;
    public IEnumerable<ulong> GetAllHashes() => Array.Empty<ulong>();
    public IEnumerable<ulong> GetMissingHashes() => Array.Empty<ulong>();
    public string? GetGuessedExtension(ulong key) => null;
}

sealed class ConsoleLog : ILoggerService
{
    public LoggerVerbosity LoggerVerbosity => LoggerVerbosity.Diagnostic;
    public void SetLoggerVerbosity(LoggerVerbosity v) { }
    public void Info(string s) => Console.WriteLine("[INFO] " + s);
    public void Warning(string s) => Console.WriteLine("[WARN] " + s);
    public void Error(string s) => Console.WriteLine("[ERR ] " + s);
    public void Success(string s) => Console.WriteLine("[ OK ] " + s);
    public void Debug(string s) { }
    public void Error(Exception e) => Console.WriteLine("[EXC ] " + e.Message);
}
