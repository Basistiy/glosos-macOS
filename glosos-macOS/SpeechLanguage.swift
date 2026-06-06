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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english:
            return "English"
        case .russian:
            return "Russian"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .english:
            return "en-US"
        case .russian:
            return "ru-RU"
        }
    }

    static var defaultValue: SpeechLanguage {
        .english
    }
}
