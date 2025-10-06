# DrawEvolve

An AI-assisted drawing coach that provides personalized feedback on your artwork using OpenAI's GPT-4 Vision API.

## Overview

DrawEvolve combines the power of Apple's PencilKit with OpenAI's vision capabilities to create an intelligent drawing mentor. Users fill out a brief questionnaire about their drawing goals, create their artwork on a digital canvas, and receive detailed, encouraging feedback tailored to their specific needs.

## Features

- **Pre-Drawing Questionnaire**: Capture context about what the user is drawing, their style, inspirations, and focus areas
- **PencilKit Canvas**: Professional-grade drawing experience with full Apple Pencil support
- **AI-Powered Feedback**: GPT-4 Vision analyzes drawings and provides specific, actionable feedback
- **Split-Screen Feedback View**: Review AI suggestions alongside your drawing
- **Minimal, Apple-Like Design**: Clean interface inspired by Apple Notes and Procreate

## Tech Stack

- **SwiftUI**: Modern declarative UI framework
- **PencilKit**: Apple's framework for drawing and sketching
- **OpenAI GPT-4 Vision API**: Image analysis and feedback generation
- **iOS 17+**: Target deployment
- **Xcode 15+**: Development environment

## Project Structure

```
DrawEvolve/
├── DrawEvolve.xcodeproj/
├── DrawEvolve/
│   ├── DrawEvolveApp.swift          # App entry point
│   ├── Info.plist                   # App configuration
│   ├── Views/
│   │   ├── ContentView.swift        # Main navigation & state
│   │   ├── PromptInputView.swift    # Pre-drawing questionnaire
│   │   ├── DrawingCanvasView.swift  # PencilKit canvas with feedback button
│   │   └── FeedbackOverlay.swift    # AI feedback display
│   ├── Models/
│   │   └── DrawingContext.swift     # User's drawing context data
│   ├── Services/
│   │   └── OpenAIManager.swift      # OpenAI API integration
│   ├── Config/
│   │   ├── Config.plist             # API keys (gitignored)
│   │   └── Config.example.plist     # Template for API keys
│   ├── Assets.xcassets/
│   │   ├── AppIcon.appiconset/
│   │   └── AccentColor.colorset/
│   └── Preview Content/
└── README.md
```

## Development Setup

### Remote Development Workflow

This project is developed using a unique remote workflow:

1. **GitHub Codespaces / VS Code**: Code is written and version-controlled here
2. **Headless Mac Mini**: Accessed remotely via SSH/AnyDesk for Xcode operations
3. **Xcode on Mac Mini**: Used for building, running simulators, and TestFlight uploads

### Prerequisites

- macOS 14+ (Sonoma or later)
- Xcode 15+
- iOS 17 SDK
- Active Apple Developer account (for device testing and TestFlight)
- OpenAI API key with GPT-4 Vision access

### Setup Instructions

#### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/DrawEvolve.git
cd DrawEvolve/DrawEvolve
```

#### 2. Configure API Keys

```bash
# Copy the example config file
cp DrawEvolve/Config/Config.example.plist DrawEvolve/Config/Config.plist

# Edit the file and add your OpenAI API key
# Replace "sk-YOUR-API-KEY-HERE" with your actual key
```

**Important**: `Config.plist` is gitignored and will never be committed. Keep your API key secure.

#### 3. Open in Xcode

```bash
open DrawEvolve.xcodeproj
```

Or if you're using the remote Mac Mini setup:
```bash
# SSH into your Mac Mini
ssh user@mac-mini-ip

# Navigate to the project
cd /path/to/DrawEvolve/DrawEvolve

# Open in Xcode
open DrawEvolve.xcodeproj
```

#### 4. Set Up Code Signing

1. In Xcode, select the DrawEvolve target
2. Go to "Signing & Capabilities"
3. Select your Apple Developer team
4. Xcode will automatically manage provisioning profiles

#### 5. Run the App

**In Simulator:**
```bash
# Command line (optional)
xcodebuild -project DrawEvolve.xcodeproj -scheme DrawEvolve -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Or simply press Cmd+R in Xcode
```

**On Device:**
1. Connect your iOS device
2. Select it from the device menu in Xcode
3. Press Cmd+R to build and run

### Building for TestFlight

```bash
# Archive the app
xcodebuild -project DrawEvolve.xcodeproj \
  -scheme DrawEvolve \
  -configuration Release \
  -archivePath ./build/DrawEvolve.xcarchive \
  archive

# Export for App Store distribution
xcodebuild -exportArchive \
  -archivePath ./build/DrawEvolve.xcarchive \
  -exportPath ./build \
  -exportOptionsPlist ExportOptions.plist

# Upload to TestFlight using Transporter app or:
xcrun altool --upload-app \
  --type ios \
  --file ./build/DrawEvolve.ipa \
  --username "your@email.com" \
  --password "@keychain:AC_PASSWORD"
```

## API Configuration

### OpenAI API Key Setup

The app uses OpenAI's GPT-4 Vision API for image analysis. You'll need:

1. An OpenAI account with API access
2. GPT-4 Vision enabled (standard with most API plans)
3. Your API key added to `Config.plist`

**Config.plist format:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>OPENAI_API_KEY</key>
    <string>sk-your-actual-key-here</string>
</dict>
</plist>
```

### API Cost Considerations

GPT-4 Vision API calls include both image and text processing:
- Image analysis: ~$0.01-0.03 per image
- Text response: ~$0.001-0.005 per response

Budget accordingly for development and production use.

## Usage

1. **Launch the app**: You'll see the pre-drawing questionnaire
2. **Fill out the form**: Provide context about your drawing
3. **Tap "Start Drawing"**: Navigate to the PencilKit canvas
4. **Create your artwork**: Use Apple Pencil or finger to draw
5. **Request Feedback**: Tap the sparkles icon when ready
6. **Review AI feedback**: Read personalized suggestions in the overlay
7. **Continue drawing**: Dismiss the overlay to keep working

## Design Philosophy

- **Minimal & Elegant**: Inspired by Apple Notes and Procreate
- **Neutral Colors**: Professional, distraction-free interface
- **Large Touch Targets**: Rounded CTA buttons for easy interaction
- **Placeholder Branding**: All assets are temporary and will be replaced

## Roadmap (v2+)

- [ ] SwiftDraw integration for advanced brush controls
- [ ] Layer support
- [ ] Drawing history and session management
- [ ] Export drawings as PNG/SVG
- [ ] Social sharing features
- [ ] Custom branding and icon assets
- [ ] Multiple AI models (Claude, Gemini, etc.)
- [ ] Offline drawing with batched feedback

## Contributing

This is a private project currently in active development. If you'd like to contribute, please reach out to discuss coordination.

## License

Copyright © 2025 DrawEvolve. All rights reserved.

## Support

For issues, questions, or feature requests, please open an issue in the GitHub repository.

---

**Note**: All branding, colors, and assets in this initial version are placeholders and will be replaced with custom DrawEvolve-branded materials in future updates.
