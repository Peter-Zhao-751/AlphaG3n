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
    /// Holds the Back bar out of VoiceOver across each focus hand-off (the cover
    /// opening, then the summary or error swapping in) so VoiceOver never half-
    /// speaks "Back to scan" before the focus above settles. Re-armed on every
    /// loader-state change; see `deferBackChrome`.
    @State private var backChromeHidden = true
    /// Invalidates an in-flight reveal when the chrome is re-hidden, so an early
    /// reveal can't fire during a later hand-off.
    @State private var revealGeneration = 0

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
                .accessibilityHidden(backChromeHidden)
                content
            }
        }
        // `.task` starts on appear and is cancelled automatically when the
        // cover is dismissed, which trips the loader's cancellation guard.
        .task { await loader.load(url: url) }
        // Re-arm the Back-bar hold whenever the loader moves between states (the
        // initial loading, then loaded / failed) so each focus hand-off is
        // covered. Fires immediately with the current state on subscribe.
        .onReceive(loader.$state) { _ in deferBackChrome() }
    }

    /// Hides the Back bar from VoiceOver, then restores it once the focus
    /// hand-off has settled — it stays visible on screen throughout, so a sighted
    /// user (and, after the brief hold, VoiceOver swipes) can still use it. Each
    /// call supersedes any pending reveal via `revealGeneration`.
    private func deferBackChrome() {
        backChromeHidden = true
        revealGeneration += 1
        let generation = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if generation == revealGeneration { backChromeHidden = false }
        }
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
                // With the Back bar held out of VoiceOver during the loaded
                // hand-off (see `deferBackChrome`), the hero is the first element
                // VoiceOver reaches — the website name — then the user swipes
                // down into the sentences.
                SentenceListView(sentences: sentences, accent: LarpTheme.orange)
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
            Spacer()
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
