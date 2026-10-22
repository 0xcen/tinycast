import Foundation

/// Layout rules for a user-supplied Parakeet model, kept pure so the app and helper share them.
enum DictationCustomModel {
    static let directoryName = "custom-model"
    static let manifestFileName = "custom-model.json"
    static let vocabularyFileName = "parakeet_vocab.json"
    static let jointName = "JointDecisionv3"

    static let requiredFiles: Set<String> = [
        "Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", vocabularyFileName,
    ]

    static let attributionFiles = [
        "NOTICE", "NOTICE.md", "NOTICE.txt", "README", "README.md", "README.txt", "LICENSE",
        "LICENSE.md", "LICENSE.txt",
    ]

    enum ComputeUnits: Sendable {
        case cpuAndGPU
        case cpuAndNeuralEngine
    }

    enum Encoder: String, CaseIterable, Sendable {
        // Ordered deliberately: the smaller, GPU-oriented variant wins when both are present.
        case lut3 = "Encoder_lut3.mlmodelc"
        case standard = "Encoder.mlmodelc"

        /// The `DictationModel.ParakeetConfiguration.encoder` value for this file.
        var baseName: String { String(rawValue.dropLast(".mlmodelc".count)) }

        var computeUnits: ComputeUnits {
            self == .lut3 ? .cpuAndGPU : .cpuAndNeuralEngine
        }
    }

    struct Manifest: Codable, Equatable, Sendable {
        let originalFolderName: String
    }

    struct Installation: Equatable, Sendable {
        let encoder: Encoder
        let manifest: Manifest
    }

    struct Vocabulary: Equatable, Sendable {
        let pieces: [Int: String]
        let blankToken: Int
    }

    enum VocabularyError: Error, Equatable, Sendable {
        case invalidJSON
        case empty
        case nonContiguous
    }

    static func encoder(in fileNames: Set<String>) -> Encoder? {
        Encoder.allCases.first { fileNames.contains($0.rawValue) }
    }

    static func missingFiles(in fileNames: Set<String>) -> [String] {
        var missing = requiredFiles.subtracting(fileNames).sorted()
        if encoder(in: fileNames) == nil {
            missing.append("Encoder.mlmodelc/Encoder_lut3.mlmodelc")
        }
        return missing
    }

