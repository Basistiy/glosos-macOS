//
//  ContentView.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var speechController = SpeechController()
    @State private var textToRead = "Since the release of the first novel, Harry Potter and the Philosopher's Stone, on 26 June 1997, the books have found immense popularity and commercial success worldwide. They have attracted a wide adult audience as well as younger readers and are widely considered cornerstones of modern literature, though the books have received mixed reviews from critics and literary scholars. As of February 2023, the books have sold more than 600 million copies worldwide, making them the best-selling book series in history, available in dozens of languages. The last four books all set records as the fastest-selling books in history, with the final instalment selling roughly 2.7 million copies in the United Kingdom and 8.3 million copies in the United States within twenty-four hours of its release. Warner Bros. Pictures adapted the original seven books into an eight-part namesake film series. In 2016, the total value of the Harry Potter franchise was estimated at $25 billion, making it one of the highest-grossing media franchises of all time. Harry Potter and the Cursed Child is a play based on a story co-written by Rowling. A television series based on the books is in production at HBO. The success of the books and films has allowed the Harry Potter franchise to expand with numerous derivative works, a travelling exhibition that premiered in Chicago in 2009, a studio tour in London that opened in 2012, a digital platform on which J. K. Rowling updates the series with new information and insight, and a trilogy of spin-off films premiering in November 2016 with Fantastic Beasts and Where to Find Them, among many other developments. Themed attractions, collectively known as The Wizarding World of Harry Potter, have been built at several Universal Destinations & Experiences amusement parks around the world."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple TTS Demo")
                .font(.largeTitle.bold())

            Text("Paste English text")
                .foregroundStyle(.secondary)

            TextEditor(text: $textToRead)
                .font(.body)
                .frame(minHeight: 240)
                .padding(12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                speechController.play(textToRead)
            } label: {
                Label(
                    speechController.isSpeaking ? "Playing..." : "Play",
                    systemImage: speechController.isSpeaking ? "waveform" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(textToRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speechController.isSpeaking)

            Text(speechController.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Live transcription")
                    .font(.headline)

                ScrollView {
                    Text(speechController.liveTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160)
                .padding(12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 680)
        .task {
            await speechController.preparePermissions()
            await speechController.startContinuousListening()
        }
        .onDisappear {
            speechController.stopContinuousListening()
        }
    }
}

#Preview {
    ContentView()
}
