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

    /// When true, the content cards take VoiceOver sort priority *above* a
    /// sibling Back bar (`LarpBackBar` = 1), so a fullScreenCover opens focus on
    /// the first sentence / lone type card instead of defaulting to the top-most,
    /// higher-priority "Back to scan" bar. The website summary leaves this false
    /// so its `ReaderHero` (the site name) keeps the initial focus.
    var leadsFocus: Bool = false

    /// Optional VoiceOver focus anchor for the screen's *first* card (first
    /// sentence, or the lone type card). The caller sets its bound value true a
    /// beat after the cover appears to MOVE focus here — necessary because a
    /// fullScreenCover doesn't hand VoiceOver focus to its content on its own,
    /// and a `.screenChanged` re-post is a no-op once the cover is presented.
    /// nil (the website summary) leaves focus on its own hero.
    var entryFocus: AccessibilityFocusState<Bool>.Binding? = nil

    /// Whether the per-sentence cards are listed. A single-sentence typed block
    /// collapses to just its type card; the website summary (no typeFooter)
    /// always lists its sentence(s), even when there's only one.
    private var listsSentences: Bool { typeFooter == nil || sentences.count > 1 }

    /// VoiceOver order for the content cards. With `leadsFocus` set, returns a
    /// descending priority that sits above `LarpBackBar`'s 1 (last content card
    /// = 2), so the first card opens focus and the Back bar falls to the end of
    /// the swipe order — mirroring how `AnalysisView` ranks its detection boxes
    /// above the Recapture bar. Returns 0 (the default) when `leadsFocus` is off,
    /// leaving the website summary's hero-first order untouched. `position` is the
    /// card's index in the rendered list (sentences first, then the type footer).
    private func sortPriority(at position: Int) -> Double {
        guard leadsFocus else { return 0 }
        let total = (listsSentences ? sentences.count : 0) + (typeFooter != nil ? 1 : 0)
        return Double(total - position + 1)
    }

    var body: some View {
        // VoiceOver entry focus takes two things together: `leadsFocus` sort
        // priority sets the ORDER (cards above the caller's Back bar), and
        // `entryFocus` actually MOVES focus onto the first card a beat after the
        // cover appears. Sort priority alone doesn't move focus into a
        // fullScreenCover, so the move is what makes the first sentence / lone
        // type card the spoken element instead of "Back to scan".
        VStack(spacing: 0) {
            if listsSentences { listHead }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if listsSentences {
                        ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                            card(index: index, sentence: sentence)
                                .accessibilitySortPriority(sortPriority(at: index))
                                .accessibilityEntryFocus(index == 0 ? entryFocus : nil)
                        }
                    }
                    if let typeFooter {
                        typeFooterCard(typeFooter)
                            .accessibilitySortPriority(sortPriority(at: listsSentences ? sentences.count : 0))
                            .accessibilityEntryFocus(listsSentences ? nil : entryFocus)
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
        // Speak just the type ("Text", "Title", …) — not "Block type: Text".
        .accessibilityLabel(type)
    }
}

private extension View {
    /// Applies an `@AccessibilityFocusState` anchor only when one is supplied,
    /// so callers that don't drive entry focus (the website summary) stay
    /// untouched. Setting the bound value true moves VoiceOver focus here.
    @ViewBuilder
    func accessibilityEntryFocus(_ binding: AccessibilityFocusState<Bool>.Binding?) -> some View {
        if let binding {
            accessibilityFocused(binding)
        } else {
            self
        }
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
