//
//  WebSummaryView.swift
//  AlphaG3n
//
//  Full-screen cover shown when the user taps a website QR code on the
//  analysis screen. The sibling of the chunk-detail reader: the same dark
//  surface, Back-to-scan bar, and accent hero — and once the summary arrives
//  it's split into sentences and shown through the shared `SentenceListView`,
//  so a blind user swipes through it one sentence at a time exactly like a
//  scanned text block. The linked site is visited and summarized here, on
//  appear, so a site is only fetched when the user opens its QR.
//

import SwiftUI
import Combine

struct WebSummaryView: View {
    let url: URL
    let onDone: () -> Void

    @StateObject private var loader = WebSummaryLoader()
    /// Drives VoiceOver onto the progress status the moment the cover opens, so
    /// a blind user hears "Summarizing…" instead of the Back bar (see `loadingView`).
    @AccessibilityFocusState private var loadingFocused: Bool
    /// Drives VoiceOver onto the website-name hero once the summary arrives, so a
    /// blind user hears which site this is before swiping into its sentences —
    /// again instead of the Back bar (see the `.loaded` case).
    @AccessibilityFocusState private var summaryFocused: Bool

    private var host: String { url.host ?? "the linked website" }

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()

            VStack(spacing: 0) {
                LarpBackBar(
                    title: "Back to scan",
                    accessibilityHint: "Closes the website summary and returns to the document",
                    action: onDone
                )
                content
            }
        }
        // `.task` starts on appear and is cancelled automatically when the
        // cover is dismissed, which trips the loader's cancellation guard.
        .task { await loader.load(url: url) }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            loadingView

        case .loaded(let summary):
            let split = SentenceSplitter.sentences(in: summary)
            let sentences = split.isEmpty ? [summary] : split
            VStack(spacing: 0) {
                ReaderHero(tagline: "Website", title: host, subtitle: "summary")
                    .accessibilityFocused($summaryFocused)
                // The list leaves its own appear-focus off (the default) so it
                // doesn't fight the hero above for VoiceOver; the user swipes
                // down into the sentences from there.
                SentenceListView(sentences: sentences, accent: LarpTheme.orange)
            }
            .onAppear {
                // Mirror the loading focus: once the summary swaps in, pull
                // VoiceOver onto the website-name hero rather than the Back bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    summaryFocused = true
                }
            }

        case .failed(let message):
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(LarpTheme.orange)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LarpTheme.ink0)
                    .padding(.horizontal, 32)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            Spacer()
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(LarpTheme.orange)
                    .scaleEffect(1.4)
                Text("SUMMARIZING WEBSITE")
                    .font(LarpTheme.mono(11))
                    .tracking(2.5)
                    .foregroundStyle(LarpTheme.orange)
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(LarpTheme.ink2)
            }
            // Tell VoiceOver something is in progress rather than leaving a
            // silent screen while the fetch + summary run.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Summarizing \(host), please wait.")
            .accessibilityFocused($loadingFocused)
            Spacer()
        }
        .onAppear {
            // Mirror the post-capture "Analyzing…" screen: once the cover has
            // settled (a fullScreenCover otherwise drops VoiceOver on the Back
            // bar above), pull focus onto the progress status so it speaks the
            // wait message immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                loadingFocused = true
            }
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
