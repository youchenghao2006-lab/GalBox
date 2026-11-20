import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let fm = FileManager.default
private let accent = Color(red: 0.65, green: 0.55, blue: 1)

enum GalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Game: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var executable: String
    var locale: String
    var imported: Date
    var lastPlayed: Date?
    var graphics: String?
}

struct Candidate: Identifiable {
    var path: String
    var score: Int
    var id: String { path }
}

final class Engine: @unchecked Sendable {
    let root: URL
    let wine: URL
    let server: URL
    let seven: URL
    let games: URL
    let logs: URL

    init(root: URL) {
        self.root = root
        let wineRoot = root.appendingPathComponent("Runtime/Wine Staging.app/Contents/Resources/wine")
        wine = wineRoot.appendingPathComponent("bin/wine")
        server = wineRoot.appendingPathComponent("bin/wineserver")
        seven = root.appendingPathComponent("Runtime/7zip/7zz")
        games = root.appendingPathComponent("Games")
        logs = root.appendingPathComponent("Logs")
    }

    func prepare() throws {
        for url in [games, logs, root.appendingPathComponent("work/imports")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard fm.isExecutableFile(atPath: wine.path), fm.isExecutableFile(atPath: seven.path) else {
            throw GalError.message("运行组件不完整。请把 GalBox.app 与 Runtime 文件夹放在一起，再打开应用。")
        }
    }

    func gameDir(_ game: Game) -> URL { games.appendingPathComponent(game.id) }
    func content(_ game: Game) -> URL { gameDir(game).appendingPathComponent("Files") }
    func usesMetal(_ game: Game) -> Bool { game.graphics == "metal" }
    func prefix(_ game: Game) -> URL { gameDir(game).appendingPathComponent(usesMetal(game) ? "Prefix-Graphics" : "Prefix") }
    func wineURL(_ game: Game) -> URL { wine }
    func serverURL(_ game: Game) -> URL { server }
    var metalAvailable: Bool {
        ["x64", "x32"].allSatisfy { arch in
            ["d3d11.dll", "d3d10core.dll"].allSatisfy { module in
                fm.isReadableFile(atPath: root.appendingPathComponent("Runtime/DXVK/\(arch)/\(module)").path)
            }
        }
    }

    func environment(_ game: Game) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix(game).path
        env["WINEARCH"] = "win64"
        env["WINEDEBUG"] = "-all,err+all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        if usesMetal(game) {
            env["WINEDLLOVERRIDES"] = "d3d11,d3d10core=n,b;dxgi=b;" + env["WINEDLLOVERRIDES"]!
            env["DXVK_LOG_PATH"] = logs.path
            env["DXVK_LOG_LEVEL"] = "info"
            env["DXVK_STATE_CACHE_PATH"] = gameDir(game).appendingPathComponent("ShaderCache").path
            env["DXVK_CONFIG"] = "dxvk.enableAsync = False"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        }
        env["LANG"] = game.locale
        env["LC_ALL"] = game.locale
        env["PATH"] = wineURL(game).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let gst = root.appendingPathComponent("Runtime/Frameworks/GStreamer.framework/Versions/1.0")
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = root.appendingPathComponent("Runtime/Frameworks").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = gst.appendingPathComponent("lib").path + ":/usr/lib"
        env["DYLD_LIBRARY_PATH"] = gst.appendingPathComponent("lib").path + ":" + wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib").path
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gst.appendingPathComponent("lib/gstreamer-1.0").path
        env["GST_PLUGIN_SCANNER"] = gst.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
        env["GST_REGISTRY"] = gameDir(game).appendingPathComponent("gstreamer-registry.bin").path
        env["TMPDIR"] = root.appendingPathComponent("work").path + "/"
        return env
    }

    @discardableResult
    func run(_ executable: URL, _ arguments: [String], env: [String: String]? = nil,
             cwd: URL? = nil, log: URL, timeout: TimeInterval = 600) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = cwd
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        try output.seekToEnd()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            throw GalError.message("操作耗时过长，已停止等待。请查看日志，或换一个压缩包重试。")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func logText(_ log: URL) -> String { (try? Data(contentsOf: log)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func candidates(in dir: URL) -> [Candidate] {
        guard let walk = fm.enumerator(atPath: dir.path) else { return [] }
        var result: [Candidate] = []
        for case let relative as String in walk {
            let url = dir.appendingPathComponent(relative)
            if url.lastPathComponent.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let lower = relative.lowercased()
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if lower.contains("__macosx/") || lower.contains("/windows/") { continue }
            var score = 100 - relative.filter { $0 == "/" }.count * 3
            if ["unins", "uninstall", "setup", "install", "redist", "vcredist", "dxsetup", "crash", "config", "setting", "patch", "update", "readme", "notification"].contains(where: { name.contains($0) }) { score -= 200 }
            if ["game", "start", "launch", "krkr", "siglus", "reallive", "advhd"].contains(where: { name.contains($0) }) { score += 15 }
            if lower.contains("redist/") || lower.contains("support/") { score -= 100 }
            result.append(Candidate(path: relative, score: score))
        }
        return result.sorted { $0.score == $1.score ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : $0.score > $1.score }
    }

    private func isInside(_ item: URL, _ directory: URL) throws -> Bool {
        var relationship = FileManager.URLRelationship.other
        try fm.getRelationship(&relationship, ofDirectoryAt: directory, toItemAt: item)
        return relationship == .contains || relationship == .same
    }

    private func validateImportSource(_ source: URL, isDirectory: Bool) throws {
        if isDirectory, try isInside(root, source) {
            throw GalError.message("这个文件夹包含 GalBox 自己。请选择单个游戏文件夹。")
        }
        for name in ["Runtime", "Games", "work", "Source", "Logs", "GalBox.app"] {
            let managed = root.appendingPathComponent(name)
            if fm.fileExists(atPath: managed.path), try isInside(source, managed) {
                throw GalError.message("请选择下载的游戏压缩包或游戏文件夹。")
            }
        }
    }

    // FileManager preserves symbolic links when copying folders, including dangling links.
    private func validateImportedTree(_ directory: URL) throws {
        var readError: Error?
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let walk = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            readError = error
            return false
        }) else { throw GalError.message("无法读取游戏文件夹。") }
        for case let entry as URL in walk {
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw GalError.message("游戏目录中包含链接或特殊文件，请使用包含实际资源文件的游戏包。")
            }
        }
        if let readError { throw readError }
    }

    func importGame(_ selected: URL, password: String, progress: @escaping (String) -> Void) throws -> (Game, [Candidate]) {
        try prepare()
        let source = selected.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw GalError.message("找不到这个文件。") }
        try validateImportSource(source, isDirectory: isDir.boolValue)
        let id = UUID().uuidString.lowercased()
        let staging = root.appendingPathComponent("work/imports/" + id)
        let files = staging.appendingPathComponent("Files")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: staging) } }
        if isDir.boolValue {
            progress("正在复制游戏文件夹…")
            try fm.removeItem(at: files)
            try fm.copyItem(at: source, to: files)
        } else if source.pathExtension.lowercased() == "exe" {
            throw GalError.message("请导入这个 EXE 所在的整个游戏文件夹，确保图片、音频、剧本等资源一起保留。")
        } else {
            let ext = source.pathExtension.lowercased()
            guard ["zip", "rar", "7z", "001", "tar", "gz", "xz", "bz2"].contains(ext) else {
                throw GalError.message("请拖入 ZIP、RAR、7z 压缩包或游戏文件夹。分卷请拖入 .part1.rar 或 .001，并把其余分卷放在旁边。")
            }
            progress("正在检查压缩包…")
            let checkLog = logs.appendingPathComponent("import-" + id + "-check.log")
            let pass = password.isEmpty ? "-p" : "-p" + password
            let listing = try run(seven, ["l", "-slt", pass, "--", source.path], log: checkLog, timeout: 300)
            let listingText = logText(checkLog)
            guard listing == 0 else { throw GalError.message("无法读取压缩包。若有密码，请先在导入区填入密码；分卷需要全部放在同一个文件夹。") }
            // Reject traversal and links before extraction. 7-Zip also rejects traversal by default.
            let entries = listingText.components(separatedBy: "----------").dropFirst().joined(separator: "----------")
            for line in entries.components(separatedBy: .newlines) {
                if line.hasPrefix("Path = ") {
                    let path = String(line.dropFirst(7)).replacingOccurrences(of: "\\", with: "/")
                    if path.hasPrefix("/") || path.split(separator: "/").contains("..") || path.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
                        throw GalError.message("压缩包包含不安全的文件路径，无法导入。")
                    }
                }
                if line.hasPrefix("Symbolic Link = ") || line.hasPrefix("Hard Link = ") {
                    throw GalError.message("压缩包包含链接，请先手动解压，再导入游戏文件夹。")
                }
            }
            progress("正在解压游戏，大型压缩包可能需要几分钟…")
            let extractLog = logs.appendingPathComponent("import-" + id + ".log")
            let status = try run(seven, ["x", "-y", "-aoa", "-snl-", "-snh-", pass, "-o" + files.path, "--", source.path], log: extractLog, timeout: 3600)
            guard status == 0 else {
                throw GalError.message("解压未完成：密码错误、分卷缺失或压缩包损坏。请检查后重试；详细信息在 Logs 文件夹。")
            }
        }
        progress("正在识别游戏主程序…")
        try validateImportedTree(files)
        let options = candidates(in: files)
        guard !options.isEmpty else { throw GalError.message("解压后没有找到 Windows .exe 程序。若压缩包里还有另一层压缩包，请把里面的游戏压缩包拖进来。") }
        let name = source.pathExtension.lowercased() == "exe" ? source.deletingLastPathComponent().lastPathComponent : source.deletingPathExtension().lastPathComponent
        let game = Game(id: id, name: name, executable: options[0].path, locale: "ja_JP.UTF-8", imported: Date(), graphics: metalAvailable ? "metal" : "compatibility")
        try fm.moveItem(at: staging, to: games.appendingPathComponent(id))
        success = true
        return (game, options)
    }

    func initialize(_ game: Game, progress: @escaping (String) -> Void) throws {
        if usesMetal(game) {
            guard metalAvailable else { throw GalError.message("增强图形组件不完整，请切换为兼容模式。") }
            let oldPrefix = gameDir(game).appendingPathComponent("Prefix")
            if !fm.fileExists(atPath: prefix(game).path), fm.fileExists(atPath: oldPrefix.path) {
                progress("正在为增强图形模式保留原环境与存档…")
                let staging = gameDir(game).appendingPathComponent(".prefix-" + UUID().uuidString)
                defer { try? fm.removeItem(at: staging) }
                try fm.copyItem(at: oldPrefix, to: staging)
                let oldMarker = staging.appendingPathComponent(".galbox-ready")
                if fm.fileExists(atPath: oldMarker.path) { try fm.removeItem(at: oldMarker) }
                try fm.moveItem(at: staging, to: prefix(game))
            }
            try fm.createDirectory(at: gameDir(game).appendingPathComponent("ShaderCache"), withIntermediateDirectories: true)
        }
        let ready = prefix(game).appendingPathComponent(".galbox-ready")
        guard !fm.fileExists(atPath: ready.path) else { return }
        progress("首次启动：正在准备独立运行环境…")
        let log = logs.appendingPathComponent(game.id + "-init.log")
        let code = try run(wineURL(game), ["wineboot", "-u"], env: environment(game), log: log, timeout: 180)
        guard code == 0 else { throw GalError.message("Windows 兼容环境初始化失败。请打开日志查看原因。") }
        guard try run(serverURL(game), ["-w"], env: environment(game), log: log, timeout: 120) == 0 else {
            throw GalError.message("运行环境未能完成初始化，请查看日志。")
        }
        if usesMetal(game) {
            for (architecture, directory) in [("x64", "system32"), ("x32", "syswow64")] {
                for module in ["d3d11.dll", "d3d10core.dll"] {
                    let source = root.appendingPathComponent("Runtime/DXVK/" + architecture + "/" + module)
                    let target = prefix(game).appendingPathComponent("drive_c/windows/" + directory + "/" + module)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                }
            }
        }
        // Keep shell folders and saves within this game's prefix.
        let users = prefix(game).appendingPathComponent("drive_c/users")
        guard try isInside(users.resolvingSymlinksInPath(), prefix(game)) else {
            throw GalError.message("Windows 用户目录指向了运行环境以外的位置。")
        }
        for user in try fm.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let info = try user.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
            for child in try fm.contentsOfDirectory(at: user, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    try fm.removeItem(at: child)
                    try fm.createDirectory(at: child, withIntermediateDirectories: true)
                }
            }
        }
        // Map the UI language before first game launch.
        let languages: [String: (String, String)] = ["ja_JP.UTF-8": ("00000411", "ja-JP"), "zh_CN.UTF-8": ("00000804", "zh-CN"), "en_US.UTF-8": ("00000409", "en-US")]
        if let lang = languages[game.locale] {
            for pair in [("Locale", lang.0), ("LocaleName", lang.1)] {
                _ = try run(wineURL(game), ["reg", "add", "HKCU\\Control Panel\\International", "/v", pair.0, "/d", pair.1, "/f"], env: environment(game), log: log, timeout: 60)
            }
        }
        _ = try run(serverURL(game), ["-w"], env: environment(game), log: log, timeout: 60)
        try Data().write(to: ready)
    }

    func save(_ library: [Game]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }

    func load() throws -> [Game] {
        let url = root.appendingPathComponent("library.json")
        if !fm.fileExists(atPath: url.path) { return [] }
        let library = try JSONDecoder().decode([Game].self, from: Data(contentsOf: url))
        guard library.allSatisfy({ UUID(uuidString: $0.id) != nil }), Set(library.map(\.id)).count == library.count else {
            throw GalError.message("游戏库编号无效或重复。请检查 library.json 或恢复备份。")
        }
        return library
    }

    func executableURL(_ game: Game) throws -> URL {
        let files = content(game)
        let exe = files.appendingPathComponent(game.executable).resolvingSymlinksInPath()
        guard exe.pathExtension.lowercased() == "exe",
              (try? exe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              try isInside(exe, files.resolvingSymlinksInPath()) else {
            throw GalError.message("游戏目录中找不到所选主程序 \(game.executable)，请重新选择。")
        }
        return exe
    }
}

