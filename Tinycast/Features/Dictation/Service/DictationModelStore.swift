import Foundation

@MainActor
@Observable
final class DictationModelStore {
    typealias Failure = DictationWire.Failure

    private(set) var downloading: DictationModel?
    private(set) var downloadProgress: (received: Int64, total: Int64)?
    private(set) var removing: DictationModel?
    private(set) var transcribing = false
    private(set) var importing = false
    private(set) var loadedTarget: DictationWire.Target?
    private(set) var installedModels: Set<DictationModel> = []
    private(set) var customModel: DictationCustomModel.Installation?
    @ObservationIgnored private var worker: DictationWorker?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionCleanup: Task<Void, Never>?
    @ObservationIgnored private var configurationCache: ConfigurationCache = .pending
    @ObservationIgnored private var idleRelease: DictationIdleRelease
    @ObservationIgnored private var downloadTask: Task<Void, Error>?
    @ObservationIgnored private var downloadID: UUID?
    private let root: URL
    private let importer: DictationCustomModelImporter
    private let makeWorker: () throws -> DictationWorker

    /// `pending` keeps a broken vocabulary from being re-read on every access.
    private enum ConfigurationCache {
        case pending
        case resolved(DictationModel.ParakeetConfiguration?)
    }

    init(
        idleRelease: DictationIdleRelease,
        root: URL = AppPaths.caches().appending(path: "Dictation"),
        importer: DictationCustomModelImporter = .helper,
        makeWorker: @escaping () throws -> DictationWorker = { try DictationWorker() }
    ) {
        self.idleRelease = idleRelease
        self.root = root
        self.importer = importer
        self.makeWorker = makeWorker
        interruptionCleanup = Task.detached(priority: .utility) {
            try? DictationCustomModelImporter.removeInterruptedImports(in: root)
        }
        refreshInstalledModels()
        refreshCustomModel()
    }

    var hasCustomModel: Bool { customConfiguration != nil }

    /// Parsed on first use: an import commonly leaves no need for it until a transcription starts.
    var customConfiguration: DictationModel.ParakeetConfiguration? {
        guard let customModel else { return nil }
        if case .resolved(let configuration) = configurationCache { return configuration }
        let configuration = try? DictationCustomModel.configuration(
            encoder: customModel.encoder,
            vocabularyData: Data(
                contentsOf: customDirectory.appending(
                    path: DictationCustomModel.vocabularyFileName)))
        configurationCache = .resolved(configuration)
        return configuration
    }

    func setIdleRelease(_ option: DictationIdleRelease) {
        idleRelease = option
        if worker != nil, !transcribing {
            scheduleRelease()
        } else {
            releaseTask?.cancel()
            releaseTask = nil
        }
    }

    func isInstalled(_ model: DictationModel) -> Bool {
        installedModels.contains(model)
    }

    func refreshInstalledModels() {
        installedModels = Set(
            DictationModel.allCases.filter { model in
                let directory = directory(for: model)
                return model.requiredFiles.allSatisfy {
                    FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
                }
            })
    }

    func installedSize(_ model: DictationModel) async -> Int64? {
        guard isInstalled(model) else { return nil }
        return await directorySize(directory(for: model))
    }

    func customModelSize() async -> Int64? {
        guard hasCustomModel else { return nil }
        return await directorySize(customDirectory)
    }

    func download(_ model: DictationModel) async throws {
        guard downloading == nil, removing != model else { throw Failure.busy }
        guard !isInstalled(model) else { return }
        downloading = model
        let id = UUID()
        downloadID = id
        let destination = directory(for: model)
        let task = Task.detached(priority: .utility) { [weak self] in
            try await DictationModelDownloader.download(model, destination: destination) {
                [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadID == id else { return }
                    self.downloadProgress = (max(self.downloadProgress?.received ?? 0, received), total)
                }
            }
        }
        downloadTask = task
        defer { downloading = nil; downloadTask = nil; downloadID = nil; downloadProgress = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        installedModels.insert(model)
    }

    func cancelDownload() {
        downloadID = nil
        downloadTask?.cancel()
    }

    func delete(_ model: DictationModel) async throws {
        guard !transcribing, removing == nil, downloading != model else { throw Failure.busy }
        removing = model
        defer { removing = nil }
        if loadedTarget == .builtIn(model) { await release() }
        let directory = directory(for: model)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }.value
        installedModels.remove(model)
    }

