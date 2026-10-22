import Foundation

protocol DictationRecognizer {
    func transcribe(_ samples: [Float], language: String?) throws -> String
}

extension QwenRecognizer: DictationRecognizer {}
extension ParakeetRecognizer: DictationRecognizer {
    func transcribe(_ samples: [Float], language: String?) throws -> String {
        try transcribe(samples)
    }
}

@main
enum DictationHelper {
    static func main() {
        if let directory = validationDirectory(from: CommandLine.arguments) {
            runValidation(directory: directory)
        }
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        guard fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { exit(1) }
        var recognizer: (any DictationRecognizer)?
        var loaded: DictationWire.Target?
        do {
            while let request = try DictationWire.read(DictationWire.Request.self, from: input) {
                try DictationTensor.checkParent()
                guard (1...DictationWire.maximumSamples).contains(request.sampleCount),
                    request.directory.isFileURL
                else {
                    throw DictationInferenceError.invalidAudio
                }
                if loaded != request.target {
                    recognizer = nil
                    loaded = nil
                    do {
                        recognizer = try autoreleasepool { () throws -> any DictationRecognizer in
                            switch request.target {
                            case .custom(let configuration):
                                try ParakeetRecognizer(
                                    directory: request.directory, configuration: configuration)
                            case .builtIn(let model) where model.isQwen:
                                try QwenRecognizer(directory: request.directory)
                            case .builtIn(let model):
                                try ParakeetRecognizer(directory: request.directory, model: model)
                            }
                        }
                        loaded = request.target
                    } catch {
                        try DictationWire.write(
                            DictationWire.Response(id: request.id, status: .failed), to: output)
                        continue
                    }
                }
                guard let recognizer else { throw DictationInferenceError.incompatibleModel }
                try DictationWire.write(DictationWire.Response(id: request.id, status: .ready), to: output)
                try autoreleasepool {
                    let data = try DictationWire.readExactly(
                        request.sampleCount * MemoryLayout<Float>.size, from: input)
                    let samples = [Float](unsafeUninitializedCapacity: request.sampleCount) { buffer, count in
                        data.withUnsafeBytes { bytes in
                            UnsafeMutableRawBufferPointer(buffer).copyMemory(from: bytes)
                        }
                        count = request.sampleCount
                    }
                    guard samples.allSatisfy({ $0.isFinite }) else {
                        throw DictationInferenceError.invalidAudio
                    }
                    do {
                        let text = try recognizer.transcribe(samples, language: request.language)
                        try DictationWire.write(
                            DictationWire.Response(id: request.id, status: .result, text: text), to: output)
                    } catch {
                        try DictationWire.write(
                            DictationWire.Response(id: request.id, status: .failed), to: output)
                    }
                }
            }
        } catch {
            exit(1)
        }
    }

    /// A missing argument validates an empty path, which reports every required file as missing.
    private static func validationDirectory(from arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--validate") else { return nil }
        let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        return URL(fileURLWithPath: path)
    }

    private static func runValidation(directory: URL) -> Never {
        let report = ParakeetModelValidator.validate(directory: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
        }
        exit(report.ok ? 0 : 1)
    }
}