@MainActor final class Library: ObservableObject {
    let engine: Engine
    @Published var games: [Game] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var status = "准备好迎接下一段故事"
    @Published var error: String?
    @Published var notice: String?
    @Published var password = ""
    @Published var choosing: Game?
    @Published var options: [Candidate] = []
    @Published var chosenPath = ""
    @Published var running = Set<String>()
    var launchAfterChoosing = false
    private var startupError: String?

    init() {
        engine = Engine(root: Bundle.main.bundleURL.deletingLastPathComponent())
        do { try engine.prepare(); games = try engine.load() }
        catch { startupError = error.localizedDescription; self.error = startupError }
    }

    var current: Game? { games.first { $0.id == selected } }
    func persist() {
        if let startupError { self.error = startupError; return }
        do { try engine.save(games) } catch { self.error = "游戏库保存失败：" + error.localizedDescription }
    }

    func removeFromLibrary(_ game: Game) {
        guard !busy, !running.contains(game.id) else { return }
        games.removeAll { $0.id == game.id }
        selected = nil
        persist()
        status = "已移出游戏库，游戏文件与存档仍保留在 Games 文件夹"
    }

    func checkRuntime() {
        guard !busy else { return }
        busy = true
        status = "正在检查 32 位与 64 位 Windows 运行环境…"
        let engine = engine
        let game = current ?? Game(id: "runtime-smoke-test", name: "运行环境检查", executable: "cmd.exe", locale: "ja_JP.UTF-8", imported: Date())
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fm.createDirectory(at: engine.gameDir(game), withIntermediateDirectories: true)
                try engine.initialize(game) { text in DispatchQueue.main.async { self.status = text } }
                let log = engine.logs.appendingPathComponent("runtime-check.log")
                try Data().write(to: log)
                for (path, marker) in [("C:\\windows\\system32\\cmd.exe", "GALBOX_WIN64_OK"), ("C:\\windows\\syswow64\\cmd.exe", "GALBOX_WIN32_OK")] {
                    let result = try engine.run(engine.wineURL(game), [path, "/c", "echo " + marker], env: engine.environment(game), log: log, timeout: 60)
                    guard result == 0, engine.logText(log).contains(marker) else { throw GalError.message("运行环境检查未通过，请打开 runtime-check.log 查看原因。") }
                }
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "运行环境检查通过 · 支持启动 32 位与 64 位 Windows 程序"
                    self.notice = "32 位和 64 位 Windows 程序均已成功执行。具体游戏的兼容性仍取决于游戏引擎和所需组件。"
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription } }
        }
    }

    func importURL(_ url: URL) {
        guard !busy else { return }
        if let startupError { error = startupError; return }
        busy = true
        status = "正在导入 " + url.lastPathComponent
        let pass = password
        let engine = engine
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (game, candidates) = try engine.importGame(url, password: pass) { text in
                    DispatchQueue.main.async { self.status = text }
                }
                DispatchQueue.main.async {
                    self.games.insert(game, at: 0)
                    self.selected = game.id
                    self.persist()
                    self.busy = false
                    self.password = ""
                    let viable = candidates.filter { $0.score > 0 }
                    if viable.count == 1 {
                        self.play(game)
                    } else {
                        self.options = candidates
                        self.chosenPath = game.executable
                        self.launchAfterChoosing = true
                        self.choosing = game
                        self.status = "请选择一次游戏主程序，之后会记住"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "导入未完成"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func openPanel(folder: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        panel.message = folder ? "选择包含游戏主程序和资源的整个文件夹" : "选择游戏压缩包；分卷请选择第一卷"
        panel.prompt = "导入游戏"
        if panel.runModal() == .OK, let url = panel.url { importURL(url) }
    }

    func chooseExecutable(_ game: Game) {
        options = engine.candidates(in: engine.content(game))
        chosenPath = game.executable
        launchAfterChoosing = false
        choosing = game
    }

    func confirmExecutable() {
        guard var game = choosing, let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        game.executable = chosenPath
        games[index] = game
        persist()
        choosing = nil
        if launchAfterChoosing { play(game) }
    }

    func play(_ game: Game) {
        guard !busy, !running.contains(game.id) else { return }
        busy = true
        running.insert(game.id)
        if let index = games.firstIndex(where: { $0.id == game.id }) { games[index].lastPlayed = Date(); persist() }
        let engine = engine
        status = "正在启动 " + game.name
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let exe = try engine.executableURL(game)
                try engine.initialize(game) { text in DispatchQueue.main.async { self.status = text } }
                let log = engine.logs.appendingPathComponent(game.id + "-game.log")
                if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(("\n=== " + Date().description + " | " + game.executable + " | " + (game.graphics ?? "compatibility") + " ===\n").utf8))
                let process = Process()
                process.executableURL = engine.wineURL(game)
                process.arguments = [exe.path]
                process.environment = engine.environment(game)
                process.currentDirectoryURL = exe.deletingLastPathComponent()
                process.standardOutput = handle
                process.standardError = handle
                process.standardInput = FileHandle.nullDevice
                let started = Date()
                try process.run()
                DispatchQueue.main.async { self.busy = false; self.status = "游戏已启动 · " + game.name }
                process.waitUntilExit()
                _ = try? engine.run(engine.serverURL(game), ["-w"], env: engine.environment(game), log: log, timeout: 86400)
                DispatchQueue.main.async {
                    self.running.remove(game.id)
                    self.status = "游戏已结束 · 存档已保留"
                    if process.terminationStatus != 0 {
                        self.error = "游戏未能正常启动或运行（退出码 \(process.terminationStatus)）。可尝试切换启动程序，或查看日志确认缺少的组件。"
                    } else if Date().timeIntervalSince(started) < 8 {
                        self.status = "程序很快结束；如未出现游戏窗口，请查看日志或更换主程序"
                    }
                }
            } catch {
                DispatchQueue.main.async { self.running.remove(game.id); self.busy = false; self.status = "启动未完成"; self.error = error.localizedDescription }
            }
        }
    }

    func stop(_ game: Game) {
        let engine = engine
        DispatchQueue.global().async {
            _ = try? engine.run(engine.serverURL(game), ["-k"], env: engine.environment(game), log: engine.logs.appendingPathComponent(game.id + "-game.log"), timeout: 15)
        }
    }

    func configure(_ game: Game) {
        guard !busy, !running.contains(game.id) else { return }
        busy = true
        let engine = engine
        DispatchQueue.global().async {
            do {
                try engine.initialize(game) { text in DispatchQueue.main.async { self.status = text } }
                DispatchQueue.main.async { self.busy = false; self.status = "已打开 Windows 设置" }
                _ = try engine.run(engine.wineURL(game), ["winecfg"], env: engine.environment(game), log: engine.logs.appendingPathComponent(game.id + "-config.log"), timeout: 3600)
            } catch { DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription } }
        }
    }

    func changeLocale(_ value: String, game: Game) {
        guard !running.contains(game.id), let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].locale = value
        try? fm.removeItem(at: engine.prefix(game).appendingPathComponent(".galbox-ready"))
        persist()
        status = "下次启动会应用新的语言环境"
    }

    func changeGraphics(_ value: String, game: Game) {
        guard !busy, !running.contains(game.id), let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].graphics = value
        persist()
        status = value == "metal" ? "下次启动使用增强图形模式" : "下次启动使用兼容图形模式"
    }
}