    func importCustomModel(from source: URL) async throws {
        guard !importing, !transcribing, downloading == nil, removing == nil else {
            throw Failure.busy
        }
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path) else {
            throw DictationCustomModelError.unreadable
        }
        importing = true
        defer { importing = false }
        await interruptionCleanup?.value
        interruptionCleanup = nil
        if case .custom? = loadedTarget { await release() }
        let importer = self.importer
        let root = self.root
        setCustomModel(
            try await Task.detached(priority: .utility) {
                try importer.importModel(from: source, into: root)
            }.value)
    }

    func removeCustomModel() async throws {
        guard !importing, !transcribing, downloading == nil, removing == nil else {
            throw Failure.busy
        }
        if case .custom? = loadedTarget { await release() }
        let root = self.root
        try await Task.detached(priority: .utility) {
            try DictationCustomModelImporter.remove(from: root)
        }.value
        setCustomModel(nil)
    }

    func transcribe(
        _ samples: [Float], target: DictationWire.Target, language: String? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        guard !transcribing, !importing else { throw Failure.busy }
        let directory: URL
        let isQwen: Bool
        switch target {
        case .builtIn(let model):
            guard removing != model else { throw Failure.busy }
            guard isInstalled(model) else { throw Failure.notInstalled }
            directory = self.directory(for: model)
            isQwen = model.isQwen
        case .custom:
            guard hasCustomModel else { throw Failure.notInstalled }
            directory = customDirectory
            isQwen = false
        }
        releaseTask?.cancel()
        releaseTask = nil
        transcribing = true
        defer { transcribing = false; scheduleRelease() }
        do {
            if loadedTarget != target { await release() }
            try Task.checkCancellation()
            let worker = try self.worker ?? makeWorker()
            self.worker = worker
            let request = DictationWire.Request(
                id: UUID(), target: target, directory: directory,
                sampleCount: samples.count, language: isQwen ? language : nil)
            let text = try await worker.transcribe(samples, request: request) { [weak self] in
                guard let self, self.worker === worker, self.transcribing else { return }
                self.loadedTarget = target
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await release()
            throw error
        }
    }

    func release() async {
        releaseTask?.cancel()
        releaseTask = nil
        let worker = self.worker
        self.worker = nil
        loadedTarget = nil
        await worker?.stop()
    }

    func stop() async {
        downloadTask?.cancel()
        try? await downloadTask?.value
        await release()
    }

    func prepareForTermination() { downloadTask?.cancel(); worker?.terminate() }

    private func refreshCustomModel() {
        setCustomModel(nil)
        let directory = customDirectory
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            DictationCustomModel.missingFiles(in: Set(names)).isEmpty,
            let encoder = DictationCustomModel.encoder(in: Set(names)),
            let manifestData = try? Data(
                contentsOf: directory.appending(path: DictationCustomModel.manifestFileName)),
            let manifest = try? JSONDecoder().decode(
                DictationCustomModel.Manifest.self, from: manifestData)
        else { return }
        setCustomModel(DictationCustomModel.Installation(encoder: encoder, manifest: manifest))
    }

    private func setCustomModel(_ installation: DictationCustomModel.Installation?) {
        customModel = installation
        configurationCache = .pending
    }

    private func directorySize(_ directory: URL) async -> Int64? {
        let task = Task.detached(priority: .utility) { () -> Int64? in
            guard
                let files = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            else { return nil }
            var size: Int64 = 0
            while let url = files.nextObject() as? URL {
                guard !Task.isCancelled else { return nil }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let bytes = values.fileSize
                else { continue }
                size += Int64(bytes)
            }
            return size
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        guard worker != nil, idleRelease != .never else { releaseTask = nil; return }
        let interval = Duration.seconds(idleRelease.rawValue * 60)
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: interval, tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self, !self.transcribing else { return }
            await self.release()
        }
    }

    private var customDirectory: URL {
        root.appendingPathComponent(DictationCustomModel.directoryName)
    }

    private func directory(for model: DictationModel) -> URL {
        root.appendingPathComponent(model.folderName)
    }
}
