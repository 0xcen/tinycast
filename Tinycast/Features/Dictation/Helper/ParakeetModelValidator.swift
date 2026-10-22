import CoreML
import Foundation

enum ParakeetModelValidator {
    static func validate(directory: URL) -> DictationCustomModel.ValidationReport {
        let fileNames = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let missing = DictationCustomModel.missingFiles(in: fileNames)
        guard missing.isEmpty, let encoder = DictationCustomModel.encoder(in: fileNames) else {
            return .failure(.missingFiles, detail: missing.joined(separator: ", "))
        }
        let vocabulary: DictationCustomModel.Vocabulary
        do {
            let data = try Data(
                contentsOf: directory.appendingPathComponent(
                    DictationCustomModel.vocabularyFileName))
            vocabulary = try DictationCustomModel.vocabulary(from: data)
        } catch let error as DictationCustomModel.VocabularyError {
            return .failure(.invalidVocabulary, detail: "\(error)")
        } catch {
            return .failure(.invalidVocabulary, detail: error.localizedDescription)
        }
        for component in components(encoder: encoder) {
            let model: MLModel
            do {
                model = try DictationTensor.load(
                    component.modelName, at: directory, units: component.units)
            } catch {
                return .failure(
                    .loadFailed, detail: "\(component.fileName): \(error.localizedDescription)")
            }
            let description = model.modelDescription
            let mismatch = component.signature.validate(
                inputs: tensors(from: description.inputDescriptionsByName),
                outputs: tensors(from: description.outputDescriptionsByName))
            if let mismatch {
                return .failure(.signatureMismatch, detail: "\(component.fileName): \(mismatch)")
            }
        }
        return .success(encoder: encoder, blankToken: vocabulary.blankToken)
    }

    private struct Component {
        let fileName: String
        let modelName: String
        let units: MLComputeUnits
        let signature: DictationCustomModel.ModelSignature
    }

    private static func components(encoder: DictationCustomModel.Encoder) -> [Component] {
        [
            Component(
                fileName: "Preprocessor.mlmodelc", modelName: "Preprocessor", units: .cpuOnly,
                signature: DictationCustomModel.preprocessorSignature),
            Component(
                fileName: encoder.rawValue, modelName: encoder.baseName,
                units: units(for: encoder.computeUnits),
                signature: DictationCustomModel.encoderSignature),
            Component(
                fileName: "Decoder.mlmodelc", modelName: "Decoder", units: .cpuAndNeuralEngine,
                signature: DictationCustomModel.decoderSignature),
            Component(
                fileName: DictationCustomModel.jointName + ".mlmodelc",
                modelName: DictationCustomModel.jointName, units: .cpuAndNeuralEngine,
                signature: DictationCustomModel.jointSignature),
        ]
    }

    private static func units(for computeUnits: DictationCustomModel.ComputeUnits) -> MLComputeUnits {
        switch computeUnits {
        case .cpuAndGPU: .cpuAndGPU
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        }
    }

    private static func tensors(
        from descriptions: [String: MLFeatureDescription]
    ) -> [DictationCustomModel.TensorDescription] {
        descriptions.compactMap { name, description in
            guard let constraint = description.multiArrayConstraint else { return nil }
            return DictationCustomModel.TensorDescription(
                name: name, shape: constraint.shape.map(\.intValue))
        }
    }
}