struct DropZone: View {
    @ObservedObject var library: Library
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(accent.opacity(0.12)).frame(width: 80, height: 80)
                Image(systemName: "shippingbox.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(accent)
                Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(.white, accent).offset(x: 30, y: 28)
            }
            Text(library.busy ? "正在为你准备游戏" : "把整个游戏压缩包拖到这里")
                .font(.system(size: 23, weight: .semibold))
            Text("ZIP / RAR / 7z · 自动解压 · 独立存档")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("选择压缩包") { library.openPanel() }.buttonStyle(PurpleButton())
                Button("导入文件夹") { library.openPanel(folder: true) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.disabled(library.busy)
            HStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(.secondary)
                SecureField("压缩包密码（如有）", text: $library.password)
                    .textFieldStyle(.plain).frame(width: 195)
            }.font(.system(size: 12)).padding(10).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .disabled(library.busy)
            Text("分卷压缩包：把所有分卷放在一起，拖入第一卷")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 35)
        .background(targeted ? accent.opacity(0.13) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(targeted ? accent : Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !library.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { library.importURL(url) } }
            }
            return true
        }
    }
}

struct PurpleButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 11)
            .background(accent.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(Color(red: 0.12, green: 0.09, blue: 0.22))
    }
}

struct MainView: View {
    @ObservedObject var library: Library
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 27)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GalBox").font(.system(size: 22, weight: .bold))
                        Text("故事，从这里开始").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 15)
                Button { library.selected = nil } label: {
                    Label("导入游戏", systemImage: "plus.square.on.square").frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(library.selected == nil ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).foregroundStyle(library.selected == nil ? accent : .white)
                HStack {
                    Text("我的游戏").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(library.games.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(library.games) { game in
                            Button { library.selected = game.id } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: library.running.contains(game.id) ? "play.circle.fill" : "gamecontroller.fill").foregroundStyle(accent)
                                    Text(game.name).font(.system(size: 12)).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(library.selected == game.id ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                        if library.games.isEmpty { Text("第一段故事，等你添加").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 10) }
                    }
                }
                Button { NSWorkspace.shared.open(library.engine.root) } label: { Label("打开 GalBox 文件夹", systemImage: "folder").font(.system(size: 11)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                Text("Apple Silicon · Wine 11.18").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(22).frame(width: 225).background(Color(red: 0.075, green: 0.075, blue: 0.11))
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(library.current == nil ? "下一段故事，拖进来就好。" : library.current!.name)
                            .font(.system(size: 27, weight: .bold)).lineLimit(2)
                        Text(library.current == nil ? "把 Windows Galgame 带到你的 Mac。" : "你的游戏、资源与存档，都在一起。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("GALGAME / MAC").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(accent.opacity(0.8))
                }.padding(.top, 22)
                if let game = library.current {
                    gameCard(game)
                } else {
                    DropZone(library: library)
                    HStack(alignment: .top, spacing: 24) {
                        tip("01", "拖入整包", "资源文件一起保留")
                        tip("02", "自动准备", "每个游戏独立运行")
                        tip("03", "开始故事", "下次从游戏库直达")
                    }.padding(.horizontal, 5)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if library.busy { ProgressView().controlSize(.small) }
                    else { Circle().fill(library.running.isEmpty ? Color.green.opacity(0.8) : accent).frame(width: 6, height: 6) }
                    Text(library.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("日志") { NSWorkspace.shared.open(library.engine.logs) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(13).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                Text("兼容性因游戏而异；安装版需先运行安装程序，再选择游戏主程序。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 32).padding(.bottom, 22).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, minHeight: 650)
        .background(Color(red: 0.105, green: 0.10, blue: 0.15))
        .preferredColorScheme(.dark)
        .alert("需要处理一下", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("打开日志") { NSWorkspace.shared.open(library.engine.logs); library.error = nil }
            Button("知道了", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(item: $library.choosing) { game in
            VStack(alignment: .leading, spacing: 18) {
                Text("选择游戏主程序").font(.system(size: 22, weight: .bold))
                Text("\(game.name)\n选择后会记住；请优先选择游戏本体，避开卸载和配置程序。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(library.options) { option in
                            Button { library.chosenPath = option.path } label: {
                                HStack {
                                    Image(systemName: library.chosenPath == option.path ? "largecircle.fill.circle" : "circle").foregroundStyle(accent)
                                    Text(option.path).font(.system(size: 12)).lineLimit(2)
                                    Spacer()
                                    if option.score < 0 { Text("辅助程序").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 260)
                HStack {
                    Button("稍后再选") { library.choosing = nil }.buttonStyle(.plain)
                    Spacer()
                    Button(library.launchAfterChoosing ? "记住并启动" : "保存选择") { library.confirmExecutable() }.buttonStyle(PurpleButton())
                }
            }.padding(28).frame(width: 540).preferredColorScheme(.dark)
        }
        .alert("运行环境检查通过", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("完成", role: .cancel) { library.notice = nil }
        } message: { Text(library.notice ?? "") }
        .onOpenURL { library.importURL($0) }
    }

    func tip(_ number: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    func gameCard(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [accent.opacity(0.22), Color.pink.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(height: 155)
                Image(systemName: "moon.stars.fill").font(.system(size: 62)).foregroundStyle(accent)
            }
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("启动程序").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(game.executable).font(.system(size: 12)).lineLimit(2)
                }
                Spacer()
                Button("更换") { library.chooseExecutable(game) }.disabled(library.busy || library.running.contains(game.id))
            }
            HStack {
                Text("语言环境").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { game.locale }, set: { library.changeLocale($0, game: game) })) {
                    Text("日语（推荐日文原版）").tag("ja_JP.UTF-8")
                    Text("简体中文（部分汉化版）").tag("zh_CN.UTF-8")
                    Text("英语").tag("en_US.UTF-8")
                }.labelsHidden().frame(width: 235).disabled(library.busy || library.running.contains(game.id))
                Spacer()
            }
            HStack {
                Text("图形模式").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { game.graphics ?? "compatibility" }, set: { library.changeGraphics($0, game: game) })) {
                    Text("增强模式（推荐 DX10 / DX11）").tag("metal")
                    Text("兼容模式（较老的游戏）").tag("compatibility")
                }.labelsHidden().frame(width: 270).disabled(library.busy || library.running.contains(game.id))
                Spacer()
            }
            HStack(spacing: 15) {
                if library.running.contains(game.id) {
                    Label("游戏运行中", systemImage: "play.fill").foregroundStyle(accent)
                    Button("结束游戏") { library.stop(game) }
                } else {
                    Button { library.play(game) } label: { Label("开始游戏", systemImage: "play.fill") }.buttonStyle(PurpleButton()).disabled(library.busy)
                }
                Button("游戏文件") { NSWorkspace.shared.open(library.engine.content(game)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Menu("更多") {
                    Button("Windows 设置 / 虚拟桌面") { library.configure(game) }
                    Button("打开存档与运行环境") { NSWorkspace.shared.open(library.engine.prefix(game)) }
                    Button("打开日志") { NSWorkspace.shared.open(library.engine.logs) }
                    Divider()
                    Button("移出游戏库（保留文件与存档）") { library.removeFromLibrary(game) }
                        .disabled(library.busy || library.running.contains(game.id))
                }.menuStyle(.borderlessButton).frame(width: 55)
            }.font(.system(size: 12))
            Text("汉化版出现乱码时，可尝试简体中文环境。每次关闭游戏后会保留原来的文件与存档。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(25).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct GalBoxScene: App {
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup("GalBox") { MainView(library: library) }
            .defaultSize(width: 1020, height: 710)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("导入游戏压缩包…") { library.openPanel() }.keyboardShortcut("o")
                    Button("导入游戏文件夹…") { library.openPanel(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                }
                CommandGroup(after: .help) {
                    Button("检查运行环境") { library.checkRuntime() }.disabled(library.busy)
                }
            }
    }
}

@main struct GalBoxMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest(); print("SELF-TEST PASS"); exit(0) }
            catch { fputs("SELF-TEST FAIL: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--runtime-test") {
            do { try runtimeTest(); print("RUNTIME-TEST PASS"); exit(0) }
            catch { fputs("RUNTIME-TEST FAIL: \(error)\n", stderr); exit(1) }
        }
        GalBoxScene.main()
    }

    static func selfTest() throws {
        let installed = Bundle.main.bundleURL.deletingLastPathComponent()
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GalBox-test-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("GalBox")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Runtime"), withDestinationURL: installed.appendingPathComponent("Runtime").resolvingSymlinksInPath())
        let engine = Engine(root: root)
        try engine.prepare()
        let fixture = scratch.appendingPathComponent("TestFixtures")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let nested = fixture.appendingPathComponent("日本語のゲーム")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let stub = Data([0x4d, 0x5a])
        try stub.write(to: nested.appendingPathComponent("Game.exe"))
        try stub.write(to: nested.appendingPathComponent("unins000.exe"))
        try Data("resource".utf8).write(to: nested.appendingPathComponent("scenario.dat"))
        let ranked = engine.candidates(in: fixture)
        guard ranked.first?.path.hasSuffix("Game.exe") == true, ranked.last!.score < 0 else { throw GalError.message("Executable ranking") }
        let zip = scratch.appendingPathComponent("fixture-password.zip")
        let log = engine.logs.appendingPathComponent("self-test.log")
        guard try engine.run(engine.seven, ["a", "-tzip", "-pgalbox-test", zip.path, nested.lastPathComponent], cwd: fixture, log: log) == 0 else { throw GalError.message("Fixture archive") }
        let (game, candidates) = try engine.importGame(zip, password: "galbox-test", progress: { print($0) })
        defer { try? fm.removeItem(at: engine.gameDir(game)) }
        guard candidates.count == 2, fm.fileExists(atPath: engine.content(game).appendingPathComponent("日本語のゲーム/scenario.dat").path) else { throw GalError.message("Archive import / Unicode / resource preservation") }
        do {
            _ = try engine.importGame(zip, password: "wrong-password", progress: { _ in })
            throw GalError.message("Wrong password accepted")
        } catch GalError.message(let message) where message.contains("解压") || message.contains("读取") { }
        do {
            _ = try engine.importGame(scratch, password: "", progress: { _ in })
            throw GalError.message("Accepted an ancestor of the import staging folder")
        } catch GalError.message(let message) where message.contains("包含 GalBox") { }
        let link = nested.appendingPathComponent("external")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        do {
            _ = try engine.importGame(nested, password: "", progress: { _ in })
            throw GalError.message("Accepted a linked game resource")
        } catch GalError.message(let message) where message.contains("链接或特殊文件") { }
        let staged = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("work/imports").path)
        guard staged.isEmpty else { throw GalError.message("Partial import left in staging") }
        _ = try engine.executableURL(game)
        var outside = game
        outside.executable = "../../outside.exe"
        try stub.write(to: engine.games.appendingPathComponent("outside.exe"))
        do {
            _ = try engine.executableURL(outside)
            throw GalError.message("Accepted an executable outside the game directory")
        } catch GalError.message(let message) where message.contains("重新选择") { }
        print("Encrypted ZIP, Unicode, resources, ranking, password cleanup, recursive import, symbolic links, executable containment: PASS")
    }

    static func runtimeTest() throws {
        let engine = Engine(root: Bundle.main.bundleURL.deletingLastPathComponent())
        let game = Game(id: "runtime-smoke-test", name: "运行环境自检", executable: "cmd.exe", locale: "ja_JP.UTF-8", imported: Date())
        try engine.prepare()
        try fm.createDirectory(at: engine.gameDir(game), withIntermediateDirectories: true)
        try engine.initialize(game, progress: { print($0) })
        let log = engine.logs.appendingPathComponent("runtime-smoke-test.log")
        for (path, marker) in [("C:\\windows\\system32\\cmd.exe", "GALBOX_WIN64_OK"), ("C:\\windows\\syswow64\\cmd.exe", "GALBOX_WIN32_OK")] {
            let code = try engine.run(engine.wine, [path, "/c", "echo " + marker], env: engine.environment(game), log: log, timeout: 60)
            guard code == 0, engine.logText(log).contains(marker) else { throw GalError.message("Failed: " + marker) }
            print(marker)
        }
        _ = try engine.run(engine.server, ["-w"], env: engine.environment(game), log: log, timeout: 60)
        print("Windows 32-bit + 64-bit processes: PASS")
    }
}
