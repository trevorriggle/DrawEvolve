# DrawEvolve

An AI-powered drawing critique app for iOS that helps artists improve their skills through personalized, context-aware feedback.

## Overview

DrawEvolve follows a simple three-step workflow:

1. **Context** — Users provide their learning context (subject, style, focus area)
2. **Draw** — Artists create drawings using PencilKit's natural drawing experience
3. **Critique** — AI analyzes the drawing and provides two-phase feedback:
   - **Visual Analysis**: Objective, measurement-driven observations
   - **Personalized Coaching**: Context-aware, actionable guidance

### CI-Only Philosophy

DrawEvolve is designed with a **CI-first approach**. While local development requires a Mac with Xcode, the primary build and deployment pipeline runs entirely through GitHub Actions. This ensures:

- Consistent builds across all deployments
- Automated TestFlight uploads via tag-based triggers
- Reproducible signing and provisioning
- No local environment configuration required for releases

## Tech Stack & Dependencies

| Technology | Purpose | Rationale |
|-----------|---------|-----------|
| **Swift** | Primary language | Native iOS performance and safety |
| **SwiftUI** | UI framework | Modern, declarative UI with less boilerplate |
| **PencilKit** | Drawing canvas | Apple's optimized drawing framework with Apple Pencil support |
| **UIKit bridging** | Canvas integration | Required to embed PencilKit (UIKit) in SwiftUI |
| **Combine** | Reactive patterns | Optional for async state management |
| **Foundation** | Core utilities | Standard library for networking, data handling |
| **URLSession** | Network client | Native HTTP client for API communication |
| **AppStorage/UserDefaults** | Local persistence | Lightweight storage for user context and preferences |
| **Photos/PHPhotoLibrary** | Image saving | Add-only permission for saving drawings to Photos |

## Project Structure

```
DrawEvolve/
├── DrawEvolve.xcodeproj              # Xcode project (see "Creating Xcode Project" below)
├── DrawEvolve/
│   ├── App/
│   │   ├── DrawEvolveApp.swift       # App entry point, SwiftUI lifecycle
│   │   ├── AppTheme.swift            # Centralized colors, typography, spacing
│   │   └── PrivacyInfo.xcprivacy     # Privacy manifest (no tracking)
│   ├── Features/
│   │   ├── Canvas/
│   │   │   ├── CanvasScreen.swift    # Main drawing interface
│   │   │   └── PKCanvasViewRepresentable.swift  # SwiftUI wrapper for PKCanvasView
│   │   ├── Critique/
│   │   │   ├── CritiquePanel.swift   # Displays AI feedback
│   │   │   ├── CritiqueClient.swift  # Network client for critique API
│   │   │   ├── CritiqueModels.swift  # Request/Response data models
│   │   │   └── PromptTemplates.swift # Two-phase AI prompts as constants
│   │   └── Onboarding/
│   │       ├── ContextCaptureView.swift  # Subject/style/focus form
│   │       └── ContextModel.swift    # @AppStorage-backed user context
│   ├── Services/
│   │   ├── AppConfig.swift           # Environment flags and constants
│   │   └── Logging.swift             # Lightweight OSLog wrapper
│   └── Utilities/
│       └── Extensions.swift          # Common Swift/SwiftUI extensions
├── .github/
│   └── workflows/
│       └── ios-testflight.yml        # CI pipeline for building and deploying
└── README.md                          # This file
```

### Folder Descriptions

