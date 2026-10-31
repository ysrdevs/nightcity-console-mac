import Foundation
import CryptoKit
import Darwin

// Preparation is read-only with respect to the game. The backend revalidates the
// approved report and every source/destination before committing the whole batch.
struct ModImportPreparationReport: Codable {
    struct File: Codable, Identifiable {
        let source: String
        let destination: String
        let sha256: String
        let size: Int64
        var id: String { destination }
    }
    struct SourceFile: Codable { let path: String; let sha256: String; let size: Int64 }
    struct Skipped: Codable { let path: String; let reason: String; let blocking: Bool }
    struct Issue: Codable { let code: String; let message: String; let blocking: Bool }
    let schema: Int
    let packageName: String
    let sourceName: String
    let sourceFingerprint: String
    let gameVersion: String
    let gameRoot: String
    let gameInfoSHA256: String
    let files: [File]
    let sourceFiles: [SourceFile]
    let skipped: [Skipped]
    let issues: [Issue]
    var preparedAt: String? = nil
}

struct ModPreparedImport {
    let report: ModImportPreparationReport
    let workspace: URL
    let receiptName: String
    init(report: ModImportPreparationReport, workspace: URL, receiptName: String? = nil) {
        self.report = report
        self.workspace = workspace
        self.receiptName = receiptName ?? report.packageName + ".json"
    }
}

enum ModImportDependencyStatus: String { case installed = "Installed", selected = "Selected in this batch", missing = "Missing", optional = "Optional" }
struct ModImportDependency: Identifiable {
    let id: String
    let name: String
    let status: ModImportDependencyStatus
    let reason: String
    let evidence: [String]
}
struct ModImportReviewIssue: Identifiable {
    let code: String
    let message: String
    let blocking: Bool
    var id: String { code + ":" + message }
}
struct ModImportPackageReview: Identifiable {
    let id: String
    let name: String
    let files: [ModImportPreparationReport.File]
    var dependencies: [ModImportDependency]
    var issues: [ModImportReviewIssue]
    let identifiedMod: String?
    let version: String?
}
struct ModImportBatchReview {
    let packages: [ModImportPackageReview]
    let issues: [ModImportReviewIssue]
    let gameVersion: String?
    var canInstall: Bool { !packages.isEmpty && fileCount > 0 && !issues.contains(where: \.blocking) && !packages.contains { $0.issues.contains(where: \.blocking) } }
    var fileCount: Int { packages.reduce(0) { $0 + $1.files.count } }
    var totalBytes: Int64 { packages.flatMap(\.files).reduce(0) { value, file in value + max(0, min(file.size, 8 * 1024 * 1024 * 1024)) } }
}

enum ModImportReview {
    private static let fm = FileManager.default
    private static let maxScripts = 4096
    private static let maxScriptBytes = 2 * 1024 * 1024
    private static let maxScanBytes = 32 * 1024 * 1024
    private static let names = ["redscript": "redscript", "red4ext": "RED4ext", "archivexl": "ArchiveXL", "tweakxl": "TweakXL", "codeware": "Codeware", "inputloader": "Input Loader", "modsettings": "Mod Settings", "va": "Virtual Atelier", "equipmentex": "Equipment-EX", "cyberwareex": "Cyberware-EX"]
    private static let nativeFiles = [
        "redscript": ["engine/tools/scc", "engine/tools/libscc_lib.dylib"],
        "red4ext": ["red4ext/RED4ext.dylib"],
        "archivexl": ["red4ext/plugins/ArchiveXL/ArchiveXL.dylib"],
        "tweakxl": ["red4ext/plugins/TweakXL/TweakXL.dylib"],
        "codeware": ["red4ext/plugins/Codeware/Codeware.dylib"],
        "inputloader": ["red4ext/plugins/input_loader/input_loader.dylib"],
        "modsettings": ["red4ext/plugins/ModSettings/ModSettings.dylib"]
    ]
    private struct Need { let key: String; let reason: String; let evidence: String; let conditions: [[Token]] }
    private struct Facts { var modules = Set<String>(); var cores = Set<String>(); var needs = [Need]() }
    private struct Inventory { var modules = Set<String>(); var cores = Set<String>(); var issues = [ModImportReviewIssue]() }

