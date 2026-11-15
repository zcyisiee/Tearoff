//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image embed (`![[...]]`) styling and layout.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    /// Style standalone `![alt](url)` paragraphs by routing the URL through
    /// the embedder's `EmbeddedImageProvider` (URL goes into the request's
    /// `name` field — providers that don't speak URLs simply return `nil`,
    /// at which point we fall back to dimming the markdown source).
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scoped(ctx.imageLinkIndexed) {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            // The URL lives between markerRanges[2] ('(') and markerRanges[3] (')').
            guard token.markerRanges.count >= 4 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlStart = NSMaxRange(openParen)
            let urlLength = closeParen.location - urlStart
            guard urlLength > 0 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)
            let isActive = ctx.activeTokenIndices.contains(idx)

            let request = EmbeddedImageRequest(name: url)
            guard let image = ctx.services.images.image(for: request) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            let imageEmbedConfig = ctx.configuration.imageEmbed
            let maxWidth: CGFloat = {
                if let tc = ctx.layoutBridge?.firstTextContainer {
                    let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                    if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                }
                return imageEmbedConfig.fallbackMaxWidth
            }()

            let minWidth = imageEmbedConfig.minimumWidth
            let imageSize = image.size
            // Alt width suffix — `![alt|300](url)` — an explicit width wins over
            // the intrinsic size, clamped the same way embed widths are.
            let altText = ctx.nsText.substring(with: altRange(of: token))
            let targetWidth: CGFloat
            if let requested = requestedWidthInAlt(altText), requested > 0 {
                targetWidth = min(max(requested, minWidth), maxWidth)
            } else {
                targetWidth = min(max(imageSize.width, minWidth), maxWidth)
            }
            let scale = imageSize.width > 0 ? targetWidth / imageSize.width : 1
            let displayWidth = imageSize.width * scale
            let displayHeight = imageSize.height * scale
            let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

            let rawContent = ctx.nsText.substring(with: token.range)
            let rendered: Bool
            if isActive {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .collapsedSource(markerTexts: ["![", "]", "(", ")"]),
                    ctx: ctx,
                    attrs: &attrs
                )
                if rendered {
                    // The standalone helper hides the alt text + the four
                    // markers, but the URL between '(' and ')' is its own
                    // range and stays visible unless we collapse it too.
                    let urlText = ctx.nsText.substring(with: urlRange)
                    attrs.append((urlRange, [
                        .foregroundColor: NSColor.clear,
                        .font: ctx.latexMarkerFont,
                        .kern: -HeadingHelpers.textWidth(urlText, font: ctx.latexMarkerFont)
                    ]))
                }
            }
            if !rendered {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// Range of an image link's alt text — between the `![` and `]` markers.
    private static func altRange(of token: MarkdownToken) -> NSRange {
        guard token.markerRanges.count >= 2 else {
            return NSRange(location: NSMaxRange(token.range), length: 0)
        }
        let start = NSMaxRange(token.markerRanges[0])
        let end = token.markerRanges[1].location
        guard end > start else { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    /// `![alt|300](url)` — the alt may carry a trailing `|<number>` width
    /// suffix (Obsidian-style). Returns the width in points, or `nil` when the
    /// alt has no parsable suffix (including plain `|` separators that aren't
    /// followed by a positive number).
    static func requestedWidthInAlt(_ alt: String) -> CGFloat? {
        guard let pipeRange = alt.range(of: "|", options: .backwards) else { return nil }
        let raw = alt[pipeRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let width = Double(raw), width > 0, width.isFinite else { return nil }
        return width
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scoped(ctx.imageEmbedIndexed) {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)  // = display name (no suffix)
            // The uuid|width suffix lives in the `.wikiLinkID` side-channel (same as node links).
            let suffix = ctx.wikiLinkIDProvider(token.range)
            // Re-apply the attribute every restyle so makeStorageState can recover the suffix on
            // save — even on the image-not-found path (mirrors styleWikiLink). Load-bearing.
            if let suffix, !suffix.isEmpty {
                attrs.append((token.contentRange, [.wikiLinkID: suffix]))
            }
            let referenceContent = (suffix?.isEmpty == false) ? "\(rawContent)|\(suffix!)" : rawContent
            guard let reference = ImageEmbedReference(content: referenceContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Determine max width from text container
                let maxWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let minWidth = imageEmbedConfig.minimumWidth
                let imageSize = image.size
                let targetWidth: CGFloat
                if let rw = reference.requestedWidth, rw > 0 {
                    targetWidth = min(max(rw, minWidth), maxWidth)
                } else {
                    targetWidth = min(imageSize.width, maxWidth)
                }
                let scale = targetWidth / imageSize.width
                let displayWidth = imageSize.width * scale
                let displayHeight = imageSize.height * scale
                let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }
}
