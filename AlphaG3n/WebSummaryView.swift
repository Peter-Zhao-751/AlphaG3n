//
//  WebSummaryView.swift
//  AlphaG3n
//
//  Full-screen cover shown when the user taps a QR code on the result screen.
//  The sibling of SentenceReadingView: a large, VoiceOver-focusable reading
//  surface with the shared Done bar. Visiting and summarizing the linked site
//  happens here, on appear — so a site is fetched only when the user opens its
//  QR — and a spinner shows for the duration.
//

import SwiftUI
import Combine

struct WebSummaryView: View {
    let url: URL
    let onDone: () -> Void

    @StateObject private var loader = WebSummaryLoader()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            TopActionBar(
                title: "Done",
                accessibilityHint: "Closes the website summary and returns to the document",
                action: onDone
            )
        }
        // `.task` starts on appear and is cancelled automatically when the cover
        // is dismissed, which trips the loader's cancellation guard.
        .task { await loader.load(url: url) }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
                Text("Summarizing website…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            // Tell VoiceOver something is in progress rather than leaving a
            // silent screen while the fetch + summary run.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Summarizing website, please wait.")

        case .loaded(let summary):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let host = url.host {
                        Text(host)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityLabel("Summary of \(host)")
                    }
                    Text(summary)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        // One focusable element holding the whole summary, like
                        // a sentence card in SentenceReadingView.
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(summary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 96)
                .padding(.bottom, 40)
            }

        case .failed(let message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }
}

/// Drives the one-shot fetch + summarize for a `WebSummaryView`. Runs on the
/// main actor so its `@Published` state is always read on main; the heavy work
/// is awaited on `WebSummarizer`'s own background hops.
@MainActor
private final class WebSummaryLoader: ObservableObject {
    enum State {
        case loading
        case loaded(String)
        case failed(String)
    }

    @Published var state: State = .loading

    /// `.task` can fire more than once across view-identity changes; only the
    /// first run does the work.
    private var started = false

    func load(url: URL) async {
        guard !started else { return }
        started = true

        do {
            let summary = try await WebSummarizer().summary(of: url)
            guard !Task.isCancelled else { return }
            state = .loaded(summary)
        } catch {
            // Dismissed mid-load → don't publish over a torn-down screen.
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription
                ?? "This website couldn't be summarized."
            state = .failed(message)
        }
    }
}
