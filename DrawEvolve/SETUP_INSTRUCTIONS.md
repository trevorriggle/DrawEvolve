# DrawEvolve - Supabase Auth & Gallery Setup Instructions

## ✅ What's Been Completed

All the code for Supabase authentication and gallery functionality has been implemented! Here's what's ready:

### 1. Authentication System
- ✅ `SupabaseManager.swift` - Supabase client configuration
- ✅ `AuthManager.swift` - User authentication (sign up, sign in, sign out, guest mode)
- ✅ `SignInView.swift` - Email/password sign in screen
- ✅ `SignUpView.swift` - New user registration screen
- ✅ `LandingView.swift` - Updated to use real auth flows

### 2. Database & Storage
- ✅ `Drawing.swift` - Model for saved drawings
- ✅ `DrawingStorageManager.swift` - Manages saving/loading drawings from Supabase
- ✅ `supabase_schema.sql` - Database schema with Row Level Security

### 3. Gallery
- ✅ `GalleryView.swift` - Grid display of user's saved drawings
- ✅ Delete functionality
- ✅ Sign out option
- ✅ Navigation to create new drawings

### 4. Canvas Integration
- ✅ Export functionality added to `CanvasRenderer.swift`
- ✅ Save button added to `DrawingCanvasView.swift`
- ✅ Save dialog for naming drawings
- ✅ Automatic upload to Supabase after drawing

### 5. App Flow
- ✅ Updated `ContentView.swift` to show Gallery after auth
- ✅ Seamless navigation: Landing → Auth → Gallery → Prompt → Canvas → Save

## 🚀 Next Steps (On Your Mac Mini)

### Step 1: Add Supabase Swift Package

1. Open the project in Xcode
2. Go to **File → Add Package Dependencies**
3. Enter this URL: `https://github.com/supabase/supabase-swift`
4. Version: **Up to Next Major** (2.0.0 or latest)
5. Add these products:
   - **Supabase**
   - **Auth**
   - **PostgREST**
   - **Storage**

### Step 2: Set Up Supabase Database

1. Go to your Supabase project: https://ipachwcfclhhhrvogmll.supabase.co
2. Click **SQL Editor** in the left sidebar
3. Create a new query
4. Copy and paste the contents of `supabase_schema.sql`
5. Click **Run** to execute

This will create:
- `drawings` table with proper columns
- Row Level Security policies (users can only see their own drawings)
- Automatic `updated_at` timestamp triggers
- Indexes for performance

### Step 3: Build and Test

1. Build the project in Xcode (⌘B)
2. Run on your device/simulator
3. Test the flow:
   - Create account / Sign in
   - See the gallery (empty at first)
   - Click **+** to create a new drawing
   - Fill out the prompt questionnaire
   - Draw something on the canvas
   - Click **Save** button (green, bottom right)
   - Enter a title
   - Drawing should appear in the gallery!

## 📝 New Files Created

```
DrawEvolve/
├── Services/
│   ├── SupabaseManager.swift (NEW)
│   ├── AuthManager.swift (NEW)
│   ├── DrawingStorageManager.swift (NEW)
│   └── CanvasRenderer.swift (UPDATED - added exportImage)
├── Views/
│   ├── SignInView.swift (NEW)
│   ├── SignUpView.swift (NEW)
│   ├── GalleryView.swift (NEW)
│   ├── LandingView.swift (UPDATED)
│   ├── DrawingCanvasView.swift (UPDATED - added Save button)
│   └── ContentView.swift (UPDATED - added Gallery navigation)
├── Models/
│   └── Drawing.swift (NEW)
└── supabase_schema.sql (NEW)
```

## 🔐 Security Features

- **Row Level Security**: Users can only access their own drawings
- **Secure auth**: All authentication handled by Supabase
- **Guest mode**: Still works for users who don't want to sign up (no save functionality)

## 🎨 User Flow

### For New Users:
1. **Landing Screen** → Click "Create Account"
2. **Sign Up** → Enter email/password
3. **Gallery** → Empty state, click "+" to create first drawing
4. **Prompt** → Fill out drawing questionnaire
5. **Canvas** → Draw artwork
6. **Save** → Click Save button, enter title
7. **Gallery** → See saved drawing

### For Returning Users:
1. **Landing Screen** → Click "Log In"
2. **Sign In** → Enter credentials
3. **Gallery** → See all saved drawings
4. Create new or view existing

## 🐛 Troubleshooting

**If builds fail:**
- Make sure Supabase Swift package is properly added
- Clean build folder (⌘⇧K) and rebuild
- Check that all import statements work

**If auth doesn't work:**
- Verify Supabase URL and API key are correct in `SupabaseManager.swift`
- Check Supabase dashboard for any auth errors
- Make sure email confirmations are disabled (or handle confirmation flow)

**If drawings don't save:**
- Run the SQL schema in Supabase
- Check browser console in Supabase dashboard for errors
- Verify Row Level Security policies are active

## 🎯 What's Left to Build

This implementation provides:
- ✅ Full authentication
- ✅ Drawing gallery
- ✅ Save/load functionality
- ✅ User-owned data

Still on the roadmap (from FEATURE_STATUS.md):
- Google Sign-In (OAuth)
- Export to device photos
- Share drawings
- Layers export/import
- Cloud sync for drawing projects (not just final images)

## 📞 Support

Everything is code-complete and ready to test! Just add the Supabase package and run the SQL schema.

Let me know if you hit any issues! 🚀
