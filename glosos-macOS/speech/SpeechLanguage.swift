//
//  SpeechLanguage.swift
//  glosos-macOS
//
//  Created by Codex on 6/6/26.
//

import Foundation

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case english
    case russian
    case spanish
    case polish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english:
            return "English"
        case .russian:
            return "Russian"
        case .spanish:
            return "Spanish"
        case .polish:
            return "Polish"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .english:
            return "en-US"
        case .russian:
            return "ru-RU"
        case .spanish:
            return "es-ES"
        case .polish:
            return "pl-PL"
        }
    }

    static var defaultValue: SpeechLanguage {
        .english
    }
}
