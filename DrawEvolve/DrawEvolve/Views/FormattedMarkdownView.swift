//
//  FormattedMarkdownView.swift
//  DrawEvolve
//
//  SwiftUI view that renders markdown-formatted text with proper styling.
//

import SwiftUI

struct FormattedMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(parseMarkdownBlocks(text), id: \.id) { block in
                blockView(for: block)
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        switch block.type {
        case .header1:
            markdownText(block.content)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 8)
        case .header2:
            markdownText(block.content)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.top, 6)
        case .header3:
            markdownText(block.content)
                .font(.headline)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .bulletList:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundColor(.accentColor)
                    .fontWeight(.bold)
                markdownText(block.content)
                    .font(.body)
            }
            .padding(.leading, 8)
        case .numberedList:
            HStack(alignment: .top, spacing: 8) {
                Text("\(block.number ?? 1).")
                    .foregroundColor(.accentColor)
                    .fontWeight(.semibold)
                markdownText(block.content)
                    .font(.body)
            }
            .padding(.leading, 8)
        case .paragraph:
            markdownText(block.content)
                .font(.body)
                .lineSpacing(4)
        }
    }

    private func markdownText(_ text: String) -> Text {
        // Parse inline markdown (bold, italic, code)
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var currentParagraph: [String] = []
        var listCounter = 1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line - end current paragraph
            if trimmed.isEmpty {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(
                        type: .paragraph,
                        content: currentParagraph.joined(separator: " ")
                    ))
                    currentParagraph = []
                }
                listCounter = 1
                continue
            }

            // Header 1 (# or ##)
            if trimmed.hasPrefix("## ") {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(MarkdownBlock(type: .header2, content: trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)))
                listCounter = 1
                continue
            } else if trimmed.hasPrefix("# ") {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(MarkdownBlock(type: .header1, content: trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                listCounter = 1
                continue
            }

            // Header 3 (###)
            if trimmed.hasPrefix("### ") {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(MarkdownBlock(type: .header3, content: trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)))
                listCounter = 1
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(MarkdownBlock(type: .bulletList, content: trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Numbered list
            if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
                if !currentParagraph.isEmpty {
                    blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(MarkdownBlock(
                    type: .numberedList,
                    content: String(match.2),
                    number: Int(match.1)
                ))
                continue
            }

            // Regular paragraph text
            currentParagraph.append(trimmed)
        }

        // Add final paragraph if exists
        if !currentParagraph.isEmpty {
            blocks.append(MarkdownBlock(type: .paragraph, content: currentParagraph.joined(separator: " ")))
        }

        return blocks
    }
}

struct MarkdownBlock: Identifiable {
    let id = UUID()
    let type: BlockType
    let content: String
    var number: Int? = nil

    enum BlockType {
        case header1, header2, header3
        case bulletList, numberedList
        case paragraph
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            FormattedMarkdownView(text: """
            # Great work on your portrait!

            Your proportions are well-balanced and the composition is strong.

            ## Strengths:
            - **Good facial structure** with proper proportions
            - *Nice shading depth* on the cheekbones
            - The eyes are well-positioned

            ## Areas to improve:
            1. Soften the shadow transitions on the nose
            2. Adjust the ear positioning slightly higher
            3. Add more detail to the hair texture

            Remember: `Practice makes perfect!`
            """)
            .padding()
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(12)

            FormattedMarkdownView(text: """
            **Bold text**, *italic text*, and `inline code`.

            Simple paragraph with line breaks.
            """)
            .padding()
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(12)
        }
        .padding()
    }
}
