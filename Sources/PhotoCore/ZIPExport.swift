import Foundation
import Darwin

public struct ZIPSource: Sendable {
    public let root: URL
    public let archiveName: String
    public let relativePaths: [String]?
    public let requiresRegularFiles: Bool
    public init(root: URL, archiveName: String? = nil, relativePaths: [String]? = nil, requiresRegularFiles: Bool = false) {
        self.root = root
        self.archiveName = archiveName ?? (root.lastPathComponent.isEmpty ? "Archive" : root.lastPathComponent)
        self.relativePaths = relativePaths
        self.requiresRegularFiles = requiresRegularFiles
    }
}

public enum ZIPStage: String, Sendable { case scanning, preparing, archiving }
public struct ZIPProgress: Sendable {
    public let stage: ZIPStage
    public let completed: Int
    public let total: Int
    public init(stage: ZIPStage, completed: Int = 0, total: Int = 0) {
        self.stage = stage; self.completed = completed; self.total = total
    }
}

/// Shared with the UI: cancellation and publication have one linearization point.
/// A subprocess is always reaped before the worker removes its staging files.
public final class ZIPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    fileprivate func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run(); self.process = process
    }
    fileprivate func reaped() { lock.lock(); process = nil; lock.unlock() }
    fileprivate func publish(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try action()
    }
}

public struct ZIPExtensionGroup: Identifiable, Sendable {
    public let extensionName: String
    public let count: Int
    public let bytes: Int64
    public var id: String { extensionName }
    public var title: String { extensionName.isEmpty ? "Без расширения" : extensionName.uppercased() }
}

public struct ZIPScan: Sendable {
    public let source: ZIPSource
    public let groups: [ZIPExtensionGroup]
    fileprivate let items: [ZIPItem]
    public var allExtensions: Set<String> { Set(groups.map(\.extensionName)) }
    public func plan(including extensions: Set<String>, excluding destination: URL? = nil) -> ZIPPlan {
        let excluded = destination.flatMap { destination -> String? in
            guard let parent = realpath(destination.deletingLastPathComponent().path, nil) else { return nil }
            defer { free(parent) }
            return URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(destination.lastPathComponent).path
        }
        let files = items.filter { $0.kind != .directory && extensions.contains($0.extensionName) && source.root.appendingPathComponent($0.relative).path != excluded }
        let preserveEmpty = source.relativePaths == nil && extensions == allExtensions
        var parents: Set<String> = [""]
        for file in files {
            var parts = file.relative.split(separator: "/").map(String.init)
            while !parts.isEmpty { parts.removeLast(); parents.insert(parts.joined(separator: "/")) }
        }
        let directories = items.filter { $0.kind == .directory && (preserveEmpty || parents.contains($0.relative)) }
        return ZIPPlan(source: source, items: directories + files)
    }
}

public struct ZIPPlan: Sendable {
    public let source: ZIPSource
    fileprivate let items: [ZIPItem]
    public var fileCount: Int { items.filter { $0.kind != .directory }.count }
    public var byteCount: Int64 { items.filter { $0.kind != .directory }.reduce(0) { $0 + $1.fingerprint.size } }
    public var relativePaths: [String] { items.map(\.relative) }
}

private enum ZIPKind: Sendable { case file, directory, link }
private struct ZIPFingerprint: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        size = value.st_size; modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
    func matches(_ other: ZIPFingerprint, directory: Bool) -> Bool {
        if directory { return device == other.device && inode == other.inode && mode == other.mode }
        return self == other
    }
}
private struct ZIPItem: Sendable {
    let relative: String
    let kind: ZIPKind
    let fingerprint: ZIPFingerprint
    let linkTarget: String?
    var extensionName: String { URL(fileURLWithPath: relative).pathExtension.lowercased() }
}

