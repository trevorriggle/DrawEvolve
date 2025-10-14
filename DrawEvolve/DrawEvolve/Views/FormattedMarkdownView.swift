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
        VStack(alignment: .leading, spacing: 8) {
            // SwiftUI's Text supports markdown natively in iOS 15+
            // Using .full to support headers, lists, bold, italic, code blocks, etc.
            if let attributedText = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                Text(attributedText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Fallback if markdown parsing fails
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
