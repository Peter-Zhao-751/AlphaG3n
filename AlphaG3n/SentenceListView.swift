//
//  SentenceListView.swift
//  AlphaG3n
//
//  The sentence-by-sentence reading surface, shared by the chunk-detail screen
//  (a tapped text block) and the website-summary screen (the fetched summary,
//  split into sentences). Each sentence is its own large, VoiceOver-focusable
//  card so a blind user can swipe through them one at a time. The cards are
//  display-only — tapping does nothing — and carry only real data (the
//  sentence and its position), not the mockup's invented role / language /
//  confidence fields.
//

import SwiftUI

struct SentenceListView: View {
    let sentences: [String]
    /// Reading accent (the tapped block's color, or orange for the website
    /// summary). Currently unstyled — the cards are drawn neutral — but kept so
    /// both call sites stay unchanged and reintroducing an accent is a one-liner.
    var accent: Color = LarpTheme.orange
    /// Optional block-type label (e.g. "Title" / "Text"). For a multi-sentence
    /// block it rides as the LAST item, after every sentence, so a blind user
    /// reads the whole block then learns what kind of block it was. For a
    /// single-sentence block the per-sentence list is dropped and only this type
    /// card shows — the tapped box already spoke that one line, so the list would
    /// just repeat it. The website summary passes nil (no type, always listed).
    var typeFooter: String? = nil

    var body: some View {
        // A single-sentence block adds nothing in the per-sentence list, so we
        // collapse to just its type card. The website summary (no typeFooter)
        // always lists its sentence(s), even when there's only one.
        let listsSentences = typeFooter == nil || sentences.count > 1
        VStack(spacing: 0) {
            if listsSentences { listHead }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if listsSentences {
                        ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                            card(index: index, sentence: sentence)
                        }
                    }
                    if let typeFooter {
                        typeFooterCard(typeFooter)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, listsSentences ? 4 : 12)
                .padding(.bottom, 40)
            }
        }
    }

    private var listHead: some View {
        HStack {
            Text("SENTENCES")
            Spacer()
            Text("\(sentences.count)")
        }
        .font(LarpTheme.mono(10))
        .tracking(2)
        .foregroundStyle(LarpTheme.ink2)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    private func card(index: Int, sentence: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(LarpTheme.mono(11, weight: .semibold))
                .foregroundStyle(LarpTheme.ink0)
                .frame(width: 28, height: 24)
                .background(LarpTheme.bg3, in: RoundedRectangle(cornerRadius: 4))
            Text(sentence)
                .font(.body)
                .foregroundStyle(LarpTheme.ink0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(LarpTheme.bg1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(LarpTheme.line, lineWidth: 1)
        )
        // One VoiceOver element per sentence so a blind user still swipes
        // through them one at a time. Not a button: a tap used only to mark the
        // card "active" and tint it, and we've dropped that — so the cards are
        // now display-only.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
        .accessibilityHint("Sentence \(index + 1) of \(sentences.count)")
    }

    /// Trailing card naming the block's layout type — the last thing VoiceOver
    /// reaches after the sentences, answering "is this a title, or text?".
    private func typeFooterCard(_ type: String) -> some View {
        VStack(spacing: 6) {
            Text("BLOCK TYPE")
                .font(LarpTheme.mono(10))
                .tracking(2)
                .foregroundStyle(LarpTheme.ink2)
            Text(type)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LarpTheme.ink0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(LarpTheme.bg1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(LarpTheme.line, lineWidth: 1)
        )
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Block type: \(type)")
    }
}

// MARK: - Reader hero

/// The accent-tinted panel atop a reading screen: a mono tagline, a large
/// title, and a mono subtitle. Shared by the chunk detail (block name) and the
/// website summary (host). Read as one element by VoiceOver.
struct ReaderHero: View {
    var tagline: String
    var title: String
    var subtitle: String
    var accent: Color = LarpTheme.orange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(accent).frame(width: 6, height: 6)
                Text(tagline.uppercased())
                    .font(LarpTheme.mono(10))
                    .tracking(2.2)
            }
            .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LarpTheme.ink0)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            if !subtitle.isEmpty {
                Text(subtitle.uppercased())
                    .font(LarpTheme.mono(10))
                    .tracking(1.8)
                    .foregroundStyle(LarpTheme.ink2)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tagline). \(title). \(subtitle)")
    }
}
