# DrawEvolve Deployment Checklist

Use this checklist when deploying DrawEvolve to your Mac Mini and preparing for TestFlight.

## Pre-Deployment (On Mac Mini)

### 1. Environment Setup
- [ ] Mac Mini running macOS 14+ (Sonoma or later)
- [ ] Xcode 15+ installed
- [ ] Logged into Apple Developer account in Xcode
- [ ] Valid provisioning profiles available
- [ ] OpenAI API key ready

### 2. Pull Latest Code
```bash
# SSH into Mac Mini
ssh user@mac-mini-ip

# Navigate to projects directory
cd ~/Projects  # or your preferred location

# Clone or pull latest
git clone https://github.com/yourusername/DrawEvolve.git
# OR
cd DrawEvolve && git pull origin main
```

### 3. Configure API Keys
```bash
cd DrawEvolve

# Run setup script
./setup.sh

# Or manually:
cp DrawEvolve/Config/Config.example.plist DrawEvolve/Config/Config.plist

# Edit Config.plist and add your OpenAI API key
open DrawEvolve/Config/Config.plist
# Replace "sk-YOUR-API-KEY-HERE" with actual key
```

### 4. Verify Project
```bash
# Run verification script
./verify-project.sh

# Expected: All checks should pass (✓)
```

## Build & Test (Xcode)

### 5. Open Project
```bash
open DrawEvolve.xcodeproj
```

### 6. Configure Code Signing
- [ ] Select DrawEvolve project in navigator
- [ ] Select DrawEvolve target
- [ ] Go to Signing & Capabilities tab
- [ ] Under "Team", select your Apple Developer team
- [ ] Verify "Automatically manage signing" is checked
- [ ] Check that provisioning profile is valid

### 7. Update Bundle Identifier (if needed)
- [ ] Current: `com.drawevolve.app`
- [ ] Change if you need a different identifier
- [ ] Location: Target → General → Bundle Identifier

### 8. Test in Simulator
- [ ] Select iPhone 15 Pro (or latest) simulator
- [ ] Press Cmd+R to build and run
- [ ] Verify app launches without errors
- [ ] Fill out questionnaire
- [ ] Draw something
- [ ] Request feedback and verify it works
- [ ] Check console for any errors/warnings

### 9. Test on Physical Device
- [ ] Connect iOS device via USB
- [ ] Trust computer on device if prompted
- [ ] Select device from Xcode device menu
- [ ] Press Cmd+R to build and run
- [ ] On first run: Settings → General → VPN & Device Management → Trust Developer
- [ ] Repeat all functionality tests
- [ ] Test with Apple Pencil if available

## Pre-TestFlight Preparation

### 10. Update Version & Build Numbers
- [ ] Project → Target → General
- [ ] Set Version (e.g., 1.0.0)
- [ ] Set Build number (e.g., 1)
- [ ] Increment these for each TestFlight upload

### 11. Update App Icon (Optional)
- [ ] Create 1024x1024 app icon
- [ ] Add to Assets.xcassets/AppIcon.appiconset
- [ ] Or keep placeholder for now

### 12. Privacy & Compliance
- [ ] Review Info.plist privacy settings
- [ ] Add usage descriptions if needed (currently none required)
- [ ] Note: App uses internet for OpenAI API

### 13. Build for Release
- [ ] Product → Scheme → Edit Scheme
- [ ] Run → Build Configuration → Release
- [ ] Product → Clean Build Folder (Cmd+Shift+K)
- [ ] Product → Build (Cmd+B)
- [ ] Verify build succeeds with no errors

## TestFlight Upload

### 14. Archive the App
- [ ] Product → Destination → Any iOS Device (arm64)
- [ ] Product → Archive
- [ ] Wait for archive to complete
- [ ] Organizer window should open automatically

### 15. Validate Archive
- [ ] In Organizer, select the archive
- [ ] Click "Validate App"
- [ ] Select distribution method: App Store Connect
- [ ] Choose automatic signing
- [ ] Wait for validation
- [ ] Fix any errors/warnings

### 16. Distribute to TestFlight
- [ ] Click "Distribute App"
- [ ] Select: App Store Connect
- [ ] Upload symbols: Yes (for crash reports)
- [ ] Automatically manage signing: Yes
- [ ] Click "Upload"
- [ ] Wait for upload to complete

### 17. App Store Connect
- [ ] Go to https://appstoreconnect.apple.com
- [ ] Navigate to your app
- [ ] Go to TestFlight tab
- [ ] Wait for build to process (10-30 minutes)
- [ ] Add "What to Test" notes for testers
- [ ] Invite internal testers
- [ ] Submit for beta review (external testing)

## Post-Upload Verification

### 18. Monitor Build Processing
- [ ] Check email for processing status
- [ ] Review for any compliance issues
- [ ] Respond to any Apple feedback

### 19. Test TestFlight Build
- [ ] Install TestFlight app on iOS device
- [ ] Accept invite
- [ ] Install DrawEvolve from TestFlight
- [ ] Test all functionality
- [ ] Verify OpenAI integration works
- [ ] Check for any crashes or issues

### 20. Gather Feedback
- [ ] Share TestFlight invite with beta testers
- [ ] Monitor crash reports in App Store Connect
- [ ] Review tester feedback
- [ ] Plan next iteration

## Troubleshooting

### Common Issues

**"No signing certificate found"**
- Go to Xcode → Settings → Accounts
- Select your Apple ID
- Click "Manage Certificates"
- Add Apple Development/Distribution certificate

**"Provisioning profile doesn't include signing certificate"**
- Delete and regenerate provisioning profile
- Or use automatic signing

**"API key not found"**
- Verify Config.plist exists in DrawEvolve/Config/
- Check that it's included in Copy Bundle Resources
- Rebuild project (Clean + Build)

**Archive fails**
- Check for code signing errors
- Ensure all targets have valid signing
- Try manual signing if automatic fails

**Upload fails**
- Check internet connection
- Verify Apple Developer account is active
- Try again (sometimes server issues)

**Build processing stuck**
- Wait at least 30 minutes
- Contact Apple Developer Support if > 2 hours

## Quick Command Reference

```bash
# Build from command line (simulator)
xcodebuild -project DrawEvolve.xcodeproj \
           -scheme DrawEvolve \
           -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
           clean build

# Archive from command line
xcodebuild -project DrawEvolve.xcodeproj \
           -scheme DrawEvolve \
           -archivePath ./build/DrawEvolve.xcarchive \
           archive

# Export IPA
xcodebuild -exportArchive \
           -archivePath ./build/DrawEvolve.xcarchive \
           -exportPath ./build \
           -exportOptionsPlist ExportOptions.plist
```

## Notes

- Keep API keys secure and never commit Config.plist
- Increment build numbers for each TestFlight upload
- Test on multiple iOS versions if possible
- Monitor OpenAI API usage and costs
- Keep backup of signing certificates

---

**Ready to deploy?** Start at step 1 and work through the checklist systematically.