- **App/**: Core app setup, theme, and privacy configuration
- **Features/Canvas/**: Drawing interface using PencilKit
- **Features/Critique/**: AI critique logic, networking, and UI
- **Features/Onboarding/**: User context collection for personalized feedback
- **Services/**: App-wide utilities (config, logging)
- **Utilities/**: Reusable extensions and helpers

## Build & Run

### Local Development (Requires Mac)

1. **Prerequisites**:
   - macOS with Xcode 15.2+ installed
   - Active Apple Developer account
   - iOS Simulator or physical device

2. **Create Xcode Project** (see section below)

3. **Open project**:
   ```bash
   open DrawEvolve/DrawEvolve.xcodeproj
   ```

4. **Select target**:
   - Choose "DrawEvolve" scheme
   - Select simulator or connected device

5. **Build and run**:
   - Press `Cmd + R` or click the Play button
   - App will launch in simulator/device

### CI-Only Build (Primary Method)

For production builds, use GitHub Actions:

1. Ensure all GitHub secrets are configured (see "App Store Connect & Signing")
2. Push a version tag to trigger the workflow:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. Monitor the workflow at: `https://github.com/your-org/DrawEvolve/actions`
4. Download the IPA artifact or check TestFlight (once upload is enabled)

## CI Pipeline

The `.github/workflows/ios-testflight.yml` workflow automates building and deploying to TestFlight.

### How to Trigger

- **Automatic**: Push a version tag matching the pattern `v*.*.*` (e.g., `v1.0.0`, `v1.2.3`)
  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

### What the Pipeline Does

1. **Checkout code**: Clones the repository
2. **Select Xcode**: Uses Xcode 15.2 on macOS 14 runner
3. **Cache derived data**: Speeds up builds by caching Xcode build artifacts
4. **Configure signing**: Decodes App Store Connect API key from GitHub secrets
5. **Build archive**: Creates release archive with automatic code signing
6. **Export IPA**: Exports signed IPA ready for distribution
7. **Upload to TestFlight**: (Commented out until secrets are configured)
8. **Upload artifacts**: Saves IPA to GitHub for 30 days

### Caching Strategy

- **Derived Data**: Cached based on `project.pbxproj` hash
- **Restore keys**: Falls back to latest cache if exact match not found
- Reduces build time by ~30-50% on subsequent runs

### Re-runs and Debugging

- **Re-run failed jobs**: Click "Re-run jobs" in GitHub Actions UI
- **View logs**: Expand each step to see detailed output
- **Download artifacts**: Access IPAs from the "Artifacts" section
- **Common fixes**:
  - Ensure secrets are set correctly
  - Verify Bundle ID matches App Store Connect
  - Check certificate/provisioning profile validity

## App Store Connect & Signing

### Prerequisites

1. **Apple Developer Account**: Active paid membership ($99/year)
2. **D-U-N-S Number**: Required for organization accounts (get from Dun & Bradstreet)

### Step-by-Step Setup

#### 1. Create App Record in App Store Connect

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Navigate to **My Apps** → **+** → **New App**
3. Fill in:
   - **Platform**: iOS
   - **Name**: DrawEvolve
   - **Primary Language**: English
   - **Bundle ID**: Create new (e.g., `com.yourcompany.drawevolve`)
   - **SKU**: Unique identifier (e.g., `DRAWEVOLVE001`)
   - **User Access**: Full Access

#### 2. Configure Bundle ID

1. Go to [Apple Developer Portal](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles** → **Identifiers**
3. Click **+** to create new identifier
4. Select **App IDs** → **Continue**
5. Fill in:
   - **Description**: DrawEvolve
   - **Bundle ID**: Explicit (e.g., `com.yourcompany.drawevolve`)
   - **Capabilities**: Enable required capabilities:
     - ✅ Push Notifications (if needed)
     - ✅ Sign in with Apple (if needed)

#### 3. Create App Store Connect API Key

1. In App Store Connect, go to **Users and Access** → **Keys** (under Integrations)
2. Click **+** to generate new key
3. Fill in:
   - **Name**: DrawEvolve CI
   - **Access**: Developer or Admin
4. Click **Generate**
5. **Download the .p8 file** (only available once!)
6. Note the **Key ID** and **Issuer ID** from the page

#### 4. Configure GitHub Secrets

1. Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret** for each:

   | Secret Name | Value | How to Get |
   |------------|-------|------------|
   | `APP_STORE_ISSUER_ID` | Your Issuer ID | From App Store Connect → Keys page (top right) |
   | `APP_STORE_KEY_ID` | Your Key ID | From the API key you created |
   | `APP_STORE_P8` | Base64-encoded .p8 file | Run: `cat AuthKey_XXXXX.p8 \| base64` |

   **To encode the .p8 file**:
   ```bash
   cat ~/Downloads/AuthKey_YOURKEY.p8 | base64 | pbcopy
   ```
   Then paste into the `APP_STORE_P8` secret.

#### 5. Enable TestFlight Upload

1. Open `.github/workflows/ios-testflight.yml`
2. Locate the commented section:
   ```yaml
   # - name: Upload to TestFlight
   #   env:
   #     APP_STORE_KEY_ID: ${{ secrets.APP_STORE_KEY_ID }}
   #     ...
   ```
3. **Uncomment** the entire step
4. Commit and push changes

#### 6. Create Export Options Plist

Create `DrawEvolve/ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

Replace `YOUR_TEAM_ID` with your Team ID from [Apple Developer Portal](https://developer.apple.com/account).

## Environment & Config

### Environment Variables

The app reads configuration from environment variables and process info:

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_USE_FAKE_CRITIQUE` | `false` | Use mock responses instead of real API |
| `APP_API_BASE_URL` | `https://api.drawevolve.com` | Backend API endpoint |

### Setting Environment Variables

**In Xcode (for local development)**:
1. Edit scheme: Product → Scheme → Edit Scheme
2. Select "Run" → "Arguments" tab
3. Add environment variables under "Environment Variables"

**Example**:
```
APP_USE_FAKE_CRITIQUE = true
APP_API_BASE_URL = http://localhost:3000
```

**In CI** (GitHub Actions):
- Set in workflow YAML under `env:` section
- Or use GitHub repository variables/secrets

### Configuration Access

All config is centralized in `Services/AppConfig.swift`:

```swift
// Usage example
if AppConfig.useFakeCritique {
    return mockCritique()
}

let url = "\(AppConfig.apiBaseURL)/critique"
```

## AI Prompting & Critique Specification

### Two-Phase Critique System

DrawEvolve uses a **two-phase AI critique approach** for optimal learning:

#### Phase 1: Visual Analysis (Objective)
- **Goal**: Provide measurement-driven, objective observations
- **Focus**: Proportions, line quality, composition, technical execution
- **Format**: Factual observations separated from recommendations
- **Specificity**: Use concrete measurements (e.g., "shoulder 15% wider")
- **Token Cap**: 150 tokens maximum

#### Phase 2: Personalized Coaching (Context-Aware)
- **Goal**: Deliver actionable, personalized guidance
- **Input**: User context (subject, style, focus area) + visual analysis
- **Format**: Encouraging, honest, direct feedback
- **Content**:
  - Recognition of what's working well
  - Specific next steps aligned with user's focus
  - Honest assessment without discouragement
- **Token Cap**: 150 tokens maximum

### Identity Injection

All prompts begin with:

> **"You are the DrawEvolve AI coach."**

This establishes:
- Consistent persona across all interactions
- Commitment to honest, encouraging feedback
- Focus on artist improvement over generic praise

### Prompt Structure

Prompts are defined in `Features/Critique/PromptTemplates.swift`:

```swift
// System identity
static let systemIdentity = """
You are the DrawEvolve AI coach. Your role is to help artists improve their drawing skills through
objective analysis and personalized, encouraging feedback.
"""

// Phase 1: Visual Analysis
static let visualAnalysisPrompt = """
Analyze this drawing objectively and provide measurement-driven observations.

Focus on:
- Proportions and anatomical accuracy (with specific measurements, e.g., "shoulder 15% wider")
- Line quality and consistency
- Composition and balance
- Technical execution

Keep observations brief and specific. Separate what you see from any recommendations.
Limit response to 150 tokens.
"""

// Phase 2: Personalized Coaching (context-injected)
static func personalizedCoachingPrompt(context: UserContext) -> String {
    """
    Based on the visual analysis and the user's learning context, provide personalized coaching.

    User Context:
    - Subject: \(context.subject)
    - Style: \(context.style)
    - Focus Area: \(context.focus)

    Provide:
    - Honest, encouraging feedback
    - Specific, actionable next steps
    - Recognition of what's working well
    - Direct suggestions aligned with their focus area

    Tone: Encouraging, honest, and direct.
    Keep response brief and actionable (under 150 tokens).
    """
}
```

### Always Collect Context First

Before any critique:
1. **Onboarding flow** captures: subject, style, focus area
2. **Stored in AppStorage** for persistent personalization
3. **Injected into Phase 2** prompt for context-aware coaching

### Key Principles

✅ **Demand specificity**: "Adjust shoulder 15% wider" not "improve proportions"
✅ **Cap tokens**: Keep responses brief and actionable
✅ **Separate observations from coaching**: Phase 1 (what) → Phase 2 (why + how)
✅ **Tone**: Encouraging, honest, direct—never generic praise
✅ **Context-aware**: Every critique references user's stated goals

## Photos Permission (Add-Only)

DrawEvolve uses **add-only photos permission** to save drawings to the user's Photos library.

### Required Info.plist Keys

Add to `Info.plist` (or configure in Xcode project settings):

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>DrawEvolve needs permission to save your drawings to your Photos library.</string>
```

**Note**: We use `NSPhotoLibraryAddUsageDescription` (add-only) rather than full library access. This limits the app to adding photos without reading existing library contents.

### Implementation

```swift
import Photos

func saveDrawingToPhotos(image: UIImage) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized else { return }

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, error in
            if success {
                Logger.log("Drawing saved to Photos")
            }
        }
    }
}
```

## Privacy & Data Handling

### No Vendor Keys in App

**Important**: DrawEvolve does **NOT** embed OpenAI or any third-party API keys in the iOS app.

- ❌ No API keys in source code
- ❌ No API keys in compiled binary
- ❌ No API keys in environment variables shipped with app
- ✅ All API calls routed through our backend proxy

### App → Backend → AI Provider

```
[iOS App] → [DrawEvolve Backend] → [OpenAI Vision API]
            (API keys stored here)
```

**Benefits**:
- Secure key management (backend only)
- Request monitoring and rate limiting
- Ability to switch AI providers without app update
- User privacy (no direct third-party data sharing)

### Data Collection

- **User drawings**: Sent to our backend, then to AI provider for analysis
- **User context**: Stored locally (AppStorage), sent with critique requests
- **No tracking**: `NSPrivacyTracking` set to `false` in PrivacyInfo.xcprivacy
- **No third-party analytics**: No Firebase, Mixpanel, etc.

### Privacy Manifest

DrawEvolve includes a **Privacy Manifest** (`App/PrivacyInfo.xcprivacy`) as required by Apple for App Store submission.

**What it declares**:
- ✅ **No tracking**: `NSPrivacyTracking` = `false`
- ✅ **No tracking domains**: Empty array (no third-party analytics)
- ✅ **No collected data types**: No user data collected that requires disclosure
- ✅ **UserDefaults access**: Declared for app functionality (reason code CA92.1)
  - Used for: Storing user context (subject, style, focus) and onboarding completion

**Why this matters**:
- Apple requires privacy manifests for apps using certain APIs (UserDefaults, file timestamps, etc.)
- This file documents that DrawEvolve does **not track users** and only uses UserDefaults for app functionality
- No third-party SDKs, no analytics, no data collection

**File location**: `DrawEvolve/DrawEvolve/App/PrivacyInfo.xcprivacy`

**Verification**: During "Mac Day," ensure this file is included in the Xcode target (see Step 3 of Mac Day Checklist)

---

## QUESTION: API Key Management Strategy

### How are OpenAI Vision and API keys imported in the iOS app process?

**Current Design**: DrawEvolve uses a **server-side proxy architecture**:

1. iOS app does **NOT** contain any OpenAI or third-party API keys
2. App sends drawing + context to our backend API
3. Backend stores API keys securely (environment variables, secret management)
4. Backend forwards request to OpenAI Vision API
5. Backend returns critique to iOS app

### Pros and Cons: Client-Side vs. Proxy

#### Client-Side API Calls (NOT recommended)

**Pros**:
- Simpler architecture (direct app → OpenAI)
- Lower latency (one less hop)
- No backend infrastructure needed

**Cons**:
- ❌ **Security risk**: API keys can be extracted from app binary
- ❌ **No rate limiting**: Users can abuse API directly
- ❌ **No monitoring**: Can't track usage or costs
- ❌ **No flexibility**: Changing providers requires app update
- ❌ **Privacy concerns**: User data sent directly to third party

#### Server-Side Proxy (RECOMMENDED ✅)

**Pros**:
- ✅ **Secure**: API keys never leave backend
- ✅ **Flexible**: Can switch AI providers without app update
- ✅ **Monitored**: Track usage, costs, and errors
- ✅ **Rate limited**: Prevent abuse
- ✅ **Privacy control**: Intermediate layer for data handling
- ✅ **Cost management**: Can implement caching, quotas

**Cons**:
- Requires backend infrastructure
- Slightly higher latency (one additional hop)
- Backend maintenance and scaling needed

### Claude's Recommendation for DrawEvolve

**Use the server-side proxy approach** for these reasons:

1. **Security**: API key extraction from iOS apps is trivial—never acceptable for production
2. **Cost Control**: AI API costs can spiral; backend monitoring is essential
3. **Flexibility**: You'll want to experiment with different AI models/providers
4. **Trust**: Users trust you more when you control the data flow
5. **Analytics**: Track what prompts work best, critique quality, user engagement

### Implementation Notes

- Backend can be simple (Node/Express, Python/FastAPI, Go/Gin)
- Store API keys in environment variables or secret manager (AWS Secrets Manager, GCP Secret Manager)
- Implement authentication (JWT, API keys) for app → backend communication
- Add rate limiting per user to prevent abuse
- Consider caching similar image analyses to reduce AI API costs

**Do NOT embed API keys in the iOS app under any circumstances.**

---

## Roadmap to TestFlight

### Step-by-Step Checklist

- [ ] **Obtain D-U-N-S Number** (if using organization account)
  - Apply at [Dun & Bradstreet](https://www.dnb.com/duns-number.html)
  - Wait 5-10 business days for approval

- [ ] **Enroll in Apple Developer Program**
  - Sign up at [developer.apple.com/programs](https://developer.apple.com/programs/)
  - Pay $99/year membership fee

- [ ] **Create App Store Connect Record**
  - Follow "App Store Connect & Signing" section above
  - Create Bundle ID, App ID, and API Key

- [ ] **Configure GitHub Secrets**
  - `APP_STORE_ISSUER_ID`
  - `APP_STORE_KEY_ID`
  - `APP_STORE_P8` (base64-encoded)

- [ ] **Create Xcode Project**
  - See "Creating the Xcode Project" section below

- [ ] **First Local Archive** (optional, for testing)
  - Open project in Xcode
  - Product → Archive
  - Distribute App → TestFlight (manual upload)

- [ ] **Enable CI Upload**
  - Uncomment TestFlight upload step in `ios-testflight.yml`
  - Commit and push

- [ ] **Tag First Release**
  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

- [ ] **Monitor CI Pipeline**
  - Check GitHub Actions for build status
  - Download IPA artifact if upload fails

- [ ] **TestFlight Configuration**
  - In App Store Connect, go to TestFlight tab
  - Add internal testers (up to 100)
  - Export Compliance: Select "No" if not using encryption beyond HTTPS

- [ ] **Distribute to Testers**
  - Once build processes (~10-30 minutes), add to testing group
  - Testers receive invite via TestFlight app

- [ ] **Iterate**
  - Collect feedback
  - Fix bugs
  - Tag new versions: `v1.0.1`, `v1.1.0`, etc.

---

## Mac Day Checklist

This is your **one-page guide** for the first time you sit down with a Mac to create the Xcode project and produce your first local archive. Follow this checklist in order.

### Prerequisites Checklist

- [ ] Mac with macOS Sonoma+ installed
- [ ] Xcode 15.2+ installed (download from Mac App Store)
- [ ] Active Apple Developer Account ($99/year)
- [ ] Apple ID signed into Xcode (Xcode → Settings → Accounts)

### Step 1: Create Xcode Project (15 minutes)

1. **Open Xcode** → File → New → Project
2. **Select**: iOS → App → Next
3. **Fill in project details**:
   - Product Name: `DrawEvolve`
   - Team: Select your Apple Developer team from dropdown
   - Organization Identifier: `com.yourcompany` (must match Bundle ID in App Store Connect)
   - Interface: SwiftUI
   - Language: Swift
   - Storage: None
4. **Save to**: This repo's `DrawEvolve/` folder
5. **Delete generated files**: Remove auto-created `DrawEvolveApp.swift` and `ContentView.swift` (we have our own)
6. **Add existing source files**:
   - Right-click project → Add Files to "DrawEvolve"
   - Select folders: `App/`, `Features/`, `Services/`, `Utilities/`
   - ✅ **Uncheck** "Copy items if needed" (files already in place)
   - ✅ **Check** "Create groups"
   - Click Add

### Step 2: Configure Target Settings (5 minutes)

1. **Select project** in navigator (blue icon at top)
2. **Select DrawEvolve target** → General tab
3. **Set Deployment Target**: iOS 16.0 or higher
4. **Set Bundle Identifier**: Must match App Store Connect exactly
   - Example: `com.yourcompany.drawevolve`
5. **Verify Team**: Should auto-fill from Step 1
6. **Check Signing & Capabilities tab**:
   - ✅ Automatically manage signing (should be checked)
   - ✅ Team should be selected

### Step 3: Add Required Info.plist Keys (2 minutes)

1. **Select DrawEvolve target** → Info tab
2. **Add custom property**:
   - Click **+** next to any existing key
   - Key: `NSPhotoLibraryAddUsageDescription`
   - Type: String
   - Value: `DrawEvolve needs permission to save your drawings to your Photos library.`
3. **Verify PrivacyInfo.xcprivacy** is included in target:
   - Find `App/PrivacyInfo.xcprivacy` in navigator
   - Check File Inspector (⌘⌥1) → Target Membership → DrawEvolve is checked

### Step 4: Configure Build Scheme for CI (3 minutes)

1. **Product** → Scheme → Manage Schemes
2. **Select DrawEvolve** scheme
3. **Check "Shared"** checkbox (critical for CI!)
4. **Click Close**
5. This creates `.xcodeproj/xcshareddata/xcschemes/DrawEvolve.xcscheme`

### Step 5: First Build Test (2 minutes)

1. **Select simulator**: iPhone 15 Pro (or any device)
2. **Press ⌘R** (or click Play button)
3. **Verify**: App launches and shows onboarding screen
4. **If build fails**: Check error messages, verify all source files are added to target

### Step 6: Update ExportOptions.plist (1 minute)

1. **Open** `DrawEvolve/ExportOptions.plist`
2. **Replace** `YOUR_TEAM_ID` with your actual Team ID
   - Find Team ID: [Apple Developer Portal](https://developer.apple.com/account) → Membership → Team ID
   - Example: `ABC123DEF4`
3. **Save** file

### Step 7: Create First Archive (5 minutes)

1. **Select**: Any iOS Device (arm64) from device dropdown
   - **Note**: Cannot archive for simulator
2. **Product** → Archive
3. **Wait** for build to complete (~2-5 minutes)
4. **Verify**: Organizer window opens showing archive

### Step 8: Distribute Archive (Optional - Test Export)

1. **In Organizer**, select your archive
2. **Click Distribute App**
3. **Select**: App Store Connect
4. **Select**: Upload (or Export for testing)
5. **Choose**: Automatically manage signing
6. **Click Upload** (or Export)
7. **Verify**: Export completes successfully

### Step 9: Commit Xcode Project to Git (2 minutes)

```bash
cd /workspaces/DrawEvolve
git add DrawEvolve/DrawEvolve.xcodeproj
git add DrawEvolve/ExportOptions.plist
git add DrawEvolve/fastlane
git commit -m "Add Xcode project and CI configuration"
git push
```

### Step 10: Test CI Pipeline (5 minutes)

1. **Create test tag**:
   ```bash
   git tag v0.1.0-test
   git push origin v0.1.0-test
   ```
2. **Go to GitHub** → Actions tab
3. **Monitor workflow**: Should start automatically
4. **Check logs**: Verify build succeeds
5. **Download artifact**: IPA should be available in workflow artifacts

### Troubleshooting Quick Fixes

**"No signing certificate found"**
- Xcode → Settings → Accounts → Download Manual Profiles
- Or: Select your team again in project settings

**"Scheme not found in CI"**
- Verify Step 4: Scheme must be marked as "Shared"
- Re-run: Product → Scheme → Manage Schemes → Check "Shared"

**"Bundle ID doesn't match"**
- Verify Bundle ID in Xcode exactly matches App Store Connect
- No typos, correct capitalization

**"Cannot find module 'PencilKit'"**
- PencilKit should auto-link for iOS 13.0+
- Verify Deployment Target is set to iOS 16.0+

**"Build succeeds locally but fails in CI"**
- Ensure scheme is shared (Step 4)
- Verify all source files are added to target
- Check Xcode version matches CI (currently 15.2)

---

## Creating the Xcode Project

**Current Status**: This repository contains Swift source files but no `.xcodeproj` yet.

### Option 1: Create Manually in Xcode

1. Open Xcode → **File** → **New** → **Project**
2. Select **iOS** → **App** → **Next**
3. Fill in:
   - **Product Name**: DrawEvolve
   - **Team**: Select your Apple Developer team
   - **Organization Identifier**: `com.yourcompany` (must match Bundle ID)
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Storage**: None (we use AppStorage)
4. Save to: `/workspaces/DrawEvolve/DrawEvolve/`
5. Xcode creates `DrawEvolve.xcodeproj`

6. **Add existing files**:
   - In Xcode, right-click project → **Add Files to "DrawEvolve"**
   - Select all folders: `App/`, `Features/`, `Services/`, `Utilities/`
   - Check **"Copy items if needed"** and **"Create groups"**

7. **Configure target**:
   - Select project in navigator → **DrawEvolve target** → **General** tab
   - Set **Deployment Target**: iOS 16.0+
   - Set **Bundle Identifier**: Must match App Store Connect (e.g., `com.yourcompany.drawevolve`)
   - Under **Frameworks, Libraries, and Embedded Content**: Add PencilKit (should auto-link)

8. **Add Info.plist keys**:
   - Select **Info** tab
   - Add:
     - `NSPhotoLibraryAddUsageDescription`: "DrawEvolve needs permission to save your drawings to your Photos library."

9. **Build and run**:
   - Press `Cmd + R`
   - App should launch in simulator

### Option 2: Create via Command Line (Advanced)

```bash
# Navigate to DrawEvolve directory
cd /workspaces/DrawEvolve/DrawEvolve

# Generate Xcode project using SwiftPM (if using Package.swift)
# Note: This requires setting up a Package.swift first
swift package generate-xcodeproj
```

**Note**: For a standard iOS app, manual creation in Xcode (Option 1) is recommended.

### Option 3: Use CI-Generated Project

If you prefer CI-only builds:
1. The workflow can build without a local project (using `xcodebuild` with source files)
2. However, this requires advanced `xcodebuild` configuration
3. **Recommended**: Create project locally once, commit it to repo

**After creation**, commit the `.xcodeproj`:
```bash
git add DrawEvolve/DrawEvolve.xcodeproj
git commit -m "Add Xcode project"
git push
```

## Troubleshooting

### Common Signing Issues

**Problem**: "No signing certificate found"
- **Solution**: Ensure you've logged into Xcode with your Apple Developer account
  - Xcode → Settings → Accounts → Add Account
  - Select your team in project settings

**Problem**: "Provisioning profile doesn't match Bundle ID"
- **Solution**:
  - Check Bundle ID in Xcode matches App Store Connect exactly
  - Refresh provisioning profiles: Xcode → Settings → Accounts → Download Manual Profiles

**Problem**: "Code signing entitlements are not valid"
- **Solution**:
  - Remove unused entitlements from target settings
  - Ensure capabilities in Bundle ID match those in Xcode project

### Common CI Issues

**Problem**: Workflow fails at "Configure signing" step
- **Solution**: Verify GitHub secrets are set correctly
  - Check `APP_STORE_P8` is base64-encoded (no extra whitespace)
  - Verify `APP_STORE_KEY_ID` and `APP_STORE_ISSUER_ID` match App Store Connect

**Problem**: Workflow fails at "Build archive" step
- **Solution**:
  - Check Xcode version in workflow matches your local version
  - Ensure project scheme is shared: Xcode → Product → Scheme → Manage Schemes → Check "Shared"
  - Commit `.xcodeproj/xcshareddata/xcschemes/DrawEvolve.xcscheme`

**Problem**: Build succeeds but TestFlight upload fails
- **Solution**:
  - Ensure app has been created in App Store Connect
  - Check Bundle ID matches exactly
  - Verify Export Compliance is set in App Store Connect
  - Wait a few minutes and retry (Apple servers can be slow)

**Problem**: "Derived Data cache miss"
- **Solution**: This is normal on first run or after `project.pbxproj` changes
  - Cache will be populated for next run
  - Check for ~30-50% faster builds on subsequent runs

### Local Development Issues

**Problem**: PencilKit not found
- **Solution**:
  - Ensure deployment target is iOS 13.0+ (PencilKit minimum)
  - Add PencilKit framework: Target → General → Frameworks, Libraries → **+** → PencilKit

**Problem**: "No such module 'Combine'"
- **Solution**: Combine is available iOS 13+, ensure deployment target is set correctly

**Problem**: App crashes on launch
- **Solution**:
  - Check console logs in Xcode for error details
  - Verify all `@AppStorage` keys are unique
  - Ensure all required frameworks are linked

---

## License

*Add your license here (MIT, Apache 2.0, proprietary, etc.)*

## Contact

*Add maintainer contact information or link to issues*

---

**Note**: This README is a living document. Update it as the project evolves, especially after creating the Xcode project and configuring App Store Connect.
