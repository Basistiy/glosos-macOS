//
//  SpeechLanguageTests.swift
//  glosos-macOSTests
//
//  Created by Codex on 6/6/26.
//

import Testing
@testable import glosos_macOS

struct SpeechLanguageTests {

    @Test
    func englishIsDefaultAndUsesUnitedStatesLocale() {
        #expect(SpeechLanguage.defaultValue == .english)
        #expect(SpeechLanguage.english.localeIdentifier == "en-US")
    }

    @Test
    func russianUsesRussianLocale() {
        #expect(SpeechLanguage.russian.localeIdentifier == "ru-RU")
    }
}