public enum ZIPExporter {
    private static func failure(_ message: String) -> NSError { NSError(domain: "ZIPExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func systemFailure(_ action: String) -> NSError {
        failure("\(action): \(String(cString: strerror(errno)))")
    }
    private static func validRelative(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw systemFailure("Папка недоступна") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw systemFailure("Не удалось открыть папку \(url.path)") }
        return fd
    }
    private static func attributes(_ fd: Int32) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0 else { throw systemFailure("Не удалось прочитать свойства файла") }
        return result
    }
    private static func names(_ directory: Int32) throws -> [String] {
        let copied = dup(directory)
        guard copied >= 0 else { throw systemFailure("Не удалось прочитать папку") }
        guard let stream = fdopendir(copied) else { close(copied); throw systemFailure("Не удалось прочитать папку") }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw failure("Имя файла не является корректным UTF-8") }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw systemFailure("Не удалось прочитать все имена файлов") }
        return result.sorted()
    }
    static func isHidden(relativePath: String, root: URL) throws -> Bool {
        guard validRelative(relativePath) else { throw failure("Недопустимый относительный путь") }
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return true }
        var directory = try openDirectory(canonicalDirectory(root))
        defer { close(directory) }
        for (index, name) in parts.enumerated() {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemFailure("Ресурс недоступен: \(relativePath)") }
            if info.st_flags & UInt32(UF_HIDDEN) != 0 { return true }
            if index < parts.count - 1 {
                let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw systemFailure("Папка недоступна: \(relativePath)") }
                close(directory); directory = next
            }
        }
        return false
    }
    private static func inspect(parent: Int32, name: String, relative: String) throws -> ZIPItem {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemFailure("Не удалось прочитать \(relative)") }
        let type = info.st_mode & S_IFMT
        let kind: ZIPKind
        var target: String?
        switch type {
        case S_IFDIR: kind = .directory
        case S_IFREG:
            kind = .file
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw systemFailure("Файл недоступен: \(relative)") }
            defer { close(fd) }
            guard ZIPFingerprint(try attributes(fd)) == ZIPFingerprint(info) else { throw failure("Файл изменился: \(relative)") }
        case S_IFLNK:
            kind = .link
            var bytes = [CChar](repeating: 0, count: Int(info.st_size) + 1)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count else { throw systemFailure("Не удалось прочитать ссылку: \(relative)") }
            target = String(validating: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard target != nil else { throw failure("Путь ссылки не является корректным UTF-8: \(relative)") }
        default: throw failure("Тип файла не поддерживается ZIP-экспортом: \(relative)")
        }
        return ZIPItem(relative: relative, kind: kind, fingerprint: ZIPFingerprint(info), linkTarget: target)
    }

    public static func scan(_ input: ZIPSource, cancellation: ZIPCancellation = ZIPCancellation(), progress: @Sendable (ZIPProgress) -> Void = { _ in }) throws -> ZIPScan {
        try cancellation.check(); progress(ZIPProgress(stage: .scanning))
        var rootInfo = stat()
        guard lstat(input.root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw failure("Источник ZIP должен быть обычной папкой") }
        let root = try canonicalDirectory(input.root)
        guard !input.archiveName.isEmpty, validRelative(input.archiveName), !input.archiveName.contains("/") else { throw failure("Недопустимое имя корневой папки архива") }
        let source = ZIPSource(root: root, archiveName: input.archiveName, relativePaths: input.relativePaths, requiresRegularFiles: input.requiresRegularFiles)
        let fd = try openDirectory(root); defer { close(fd) }
        var items = [ZIPItem(relative: "", kind: .directory, fingerprint: ZIPFingerprint(try attributes(fd)), linkTarget: nil)]
        if let selected = source.relativePaths {
            var paths = Set<String>()
            for path in selected {
                if try isHidden(relativePath: path, root: root) { continue }
                guard validRelative(path) else { throw failure("Недопустимый относительный путь: \(path)") }
                paths.insert(path)
                var components = path.split(separator: "/").map(String.init)
                while components.count > 1 { components.removeLast(); paths.insert(components.joined(separator: "/")) }
            }
            for path in paths.sorted() {
                try cancellation.check()
                let url = root.appendingPathComponent(path)
                let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
                let item = try inspect(parent: parent, name: url.lastPathComponent, relative: path)
                if selected.contains(path), source.requiresRegularFiles, item.kind != .file { throw failure("Ресурс библиотеки не является обычным файлом: \(path)") }
                items.append(item)
                progress(ZIPProgress(stage: .scanning, completed: items.count - 1))
            }
        } else {
            func visit(_ parent: Int32, _ prefix: String) throws {
                for name in try names(parent) {
                    try cancellation.check()
                    if name.hasPrefix(".") { continue }
                    var info = stat()
                    guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemFailure("Ресурс недоступен: \(name)") }
                    if info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                    let relative = prefix.isEmpty ? name : prefix + "/" + name
                    let item = try inspect(parent: parent, name: name, relative: relative)
                    items.append(item)
                    progress(ZIPProgress(stage: .scanning, completed: items.count - 1))
                    if item.kind == .directory {
                        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw systemFailure("Папка недоступна: \(relative)") }
                        defer { close(child) }
                        guard item.fingerprint.matches(ZIPFingerprint(try attributes(child)), directory: true) else { throw failure("Папка изменена: \(relative)") }
                        try visit(child, relative)
                    }
                }
            }
            try visit(fd, "")
        }
        try cancellation.check()
        let groups = Dictionary(grouping: items.filter { $0.kind != .directory }, by: \.extensionName)
            .map { ZIPExtensionGroup(extensionName: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.fingerprint.size }) }
            .sorted { $0.extensionName < $1.extensionName }
        return ZIPScan(source: source, groups: groups, items: items)
    }

    private static func sourceDescriptor(_ item: ZIPItem, root: URL) throws -> Int32 {
        let url = item.relative.isEmpty ? root : root.appendingPathComponent(item.relative)
        let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let flags = O_RDONLY | O_CLOEXEC | (item.kind == .link ? O_SYMLINK : O_NOFOLLOW | O_NONBLOCK)
        let fd = openat(parent, url.lastPathComponent, flags)
        guard fd >= 0 else { throw systemFailure("Источник недоступен: \(item.relative)") }
        do {
            guard item.fingerprint.matches(ZIPFingerprint(try attributes(fd)), directory: item.kind == .directory) else { throw failure("Источник изменился после сканирования: \(item.relative)") }
        } catch { close(fd); throw error }
        return fd
    }
    private static func verify(_ item: ZIPItem, root: URL) throws {
        let fd = try sourceDescriptor(item, root: root); close(fd)
    }
    // Per-operation fault injection keeps regression tests deterministic without global state.
    struct TestHooks {
        var afterChunk: (URL) throws -> Void = { _ in }
        var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = { Darwin.read($0, $1, $2) }
        var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        var processStarted: (Process, URL) -> Void = { _, _ in }
    }
    private static func copy(_ item: ZIPItem, root: URL, destination: URL, cancellation: ZIPCancellation, hooks: TestHooks) throws {
        let source = try sourceDescriptor(item, root: root); defer { close(source) }
        let output: Int32
        if item.kind == .link {
            guard let target = item.linkTarget, symlink(target, destination.path) == 0 else { throw systemFailure("Не удалось сохранить ссылку") }
            output = Darwin.open(destination.path, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        } else if item.kind == .directory {
            output = try openDirectory(destination)
        } else {
            output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard output >= 0 else { throw systemFailure("Не удалось подготовить \(item.relative)") }
        defer { close(output) }
        if item.kind == .file {
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try cancellation.check()
                let count = buffer.withUnsafeMutableBytes { hooks.read(source, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw systemFailure("Ошибка чтения \(item.relative)") }
                if count == 0 { break }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes { hooks.write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                    if written < 0 { if errno == EINTR { continue }; throw systemFailure("Ошибка записи временной копии") }
                    guard written > 0 else { throw failure("Не удалось записать временную копию") }
                    offset += written
                }
                try hooks.afterChunk(root.appendingPathComponent(item.relative))
            }
        }
        try cancellation.check()
        guard fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else { throw systemFailure("Не удалось сохранить метаданные \(item.relative)") }
        guard item.fingerprint.matches(ZIPFingerprint(try attributes(source)), directory: item.kind == .directory) else { throw failure("Источник изменился во время копирования: \(item.relative)") }
        try verify(item, root: root)
    }
    private static func cleanup(_ directory: URL) {
        // Copies may inherit read-only modes/flags. Never follow staged symlinks.
        if let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in urls {
                var info = stat()
                if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK {
                    _ = chflags(url.path, 0); _ = chmod(url.path, 0o700)
                }
            }
        }
        _ = chflags(directory.path, 0); _ = chmod(directory.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }

    public static func export(_ plan: ZIPPlan, to destination: URL, cancellation: ZIPCancellation = ZIPCancellation(), progress: @Sendable (ZIPProgress) -> Void = { _ in }) throws {
        try export(plan, to: destination, cancellation: cancellation, progress: progress, hooks: TestHooks())
    }
    static func export(_ plan: ZIPPlan, to destination: URL, cancellation: ZIPCancellation = ZIPCancellation(), progress: @Sendable (ZIPProgress) -> Void = { _ in }, hooks: TestHooks) throws {
        try cancellation.check()
        let parentURL = try canonicalDirectory(destination.deletingLastPathComponent())
        let parent = try openDirectory(parentURL); defer { close(parent) }
        let parentIdentity = ZIPFingerprint(try attributes(parent))
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else { throw failure("Недопустимое имя ZIP") }
        var previous = stat()
        let hadDestination = fstatat(parent, destinationName, &previous, AT_SYMLINK_NOFOLLOW) == 0
        if !hadDestination, errno != ENOENT { throw systemFailure("Не удалось проверить ZIP назначения") }
        if hadDestination, previous.st_mode & S_IFMT == S_IFDIR { throw failure("Назначение является папкой") }
        let temporaryName = ".PhotoViewer-\(UUID().uuidString).zip"
        let output = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw systemFailure("Не удалось создать временный ZIP") }
        defer { close(output); _ = unlinkat(parent, temporaryName, 0) }
        let staging = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("PhotoViewer-ZIP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { cleanup(staging) }
        let contents = staging.appendingPathComponent(plan.source.archiveName)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        let directories = plan.items.filter { $0.kind == .directory }.sorted { $0.relative.count < $1.relative.count }
        for item in directories where !item.relative.isEmpty {
            try verify(item, root: plan.source.root)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(item.relative), withIntermediateDirectories: false)
        }
        progress(ZIPProgress(stage: .preparing, total: plan.fileCount))
        var completed = 0
        for item in plan.items where item.kind != .directory {
            try cancellation.check()
            // Also enforce exclusion for callers who built their plan before choosing a destination.
            if plan.source.root.appendingPathComponent(item.relative).path == parentURL.appendingPathComponent(destinationName).path { continue }
            try copy(item, root: plan.source.root, destination: contents.appendingPathComponent(item.relative), cancellation: cancellation, hooks: hooks)
            completed += 1; progress(ZIPProgress(stage: .preparing, completed: completed, total: plan.fileCount))
        }
        for item in directories.reversed() {
            try copy(item, root: plan.source.root, destination: item.relative.isEmpty ? contents : contents.appendingPathComponent(item.relative), cancellation: cancellation, hooks: hooks)
        }
        try cancellation.check()
        progress(ZIPProgress(stage: .archiving))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--rsrc", "--extattr", "--sequesterRsrc", "--keepParent", contents.path, "-"]
        var environment = ProcessInfo.processInfo.environment; environment.removeValue(forKey: "DITTONORSRC")
        process.environment = environment
        process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        let diagnostics = staging.appendingPathComponent(".ditto-errors-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let errors = try FileHandle(forWritingTo: diagnostics); defer { try? errors.close() }
        process.standardError = errors
        try cancellation.launch(process)
        hooks.processStarted(process, staging)
        process.waitUntilExit(); cancellation.reaped()
        try cancellation.check()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: diagnostics); defer { try? handle.close() }
            let detail = String(decoding: try handle.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
            throw failure("Не удалось создать ZIP: \(detail)")
        }
        guard fsync(output) == 0 else { throw systemFailure("Не удалось сохранить ZIP") }
        try cancellation.publish {
            let currentParent = try openDirectory(parentURL); defer { close(currentParent) }
            guard parentIdentity.matches(ZIPFingerprint(try attributes(currentParent)), directory: true) else { throw failure("Папка назначения изменилась") }
            var current = stat()
            let exists = fstatat(parent, destinationName, &current, AT_SYMLINK_NOFOLLOW) == 0
            guard exists == hadDestination, !exists || ZIPFingerprint(current) == ZIPFingerprint(previous) else { throw failure("Файл назначения изменился во время экспорта") }
            guard renameat(parent, temporaryName, parent, destinationName) == 0 else { throw systemFailure("Не удалось опубликовать ZIP") }
        }
    }
}
