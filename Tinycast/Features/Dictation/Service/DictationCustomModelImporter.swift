import Foundation
import Synchronization

struct DictationCustomModelImporter: Sendable {
    typealias Validation = @Sendable (_ directory: URL) throws -> DictationCustomModel.ValidationReport

    let validate: Validation

    /// Production: the helper's `--validate` mode keeps Core ML out of the app process.
    static let helper = DictationCustomModelImporter { try helperReport(for: $0) }

    func importModel(
        from source: URL, into root: URL
    ) throws -> DictationCustomModel.Installation {
        let manager = FileManager.default
        let names = Set((try? manager.contentsOfDirectory(atPath: source.path)) ?? [])
        let missing = DictationCustomModel.missingFiles(in: names)
        guard missing.isEmpty, let encoder = DictationCustomModel.encoder(in: names) else {
            throw DictationCustomModelError.invalid(
                .failure(.missingFiles, detail: missing.joined(separator: ", ")))
        }
        let staging = root.appending(path: ".import-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            let kept = DictationCustomModel.installableFiles(encoder: encoder)
            try copyContents(of: source, into: staging, keeping: kept, using: manager)
            let report = try validate(staging)
            guard report.ok else { throw DictationCustomModelError.invalid(report) }
            let manifest = DictationCustomModel.Manifest(originalFolderName: source.lastPathComponent)
            try JSONEncoder().encode(manifest).write(
                to: staging.appending(path: DictationCustomModel.manifestFileName))
            try publish(staging, to: root, using: manager)
            return DictationCustomModel.Installation(encoder: encoder, manifest: manifest)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func remove(from root: URL) throws {
        let directory = root.appending(path: DictationCustomModel.directoryName)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Staging folders an interrupted import left behind, named by its own UUID suffixes.
    static func removeInterruptedImports(in root: URL) throws {
        let manager = FileManager.default
        for entry in try manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            let name = entry.lastPathComponent
            let prefix = name.hasPrefix(".import-old-") ? ".import-old-" : ".import-"
            guard name.hasPrefix(prefix),
                UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try manager.removeItem(at: entry)
        }
    }

    private func copyContents(
        of source: URL, into destination: URL, keeping kept: Set<String>, using manager: FileManager
    ) throws {
        for name in try manager.contentsOfDirectory(atPath: source.path) where kept.contains(name) {
            try manager.copyItem(
                at: source.appending(path: name), to: destination.appending(path: name))
        }
    }

    /// Moves the validated staging folder into place, keeping the previous model until it lands.
    private func publish(_ staging: URL, to root: URL, using manager: FileManager) throws {
        let destination = root.appending(path: DictationCustomModel.directoryName)
        let backup = root.appending(path: ".import-old-\(UUID().uuidString)")
        let hadPrevious = manager.fileExists(atPath: destination.path)
        if hadPrevious { try manager.moveItem(at: destination, to: backup) }
        do {
            try manager.moveItem(at: staging, to: destination)
        } catch {
            if hadPrevious { try? manager.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? manager.removeItem(at: backup) }
    }

    static func helperReport(
        for directory: URL,
        executable: URL = DictationWorker.executable,
        arguments: [String]? = nil,
        timeout: DispatchTimeInterval = .seconds(120)
    ) throws -> DictationCustomModel.ValidationReport {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments ?? ["--validate", directory.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exit = try process.runObservingExit()
        // Deadline first: a child that never writes closes its pipe only on exit.
        let expired = Mutex(false)
        let deadline = DispatchWorkItem {
            expired.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exit.wait()
        deadline.cancel()
        guard !expired.withLock({ $0 }) else {
            throw DictationCustomModelError.invalid(.failure(.loadFailed))
        }
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw DictationCustomModelError.unreadable
        }
        return try JSONDecoder().decode(DictationCustomModel.ValidationReport.self, from: data)
    }
}