    static func vocabulary(from data: Data) throws -> Vocabulary {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw VocabularyError.invalidJSON
        }
        guard !raw.isEmpty else { throw VocabularyError.empty }
        var pieces = [Int: String]()
        for (key, piece) in raw {
            guard let id = Int(key), id >= 0 else { throw VocabularyError.nonContiguous }
            pieces[id] = piece
        }
        guard pieces.count == raw.count, Set(pieces.keys) == Set(0..<pieces.count) else {
            throw VocabularyError.nonContiguous
        }
        return Vocabulary(pieces: pieces, blankToken: pieces.count)
    }

    static func configuration(
        encoder: Encoder, vocabularyData: Data
    ) throws -> DictationModel.ParakeetConfiguration {
        let vocabulary = try vocabulary(from: vocabularyData)
        return DictationModel.ParakeetConfiguration(
            encoder: encoder.baseName, joint: jointName, blankToken: vocabulary.blankToken,
            encoderUsesGPU: encoder.computeUnits == .cpuAndGPU, stripsNonTextTokens: true)
    }

    static func isNonTextToken(id: Int, piece: String) -> Bool {
        if id == 0, piece == "<unk>" { return true }
        if piece.hasPrefix("<|") { return true }
        return ["<pad>", "<blank>", "<s>", "</s>"].contains(piece)
    }

    static func skipsToken(id: Int, piece: String, stripsNonTextTokens: Bool) -> Bool {
        if stripsNonTextTokens { return isNonTextToken(id: id, piece: piece) }
        return piece.hasPrefix("<|")
    }

    struct TensorExpectation: Equatable, Sendable {
        let name: String
        /// A `nil` dimension is flexible, such as the time axis.
        let shape: [Int?]

        func matches(shape: [Int]) -> Bool {
            guard self.shape.count == shape.count else { return false }
            return zip(self.shape, shape).allSatisfy { expected, actual in
                expected == nil || expected == actual
            }
        }
    }

    struct TensorDescription: Equatable, Sendable {
        let name: String
        let shape: [Int]
    }

    enum SignatureError: Error, Equatable, Sendable {
        case missingInput(String)
        case missingOutput(String)
        case inputShape(name: String, expected: [Int?], actual: [Int])
        case outputShape(name: String, expected: [Int?], actual: [Int])
    }

    struct ModelSignature: Equatable, Sendable {
        let inputs: [TensorExpectation]
        let outputs: [TensorExpectation]

        /// Declared tensors must be present with their shape; extra ones are allowed.
        func validate(
            inputs actualInputs: [TensorDescription], outputs actualOutputs: [TensorDescription]
        ) -> SignatureError? {
            mismatch(inputs, against: actualInputs, isInput: true)
                ?? mismatch(outputs, against: actualOutputs, isInput: false)
        }

        private func mismatch(
            _ expectations: [TensorExpectation], against actual: [TensorDescription], isInput: Bool
        ) -> SignatureError? {
            for expectation in expectations {
                guard let tensor = actual.first(where: { $0.name == expectation.name }) else {
                    return isInput ? .missingInput(expectation.name) : .missingOutput(expectation.name)
                }
                guard expectation.matches(shape: tensor.shape) else {
                    return isInput
                        ? .inputShape(
                            name: expectation.name, expected: expectation.shape, actual: tensor.shape)
                        : .outputShape(
                            name: expectation.name, expected: expectation.shape, actual: tensor.shape)
                }
            }
            return nil
        }
    }

    static let preprocessorSignature = ModelSignature(
        inputs: [
            TensorExpectation(name: "audio_signal", shape: [1, nil]),
            TensorExpectation(name: "audio_length", shape: [1]),
        ],
        outputs: [
            TensorExpectation(name: "mel", shape: [1, 128, nil]),
            TensorExpectation(name: "mel_length", shape: [1]),
        ])

    static let encoderSignature = ModelSignature(
        inputs: [
            TensorExpectation(name: "mel", shape: [1, 128, nil]),
            TensorExpectation(name: "mel_length", shape: [1]),
        ],
        outputs: [
            TensorExpectation(name: "encoder", shape: [1, 1024, nil]),
            TensorExpectation(name: "encoder_length", shape: [1]),
        ])

    static let decoderSignature = ModelSignature(
        inputs: [
            TensorExpectation(name: "targets", shape: [1, nil]),
            TensorExpectation(name: "target_length", shape: [1]),
            TensorExpectation(name: "h_in", shape: [2, 1, 640]),
            TensorExpectation(name: "c_in", shape: [2, 1, 640]),
        ],
        outputs: [
            TensorExpectation(name: "decoder", shape: [1, 640, 1]),
            TensorExpectation(name: "h_out", shape: [2, 1, 640]),
            TensorExpectation(name: "c_out", shape: [2, 1, 640]),
        ])

    static let jointSignature = ModelSignature(
        inputs: [
            TensorExpectation(name: "encoder_step", shape: [1, 1024, 1]),
            TensorExpectation(name: "decoder_step", shape: [1, 640, 1]),
        ],
        outputs: [
            TensorExpectation(name: "token_id", shape: [1, 1, 1]),
            TensorExpectation(name: "duration", shape: [1, 1, 1]),
        ])

    static func signature(for component: String) -> ModelSignature? {
        switch component {
        case "Preprocessor.mlmodelc": preprocessorSignature
        case Encoder.lut3.rawValue, Encoder.standard.rawValue: encoderSignature
        case "Decoder.mlmodelc": decoderSignature
        case jointName + ".mlmodelc": jointSignature
        default: nil
        }
    }

    enum ValidationErrorCode: String, Codable, Sendable {
        case missingFiles, loadFailed, signatureMismatch, invalidVocabulary
    }

    struct ValidationReport: Codable, Equatable, Sendable {
        let ok: Bool
        var code: ValidationErrorCode?
        var detail: String?
        var encoder: String?
        var encoderUsesGPU: Bool?
        var blankToken: Int?

        static func success(encoder: Encoder, blankToken: Int) -> ValidationReport {
            .init(
                ok: true, code: nil, detail: nil, encoder: encoder.baseName,
                encoderUsesGPU: encoder.computeUnits == .cpuAndGPU, blankToken: blankToken)
        }

        static func failure(
            _ code: ValidationErrorCode, detail: String? = nil
        ) -> ValidationReport {
            .init(
                ok: false, code: code, detail: detail, encoder: nil, encoderUsesGPU: nil,
                blankToken: nil)
        }
    }
}
