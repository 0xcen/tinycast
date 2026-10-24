import Foundation

@main
struct DictationCustomModelTest {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                print(message)
                exit(1)
            }
        }

        func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
            guard actual == expected else {
                print("\(message): expected \(expected), got \(actual)")
                exit(1)
            }
        }

        let complete = DictationCustomModel.requiredFiles.union([
            DictationCustomModel.Encoder.standard.rawValue
        ])
        checkEqual(DictationCustomModel.missingFiles(in: complete), [], "A complete layout is missing files")
        check(
            DictationCustomModel.missingFiles(in: complete.subtracting(["Preprocessor.mlmodelc"]))
                .contains("Preprocessor.mlmodelc"),
            "A missing required file was not reported")
        check(
            DictationCustomModel.missingFiles(in: DictationCustomModel.requiredFiles)
                .contains("Encoder.mlmodelc/Encoder_lut3.mlmodelc"),
            "A missing encoder was not reported")

        let root = FileManager.default.temporaryDirectory.appending(path: "dictation-custom-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in complete where name != "JointDecisionv3.mlmodelc" {
            try Data().write(to: root.appending(path: name))
        }
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        checkEqual(
            DictationCustomModel.missingFiles(in: onDisk), ["JointDecisionv3.mlmodelc"],
            "A temporary folder did not report its missing file")

        checkEqual(
            DictationCustomModel.encoder(in: ["Encoder_lut3.mlmodelc"]), .lut3,
            "The lut3 encoder was not detected")
        checkEqual(
            DictationCustomModel.encoder(in: ["Encoder.mlmodelc"]), .standard,
            "The standard encoder was not detected")
        checkEqual(
            DictationCustomModel.encoder(in: ["Encoder.mlmodelc", "Encoder_lut3.mlmodelc"]), .standard,
            "The standard encoder did not win when both were present")
        checkEqual(
            DictationCustomModel.encoder(in: []), nil, "An absent encoder was detected")
        checkEqual(
            DictationCustomModel.installableFiles(encoder: .standard),
            DictationCustomModel.requiredFiles.union(["Encoder.mlmodelc", "NOTICE"]),
            "The standard installable set is wrong")
        checkEqual(
            DictationCustomModel.installableFiles(encoder: .lut3),
            DictationCustomModel.requiredFiles.union(["Encoder_lut3.mlmodelc", "NOTICE"]),
            "The lut3 installable set is wrong")
        checkEqual(
            DictationCustomModel.Encoder.lut3.computeUnits, .cpuAndGPU,
            "The lut3 encoder did not prefer the GPU")
        checkEqual(
            DictationCustomModel.Encoder.standard.computeUnits, .cpuAndNeuralEngine,
            "The standard encoder did not prefer the Neural Engine")

        let goodVocabulary = try DictationCustomModel.vocabulary(
            from: Data(#"{"0":"<unk>","1":"hello","2":"world"}"#.utf8))
        checkEqual(goodVocabulary.blankToken, 3, "The blank token is not the vocabulary count")
        checkEqual(goodVocabulary.pieces[1], "hello", "A vocabulary piece was not decoded")

        let customConfiguration = try DictationCustomModel.configuration(
            encoder: .lut3,
            vocabularyData: Data(#"{"0":"<unk>","1":"hello","2":"world"}"#.utf8))
        checkEqual(
            customConfiguration.encoder, "Encoder_lut3", "The custom encoder base name is wrong")
        checkEqual(
            customConfiguration.joint, DictationCustomModel.jointName,
            "The custom joint model name is wrong")
        checkEqual(
            customConfiguration.blankToken, 3, "The custom blank token is not the count")
        checkEqual(
            customConfiguration.encoderUsesGPU, true, "The lut3 configuration does not use the GPU")
        check(
            customConfiguration.stripsNonTextTokens,
            "A custom configuration must strip non-text tokens")

        do {
            _ = try DictationCustomModel.vocabulary(from: Data(#"{"0":"a","2":"c"}"#.utf8))
            print("A vocabulary with a gap was accepted")
            exit(1)
        } catch let error as DictationCustomModel.VocabularyError {
            checkEqual(error, .nonContiguous, "A gap reported the wrong vocabulary error")
        }

        do {
            _ = try DictationCustomModel.vocabulary(from: Data(#"{"0":"a","key":"b"}"#.utf8))
            print("A vocabulary with a non-numeric key was accepted")
            exit(1)
        } catch let error as DictationCustomModel.VocabularyError {
            checkEqual(error, .nonContiguous, "A non-numeric key reported the wrong vocabulary error")
        }

        do {
            _ = try DictationCustomModel.vocabulary(from: Data("{}".utf8))
            print("An empty vocabulary was accepted")
            exit(1)
        } catch let error as DictationCustomModel.VocabularyError {
            checkEqual(error, .empty, "An empty vocabulary reported the wrong error")
        }

        check(DictationCustomModel.isNonTextToken(id: 0, piece: "<unk>"), "Token 0 <unk> survived")
        check(DictationCustomModel.isNonTextToken(id: 1, piece: "<|nospeech|>"), "A <|…|> token survived")
        check(DictationCustomModel.isNonTextToken(id: 2, piece: "<pad>"), "<pad> survived")
        check(DictationCustomModel.isNonTextToken(id: 3, piece: "<blank>"), "<blank> survived")
        check(DictationCustomModel.isNonTextToken(id: 4, piece: "<s>"), "<s> survived")
        check(DictationCustomModel.isNonTextToken(id: 5, piece: "</s>"), "</s> survived")
        check(!DictationCustomModel.isNonTextToken(id: 0, piece: "hello"), "A text token was stripped")
        check(
            !DictationCustomModel.isNonTextToken(id: 7, piece: "<unk>"),
            "A non-zero <unk> token was stripped")

        check(
            !DictationCustomModel.skipsToken(
                id: 0, piece: "<unk>", stripsNonTextTokens: false),
            "A shipped model skipped token 0 <unk>")
        check(
            !DictationCustomModel.skipsToken(
                id: 0, piece: "hello", stripsNonTextTokens: false),
            "A shipped model skipped a text token")
        check(
            DictationCustomModel.skipsToken(
                id: 1, piece: "<|nospeech|>", stripsNonTextTokens: false),
            "A shipped model kept a <|…|> token")
        check(
            DictationCustomModel.skipsToken(
                id: 0, piece: "<unk>", stripsNonTextTokens: true),
            "A custom model kept token 0 <unk>")
        check(
            !DictationCustomModel.skipsToken(
                id: 0, piece: "hello", stripsNonTextTokens: true),
            "A custom model stripped a text token")

        let manifest = DictationCustomModel.Manifest(originalFolderName: "bark-3.0-clean")
        let manifestData = try JSONEncoder().encode(manifest)
        checkEqual(
            try JSONDecoder().decode(DictationCustomModel.Manifest.self, from: manifestData), manifest,
            "The manifest did not round-trip")

        let encoderSignature = try unwrap(DictationCustomModel.signature(for: "Encoder_lut3.mlmodelc"))
        let encoderOutput = try unwrap(encoderSignature.outputs.first { $0.name == "encoder" })
        check(
            encoderOutput.matches(shape: [1, 1024, 512]),
            "A flexible encoder output no longer matched")
        check(
            !encoderOutput.matches(shape: [1, 768, 512]),
            "A wrong fixed encoder dimension matched")

        let preprocessor = try unwrap(DictationCustomModel.signature(for: "Preprocessor.mlmodelc"))
        checkEqual(
            preprocessor.validate(
                inputs: [
                    .init(name: "audio_signal", shape: [1, 240_000]),
                    .init(name: "audio_length", shape: [1]),
                ],
                outputs: [
                    .init(name: "mel", shape: [1, 128, 1501]),
                    .init(name: "mel_length", shape: [1]),
                ]), nil, "The valid Preprocessor signature was rejected")

        let encoderInputs = [
            DictationCustomModel.TensorDescription(name: "mel", shape: [1, 128, 1501]),
            DictationCustomModel.TensorDescription(name: "mel_length", shape: [1]),
        ]
        let encoderOutputs = [
            DictationCustomModel.TensorDescription(name: "encoder", shape: [1, 1024, 188]),
            DictationCustomModel.TensorDescription(name: "encoder_length", shape: [1]),
        ]
        checkEqual(
            encoderSignature.validate(inputs: encoderInputs, outputs: encoderOutputs), nil,
            "The valid encoder signature was rejected")
        checkEqual(
            encoderSignature.validate(
                inputs: [.init(name: "audio", shape: [1, 128, 1501]), encoderInputs[1]],
                outputs: encoderOutputs),
            .missingInput("mel"), "A wrong input name was accepted")
        checkEqual(
            encoderSignature.validate(
                inputs: encoderInputs,
                outputs: [.init(name: "encoder", shape: [1, 768, 188]), encoderOutputs[1]]),
            .outputShape(name: "encoder", expected: [1, 1024, nil], actual: [1, 768, 188]),
            "A wrong output shape was accepted")
        checkEqual(
            encoderSignature.validate(inputs: encoderInputs, outputs: [encoderOutputs[0]]),
            .missingOutput("encoder_length"), "A missing output was accepted")

        let decoder = try unwrap(DictationCustomModel.signature(for: "Decoder.mlmodelc"))
        checkEqual(
            decoder.validate(
                inputs: [
                    .init(name: "targets", shape: [1, 1]),
                    .init(name: "target_length", shape: [1]),
                    .init(name: "h_in", shape: [2, 1, 640]),
                    .init(name: "c_in", shape: [2, 1, 640]),
                ],
                outputs: [
                    .init(name: "decoder", shape: [1, 640, 1]),
                    .init(name: "h_out", shape: [2, 1, 640]),
                    .init(name: "c_out", shape: [2, 1, 640]),
                ]), nil, "The valid Decoder signature was rejected")

        let joint = try unwrap(DictationCustomModel.signature(for: "JointDecisionv3.mlmodelc"))
        let jointInputs = [
            DictationCustomModel.TensorDescription(name: "encoder_step", shape: [1, 1024, 1]),
            DictationCustomModel.TensorDescription(name: "decoder_step", shape: [1, 640, 1]),
        ]
        checkEqual(
            joint.validate(
                inputs: jointInputs,
                outputs: [
                    .init(name: "token_id", shape: [1, 1, 1]),
                    .init(name: "duration", shape: [1, 1, 1]),
                ]), nil, "A [1, 1, 1] Joint output was rejected")
        for short in [[1], [1, 1]] {
            checkEqual(
                joint.validate(
                    inputs: jointInputs,
                    outputs: [
                        .init(name: "token_id", shape: short),
                        .init(name: "duration", shape: [1, 1, 1]),
                    ]),
                .outputShape(name: "token_id", expected: [1, 1, 1], actual: short),
                "A \(short) Joint output was accepted")
        }
        checkEqual(
            joint.validate(
                inputs: jointInputs,
                outputs: [
                    .init(name: "token_id", shape: [1, 1, 1]),
                    .init(name: "duration", shape: [1, 1, 1]),
                    .init(name: "token_prob", shape: [1, 1, 1]),
                    .init(name: "top_k_ids", shape: [1, 1, 1, 64]),
                ]), nil, "The valid Joint signature with extra outputs was rejected")

        let success = DictationCustomModel.ValidationReport.success(encoder: .lut3, blankToken: 8192)
        checkEqual(success.encoder, "Encoder_lut3", "The success report did not name the encoder")
        checkEqual(success.encoderUsesGPU, true, "The success report did not mark the GPU encoder")
        checkEqual(success.blankToken, 8192, "The success report lost the blank token")
        check(
            !DictationCustomModel.ValidationReport.failure(.missingFiles, detail: "x").ok,
            "A failure report claimed success")
        let reportData = try JSONEncoder().encode(success)
        checkEqual(
            try JSONDecoder().decode(DictationCustomModel.ValidationReport.self, from: reportData),
            success, "The validation report did not round-trip")

        print("dictation-custom-model-test passed")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderValueNotFound) }
        return value
    }
}