    static func analyze(_ inputs: [ModPreparedImport], gameRoot: URL) -> ModImportBatchReview {
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        var global = [ModImportReviewIssue]()
        var gameVersion: String?
        var gameHash: String?
        do {
            let info = try read(root: root, relative: "Cyberpunk2077.app/Contents/Info.plist", limit: 1024 * 1024)
            guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty else { throw Failure("Game version is missing from Info.plist") }
            gameVersion = version; gameHash = hash(info)
        } catch { global.append(issue("game-inspection", "Cannot inspect the selected game: \(error.localizedDescription)", true)) }
        if inputs.count > 128 { return ModImportBatchReview(packages: [], issues: [issue("batch-limit", "Select at most 128 mod packages in one batch.", true)], gameVersion: gameVersion) }
        let installed = inventory(root: root)
        global += installed.issues
        var packages = [ModImportPackageReview]()
        var allNeeds = [[Need]]()
        var facts = [Facts]()
        var destinations = [(key: String, path: String, index: Int)]()
        var receipts = [String: Int]()

        for (index, input) in inputs.enumerated() {
            let report = input.report
            let label = report.packageName.isEmpty ? report.sourceName : report.packageName
            var issues = report.issues.map { issue($0.code, "\(label): \($0.message)", $0.blocking) }
            issues += report.skipped.map { issue("skipped-file", "\(label): \($0.path): \($0.reason)", $0.blocking) }
            var own = Facts()
            var needs = [Need]()
            if report.schema != 1 || report.files.count > 10000 || report.sourceFiles.count > 20000 || !validHash(report.sourceFingerprint) || !validHash(report.gameInfoSHA256) {
                issues.append(issue("invalid-report", "\(label): preparation report is invalid or exceeds review limits.", true))
            }
            if URL(fileURLWithPath: report.gameRoot).resolvingSymlinksInPath().standardizedFileURL != root || report.gameVersion != gameVersion || report.gameInfoSHA256 != gameHash {
                issues.append(issue("game-changed", "\(label): preparation targets a different game or game version (prepared \(report.gameVersion), current \(gameVersion ?? "unknown")). Prepare it again.", true))
            }
            if report.files.isEmpty { issues.append(issue("empty-package", "\(label): no installable files were prepared.", true)) }
            let receipt = input.receiptName
            if !safePath(receipt) || receipt.contains("/") || !receipt.lowercased().hasSuffix(".json") {
                issues.append(issue("invalid-receipt", "\(label): the installation receipt name is invalid.", true))
            } else {
                let key = folded(receipt)
                if let other = receipts[key] {
                    issues.append(issue("receipt-conflict", "\(label) and \(inputs[other].report.packageName) would share the same installation receipt.", true))
                } else { receipts[key] = index }
                if let conflict = existingConflict(root: root, relative: "red4ext/nightcity/mods/" + receipt) {
                    issues.append(issue("existing-receipt", "\(label): an installation receipt already exists or cannot be safely inspected (\(conflict)). Remove the previous managed package first.", true))
                }
            }
            if report.sourceFiles.contains(where: { !safePath($0.path) || !validHash($0.sha256) || $0.size < 0 }) {
                issues.append(issue("invalid-source-inventory", "\(label): original package inventory is invalid.", true))
            }
            var scriptBytes = 0
            var scriptCount = 0
            for file in report.files.prefix(10000) {
                guard safePath(file.source), safePath(file.destination), validHash(file.sha256), file.size >= 0, file.size <= 8 * 1024 * 1024 * 1024 else {
                    issues.append(issue("invalid-file", "\(label): an unsafe path, size or hash occurs in the prepared file list.", true)); continue
                }
                let lower = folded(file.destination)
                if protected(file.destination) { issues.append(issue("protected-runtime", "\(label): \(file.destination) belongs to NightCity's managed runtime or is outside supported mod folders.", true)) }
                if let conflict = existingConflict(root: root, relative: file.destination) {
                    issues.append(issue("existing-file", "\(label): \(file.destination) conflicts with an existing game file or path (\(conflict)). Nothing will be overwritten.", true))
                }
                destinations.append((folded(file.destination), file.destination, index))
                func require(_ key: String, _ why: String) { needs.append(Need(key: key, reason: why, evidence: file.destination, conditions: [])) }
                if lower.hasPrefix("r6/scripts/"), lower.hasSuffix(".reds") {
                    require("redscript", "Contains redscript source")
                    do {
                        scriptCount += 1
                        guard scriptCount <= maxScripts else { throw Failure("too many scripts for a complete review") }
                        let data = try read(root: input.workspace.resolvingSymlinksInPath(), relative: file.source, limit: maxScriptBytes)
                        scriptBytes += data.count
                        guard scriptBytes <= maxScanBytes, Int64(data.count) == file.size, hash(data) == file.sha256,
                              let source = String(data: data, encoding: .utf8) else { throw Failure("script snapshot changed, is too large, or is not UTF-8") }
                        let parsed = try parse(source, path: file.destination)
                        own.modules.formUnion(parsed.modules); own.cores.formUnion(parsed.cores); needs += parsed.needs
                    } catch { issues.append(issue("script-inspection", "\(label): cannot completely inspect \(file.destination): \(error.localizedDescription)", true)) }
                }
                if lower.hasPrefix("r6/tweaks/") { require("tweakxl", "Contains TweakXL data") }
                if lower.hasSuffix(".xl") { require("archivexl", "Contains ArchiveXL metadata") }
                if lower.hasPrefix("r6/input/"), lower.hasSuffix(".xml") { require("inputloader", "Contains an input mapping XML") }
            }
            let nativeNeeds = needs.filter { nativeFiles[$0.key] != nil && $0.key != "redscript" && $0.key != "red4ext" }
            needs += nativeNeeds.map { Need(key: "red4ext", reason: "Native framework dependencies require RED4ext", evidence: $0.evidence, conditions: $0.conditions) }
            issues.append(issue("requirements-unknown", "\(label): requirements are not fully known. Check the author's page; detected dependencies do not establish macOS compatibility.", false))
            if !own.cores.isEmpty { issues.append(issue("version-unverified", "\(label): recognized \(own.cores.sorted().compactMap { names[$0] }.joined(separator: ", ")), but its version and complete package have not been verified.", false)) }
            facts.append(own); allNeeds.append(needs)
            packages.append(ModImportPackageReview(id: input.workspace.path, name: label, files: report.files, dependencies: [], issues: unique(issues), identifiedMod: own.cores.sorted().compactMap { names[$0] }.first, version: nil))
        }

        // Check every ancestor, not only sorted neighbors (a, a-b, a/child).
        let byPath = Dictionary(grouping: destinations, by: \.key)
        for key in byPath.keys.sorted() {
            let group = byPath[key]!
            if group.count > 1 {
                let owners = Set(group.map(\.index)).sorted()
                let finding = issue("batch-file-conflict", "\(owners.map { packages[$0].name }.joined(separator: ", ")) contain more than one file targeting \(group[0].path).", true)
                for owner in owners { packages[owner].issues.append(finding) }
            }
            let parts = key.split(separator: "/")
            let keys = (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
            for key in keys {
                guard let parent = byPath[key] else { continue }
                let owners = Set((parent + group).map(\.index)).sorted()
                let finding = issue("batch-file-conflict", "\(owners.map { packages[$0].name }.joined(separator: ", ")) target conflicting file/directory paths: \(parent[0].path) / \(group[0].path).", true)
                for owner in owners { packages[owner].issues.append(finding) }
            }
        }
        let modules = facts.reduce(installed.modules) { $0.union($1.modules) }
        for index in packages.indices {
            for core in facts[index].cores {
                if installed.cores.contains(core) {
                    packages[index].issues.append(issue("existing-core", "\(packages[index].name): \(names[core] ?? core) is already installed, including possibly under a renamed script folder. Keep it or remove its existing installation first.", true))
                }
                let others = facts.indices.filter { $0 != index && facts[$0].cores.contains(core) }
                if !others.isEmpty {
                    packages[index].issues.append(issue("duplicate-core", "\(packages[index].name) and \(others.map { packages[$0].name }.joined(separator: ", ")) both contain \(names[core] ?? core).", true))
                }
            }
            let grouped = Dictionary(grouping: allNeeds[index].filter { !facts[index].cores.contains($0.key) }, by: \.key)
            for key in grouped.keys.sorted() {
                let requirements = grouped[key]!
                let active = requirements.filter { $0.conditions.allSatisfy { evaluate($0, modules: modules) != false } }
                let conditionalOnly = active.isEmpty || active.allSatisfy { !$0.conditions.isEmpty && $0.conditions.contains { evaluate($0, modules: modules) == nil } }
                let status: ModImportDependencyStatus
                let reason: String
                if conditionalOnly {
                    status = .optional; reason = "Used only by a ModuleExists-guarded declaration that is inactive or could not be resolved; check the author's optional integration instructions."
                } else if let paths = nativeFiles[key], paths.allSatisfy({ nativePresent(root: root, relative: $0) }) {
                    status = .installed; reason = "\(active.first?.reason ?? "Required"). Native files are present; this does not verify API/version compatibility."
                } else if installed.cores.contains(key) {
                    status = .installed; reason = "\(active.first?.reason ?? "Required"). Its defining script is already installed; version is unverified."
                } else if facts.indices.contains(where: { $0 != index && facts[$0].cores.contains(key) }) {
                    status = .selected; reason = "\(active.first?.reason ?? "Required"). Its defining script is supplied by another selected package; that package must also pass review."
                } else {
                    status = .missing; reason = active.first?.reason ?? "Required by this package"
                    packages[index].issues.append(issue("missing-" + key, "\(packages[index].name): missing \(names[key] ?? key). \(nativeFiles[key] != nil ? "Install the supported NightCity native foundation first." : "Add the required mod to this batch or install it first.") No minimum version was inferred.", true))
                }
                packages[index].dependencies.append(ModImportDependency(id: key, name: names[key] ?? key, status: status, reason: reason, evidence: Array(Set(requirements.map(\.evidence))).sorted()))
            }
            packages[index].issues = unique(packages[index].issues)
        }
        return ModImportBatchReview(packages: packages, issues: unique(global), gameVersion: gameVersion)
    }

    private static func issue(_ code: String, _ message: String, _ blocking: Bool) -> ModImportReviewIssue { ModImportReviewIssue(code: code, message: message, blocking: blocking) }
    private static func unique(_ issues: [ModImportReviewIssue]) -> [ModImportReviewIssue] { var seen = Set<String>(); return issues.filter { seen.insert($0.id).inserted } }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func folded(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        path.split(separator: "/", omittingEmptySubsequences: false).count <= 32 &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func protected(_ path: String) -> Bool {
        let p = folded(path), parts = p.split(separator: "/").map(String.init)
        let companion = parts.last ?? ""
        let foundationAssets = ["archivexl", "codeware", "modsettings", "mod_settings", "tweakxl", "input_loader", "red4ext"]
        if foundationAssets.contains(where: { companion == $0 + ".archive" || companion == $0 + ".archive.xl" }) { return true }
        if p.hasPrefix("archive/mac/mod/") { return !(p.hasSuffix(".archive") || p.hasSuffix(".xl")) }
        if p.hasPrefix("r6/scripts/") {
            let roots: Set<String> = ["zz_nightcity_plugins", "nightcityexploration", "codeware", "archivexl", "tweakxl", "modsettings", "mod_settings", "input_loader", "red4ext"]
            return parts.count < 3 || roots.contains(parts[2]) || ["ncccollisionflightprobe.reds", "nccflightclearance.reds"].contains(parts.last ?? "")
        }
        if p.hasPrefix("r6/tweaks/") || p.hasPrefix("r6/input/") || p.hasPrefix("r6/config/redsuserhints/") { return false }
        if p.hasPrefix("red4ext/plugins/archivexl/bundle/") { return !p.hasSuffix(".xl") }
        if p.hasPrefix("red4ext/plugins/"), parts.count >= 4 {
            let foundations: Set<String> = ["codeware", "archivexl", "tweakxl", "modsettings", "input_loader", "red4ext"]
            return foundations.contains(parts[2]) || !["json", "ini", "toml", "yaml", "yml", "xml"].contains((p as NSString).pathExtension)
        }
        return true
    }
    private struct Failure: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
    private static func mode(_ path: String) -> mode_t? { var value = stat(); return lstat(path, &value) == 0 ? value.st_mode & S_IFMT : nil }
    private static func checkedURL(root: URL, relative: String) throws -> URL {
        guard safePath(relative) else { throw Failure("unsafe relative path") }
        var cursor = root
        guard mode(cursor.path) == S_IFDIR else { throw Failure("root is not an ordinary directory") }
        let parts = relative.split(separator: "/")
        for part in parts.dropLast() { cursor.appendPathComponent(String(part)); guard mode(cursor.path) == S_IFDIR else { throw Failure("missing or linked parent directory") } }
        return cursor.appendingPathComponent(String(parts.last!))
    }
    private static func read(root: URL, relative: String, limit: Int, prefixOnly: Bool = false) throws -> Data {
        let url = try checkedURL(root: root, relative: relative)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure("file cannot be opened safely") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              prefixOnly || info.st_size <= limit else { throw Failure("not a regular file or exceeds inspection limit") }
        let data = try handle.read(upToCount: prefixOnly ? limit : limit + 1) ?? Data()
        guard prefixOnly || data.count == info.st_size else { throw Failure("file changed during inspection") }
        return data
    }
    private static func nativePresent(root: URL, relative: String) -> Bool {
        guard let bytes = try? read(root: root, relative: relative, limit: 8, prefixOnly: true), bytes.count == 8 else { return false }
        return Array(bytes) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
    }
    private static func existingConflict(root: URL, relative: String) -> String? {
        guard safePath(relative) else { return "unsafe path" }
        var current = root
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard mode(current.path) == S_IFDIR else { return current.lastPathComponent + " is not an ordinary directory" }
            guard let children = try? fm.contentsOfDirectory(atPath: current.path), children.count <= 20000 else { return current.lastPathComponent + " is unreadable or too large to inspect" }
            guard let existing = children.first(where: { folded($0) == folded(part) }) else { return nil }
            current.appendPathComponent(existing)
            if index == parts.count - 1 { return existing }
        }
        return nil
    }
    private static func inventory(root: URL) -> Inventory {
        var result = Inventory()
        let relative = "r6/scripts"
        // A missing scripts directory is a normal fresh installation, not a successful scan.
        guard fm.fileExists(atPath: root.appendingPathComponent(relative).path) || mode(root.appendingPathComponent(relative).path) != nil else { return result }
        do {
            _ = try checkedURL(root: root, relative: relative + "/placeholder")
            var pending = [relative], entries = 0, bytes = 0, scripts = 0
            while let directory = pending.popLast() {
                let url = root.appendingPathComponent(directory)
                let children = try fm.contentsOfDirectory(atPath: url.path)
                entries += children.count
                guard entries <= 20000 else { throw Failure("installed script inventory exceeds the entry limit") }
                for name in children.sorted() {
                    let path = directory + "/" + name
                    let kind = mode(root.appendingPathComponent(path).path)
                    if kind == S_IFLNK { throw Failure("linked file or directory in installed scripts: \(path)") }
                    if kind == S_IFDIR { pending.append(path); continue }
                    guard path.lowercased().hasSuffix(".reds") else { continue }
                    scripts += 1
                    guard scripts <= maxScripts else { throw Failure("installed script inventory exceeds the file limit") }
                    let data = try read(root: root, relative: path, limit: maxScriptBytes)
                    bytes += data.count
                    guard bytes <= maxScanBytes, let source = String(data: data, encoding: .utf8) else { throw Failure("installed scripts exceed the size limit or are not UTF-8") }
                    let facts = try parse(source, path: path, dependencies: false)
                    result.modules.formUnion(facts.modules); result.cores.formUnion(facts.cores)
                }
            }
        } catch { result.issues.append(issue("installed-inspection", "Installed mod inspection is incomplete: \(error.localizedDescription). Resolve this before importing so duplicates and dependencies can be checked.", true)) }
        return result
    }

    // A small lexical scanner ignores comments/string examples and records the
    // scope of @if annotations. It is dependency evidence, not a redscript compiler.
    private struct Token { let value: String; let string: Bool; let line: Int }
    private static func tokenize(_ source: String) -> [Token] {
        let bytes = Array(source.utf8)
        var tokens = [Token](), i = 0, line = 1
        func asciiID(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 }
        while i < bytes.count {
            let c = bytes[i]
            if c == 10 { tokens.append(Token(value: "\n", string: false, line: line)); line += 1; i += 1; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            if c == 47, i + 1 < bytes.count, bytes[i + 1] == 47 { while i < bytes.count && bytes[i] != 10 { i += 1 }; continue }
            if c == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
                i += 2; var depth = 1
                while i < bytes.count && depth > 0 {
                    if bytes[i] == 10 { tokens.append(Token(value: "\n", string: false, line: line)); line += 1 }
                    if i + 1 < bytes.count, bytes[i] == 47, bytes[i + 1] == 42 { depth += 1; i += 2 }
                    else if i + 1 < bytes.count, bytes[i] == 42, bytes[i + 1] == 47 { depth -= 1; i += 2 }
                    else { i += 1 }
                }; continue
            }
            if c == 34 {
                i += 1; let start = i; let tokenLine = line
                while i < bytes.count && bytes[i] != 34 { if bytes[i] == 92 && i + 1 < bytes.count { i += 2 } else { if bytes[i] == 10 { line += 1 }; i += 1 } }
                tokens.append(Token(value: String(decoding: bytes[start..<i], as: UTF8.self), string: true, line: tokenLine)); if i < bytes.count { i += 1 }; continue
            }
            if asciiID(c) { let start = i; while i < bytes.count && asciiID(bytes[i]) { i += 1 }; tokens.append(Token(value: String(decoding: bytes[start..<i], as: UTF8.self), string: false, line: line)); continue }
            tokens.append(Token(value: String(UnicodeScalar(c)), string: false, line: line)); i += 1
        }
        return tokens
    }
    private static func matching(_ tokens: [Token], _ start: Int, _ open: String, _ close: String) -> Int? {
        var depth = 0
        for i in start..<tokens.count where !tokens[i].string {
            if tokens[i].value == open { depth += 1 }
            if tokens[i].value == close { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }
    private static func parse(_ source: String, path: String, dependencies: Bool = true) throws -> Facts {
        let tokens = tokenize(source)
        guard tokens.count <= 250000 else { throw Failure("script exceeds the lexical inspection limit") }
        var result = Facts(), guarded = [(Range<Int>, [Token])]()
        for i in tokens.indices {
            if tokens[i].value == "module", !tokens[i].string {
                var j = i + 1, name = ""
                while j < tokens.count && tokens[j].value != "\n" && tokens[j].value != ";" { name += tokens[j].value; j += 1 }
                if !name.isEmpty { result.modules.insert(name) }
            }
            if tokens[i].value == "class", !tokens[i].string, i + 1 < tokens.count {
                if let key = ["VirtualAtelierSiteListener": "va", "EquipmentEx": "equipmentex", "CyberwareEx": "cyberwareex"][tokens[i + 1].value] { result.cores.insert(key) }
            }
            guard dependencies, tokens[i].value == "@", i + 3 < tokens.count, tokens[i + 1].value == "if", tokens[i + 2].value == "(",
                  let end = matching(tokens, i + 2, "(", ")") else { continue }
            let condition = Array(tokens[(i + 3)..<end]).filter { $0.value != "\n" }
            let begin = end + 1
            var j = begin
            while j < tokens.count {
                if tokens[j].value == "\n" { j += 1; continue }
                if tokens[j].value == "@", j + 2 < tokens.count, tokens[j + 2].value == "(", let close = matching(tokens, j + 2, "(", ")") { j = close + 1; continue }
                break
            }
            let singleLine = j < tokens.count && ["import", "module"].contains(tokens[j].value)
            var parentheses = 0, expressionBody = false, lastValue = ""
            while j < tokens.count {
                if !tokens[j].string && (tokens[j].value == ";" || (singleLine && tokens[j].value == "\n")) { j += 1; break }
                // redscript allows `func Flag() -> Bool = true` without a semicolon.
                // Its @if must not leak into the next unconditionally declared function.
                if tokens[j].value == "\n", expressionBody, parentheses == 0,
                   !["=", ".", "+", "-", "*", "/", "&", "|", "?", ":", ","].contains(lastValue) { j += 1; break }
                if !tokens[j].string && tokens[j].value == "{" { j = (matching(tokens, j, "{", "}") ?? tokens.count - 1) + 1; break }
                if !tokens[j].string {
                    if tokens[j].value == "(" { parentheses += 1 }
                    if tokens[j].value == ")" { parentheses = max(0, parentheses - 1) }
                    if tokens[j].value == "=" && parentheses == 0 { expressionBody = true }
                }
                if tokens[j].value != "\n" { lastValue = tokens[j].value }
                j += 1
            }
            if begin < j { guarded.append((begin..<j, condition)); guard guarded.count <= 1024 else { throw Failure("script exceeds the conditional inspection limit") } }
        }
        guard dependencies else { return result }
        guarded.sort { $0.0.lowerBound < $1.0.lowerBound }
        var nextGuard = 0, activeGuards = [(Range<Int>, [Token])]()
        let identifiers = ["Codeware": "codeware", "ArchiveXL": "archivexl", "TweakXL": "tweakxl", "ScriptableTweak": "tweakxl", "TweakDBManager": "tweakxl", "ModSettings": "modsettings", "VirtualAtelier": "va", "VirtualShopRegistration": "va", "EquipmentEx": "equipmentex", "CyberwareEx": "cyberwareex"]
        for i in tokens.indices {
            activeGuards.removeAll { $0.0.upperBound <= i }
            while nextGuard < guarded.count && guarded[nextGuard].0.lowerBound <= i { activeGuards.append(guarded[nextGuard]); nextGuard += 1 }
            guard activeGuards.count <= 32 else { throw Failure("script exceeds the nested conditional inspection limit") }
            let token = tokens[i]
            var key = token.string ? nil : identifiers[token.value]
            if token.string && token.value.hasPrefix("ModSettings."), i >= 2, tokens[i - 1].value == "(", tokens[i - 2].value == "runtimeProperty" { key = "modsettings" }
            guard let key else { continue }
            if i > 0 && ["module", "class"].contains(tokens[i - 1].value) { continue }
            if !token.string {
                let previous = i > 0 ? tokens[i - 1].value : ""
                let next = i + 1 < tokens.count ? tokens[i + 1].value : ""
                let typed = ["import", "extends", "<", ":", "as", "new"].contains(previous)
                let annotated = i >= 2 && previous == "(" && ["addMethod", "addField", "wrapMethod", "replaceMethod"].contains(tokens[i - 2].value)
                // A local variable named Codeware is not evidence of using its API.
                if next != "." && !typed && !annotated { continue }
            }
            // ModuleExists strings are conditions, never a mandatory import themselves.
            let conditions = activeGuards.map(\.1)
            result.needs.append(Need(key: key, reason: "Script uses \(names[key] ?? key)", evidence: "\(path):\(token.line) (\(token.value))", conditions: conditions))
        }
        return result
    }
    private static func evaluate(_ tokens: [Token], modules: Set<String>) -> Bool? {
        var index = 0
        func atom() -> Bool? {
            guard index < tokens.count else { return nil }
            if tokens[index].value == "!" { index += 1; return atom().map { !$0 } }
            if tokens[index].value == "(" { index += 1; let value = expression(); guard index < tokens.count && tokens[index].value == ")" else { return nil }; index += 1; return value }
            guard index + 3 < tokens.count, tokens[index].value == "ModuleExists", tokens[index + 1].value == "(", tokens[index + 2].string, tokens[index + 3].value == ")" else { return nil }
            let name = tokens[index + 2].value; index += 4; return modules.contains(name)
        }
        func conjunction() -> Bool? {
            var value = atom()
            while index + 1 < tokens.count && tokens[index].value == "&" && tokens[index + 1].value == "&" { index += 2; let right = atom(); if value == false || right == false { value = false } else if value == nil || right == nil { value = nil } else { value = true } }
            return value
        }
        func expression() -> Bool? {
            var value = conjunction()
            while index + 1 < tokens.count && tokens[index].value == "|" && tokens[index + 1].value == "|" { index += 2; let right = conjunction(); if value == true || right == true { value = true } else if value == nil || right == nil { value = nil } else { value = false } }
            return value
        }
        let value = expression(); return index == tokens.count ? value : nil
    }
}
