# DrawEvolve Quick Start Guide

Get up and running with DrawEvolve in 5 minutes.

## Prerequisites Checklist

- [ ] Mac with macOS 14+ (Sonoma or later)
- [ ] Xcode 15+ installed
- [ ] OpenAI API key with GPT-4 Vision access
- [ ] Apple Developer account (for device testing)

## Setup Steps

### 1. Configure Your API Key (2 minutes)

```bash
# Navigate to the project
cd DrawEvolve

# Run the setup script
./setup.sh

# Or manually copy the config template
cp DrawEvolve/Config/Config.example.plist DrawEvolve/Config/Config.plist
```

**Edit `DrawEvolve/Config/Config.plist`:**
```xml
<key>OPENAI_API_KEY</key>
<string>sk-your-actual-openai-key-here</string>
```

### 2. Open in Xcode (1 minute)

```bash
open DrawEvolve.xcodeproj
```

Or double-click `DrawEvolve.xcodeproj` in Finder.

### 3. Configure Code Signing (1 minute)

1. Select the **DrawEvolve** project in the left sidebar
2. Select the **DrawEvolve** target
3. Go to **Signing & Capabilities** tab
4. Under **Team**, select your Apple Developer team
5. Xcode will automatically handle provisioning

### 4. Run the App (1 minute)

**In Simulator:**
- Select a simulator from the device menu (e.g., iPhone 15 Pro)
- Press `Cmd + R` or click the Play button

**On Device:**
- Connect your iPhone or iPad via USB
- Select it from the device menu
- Press `Cmd + R`
- On first run, go to Settings → General → VPN & Device Management → Trust your developer certificate

## Testing the App

1. **Launch**: You'll see the questionnaire
2. **Fill the form**:
   - Subject: "Portrait"
   - Style: "Realism"
   - (Other fields optional)
3. **Tap "Start Drawing"**
4. **Draw something** with Apple Pencil or your finger
5. **Tap the sparkles icon** (⭐) in the toolbar
6. **View AI feedback** in the overlay

## Troubleshooting

### "Failed to load API key"
- Check that `Config.plist` exists in `DrawEvolve/Config/`
- Verify your API key starts with `sk-`
- Rebuild the project (Cmd + Shift + K, then Cmd + R)

### "Build Failed"
- Make sure you've selected a valid team in Signing & Capabilities
- Clean build folder: Product → Clean Build Folder (Cmd + Shift + K)
- Restart Xcode

### "API Error"
- Verify your OpenAI API key is active
- Check your OpenAI account has GPT-4 Vision access
- Ensure you have API credits available

### Canvas not responding
- PencilKit requires iOS 17+ (use simulator or device running iOS 17+)
- Grant the app any requested permissions

## Remote Development (Mac Mini Setup)

If you're using a headless Mac Mini:

```bash
# SSH into your Mac Mini
ssh user@your-mac-mini-ip

# Navigate to project
cd /path/to/DrawEvolve

# Run setup
./setup.sh

# Build from command line
xcodebuild -project DrawEvolve.xcodeproj \
           -scheme DrawEvolve \
           -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
           build

# Or use AnyDesk/Screen Sharing to access Xcode GUI
```

## Next Steps

- Read the full [README.md](README.md) for detailed documentation
- Customize the accent color in `Assets.xcassets/AccentColor.colorset`
- Explore the code structure in the `Views/`, `Models/`, and `Services/` directories
- Test with different drawing styles and subjects

## Getting Help

- Review error messages in Xcode's console (bottom panel)
- Check OpenAI API status at https://status.openai.com
- Refer to [README.md](README.md) for architecture details

---

**Happy Drawing! 🎨**
