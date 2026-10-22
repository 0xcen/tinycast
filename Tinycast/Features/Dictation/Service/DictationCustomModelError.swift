import Foundation

/// Import failures whose descriptions are the only text the settings surface shows.
enum DictationCustomModelError: LocalizedError, Equatable, Sendable {
    case unreadable
    case invalid(DictationCustomModel.ValidationReport)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "That folder couldn't be read.")
        case .invalid(let report):
            switch report.code {
            case .missingFiles?:
                String(localized: "That folder is missing \(report.detail ?? "").")
            case .loadFailed?:
                String(localized: "The model couldn't be loaded.")
            case .signatureMismatch?:
                String(localized: "The model's input or output shapes don't match Parakeet.")
            case .invalidVocabulary?:
                String(localized: "The vocabulary file isn't a valid Parakeet vocabulary.")
            case nil:
                String(localized: "That folder isn't a Parakeet model.")
            }
        }
    }
}
