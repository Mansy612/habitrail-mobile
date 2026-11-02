# iOS App Store release checklist — Habitrail

Status after the in-repo prep pass (2026-10-30). Items marked **[done]** are in
the repo; **[you / Mac]** need a Mac, an Apple Developer account, or App Store
Connect; **[verify]** need testing on a real device.

## Identity & config
- **[done]** Bundle ID changed off the `com.example.*` placeholder to
  `com.habitrail.app` (`ios/Runner.xcodeproj/project.pbxproj`). **Confirm this
  is the ID you want BEFORE creating the App Store Connect record — it's
  permanent once published.** Change it there (and in App Store Connect) if you
  use a different reverse-domain.
- **[done]** App display name `Habitrail`, pubspec description set, version
  `1.0.0+1` (correct for a first release; bump the `+build` on each upload).
- **[you / Mac]** In Xcode → Runner target → Signing & Capabilities: pick your
  **Team**, set signing to Automatic, create the App ID + provisioning.
- **[you / Mac]** Add **In-App Purchase** capability (for `in_app_purchase`),
  and **Push Notifications** only if you later add remote push (local
  notifications need no capability).

## Privacy (Apple now enforces these)
- **[done]** Privacy manifest `ios/Runner/PrivacyInfo.xcprivacy` created
  (tracking = false; declares the UserDefaults required-reason API for
  shared_preferences).
- **[you / Mac]** **Add `PrivacyInfo.xcprivacy` to the Runner target in Xcode**
  (drag into the Runner group, tick "Copy items / add to target" so it lands in
  Build Phases → Copy Bundle Resources). A file in the folder that isn't in the
  target does nothing.
- **[you / Mac]** Run `flutter build ipa` once; if Xcode/Apple flags other
  required-reason APIs from plugins (file timestamp, disk space, system boot
  time), add them to the manifest with their reason codes.
- **[you]** Fill the **App Store Connect privacy questionnaire** ("nutrition
  label"): you collect **email + display name** (account), and sync a **stats
  snapshot + optional full cloud backup** to Supabase. Mark data as *linked to
  the user*, *not used for tracking*.
- **[you]** Host a **Privacy Policy** and a **Support URL** (both required in
  App Store Connect).

## Accounts & review guidelines
- **[done, deploy needed]** **Account deletion (Guideline 5.1.1(v))** now fully
  deletes the auth user via the `delete-account` Edge Function
  (`supabase/functions/delete-account`), invoked by the Delete-account flow; data
  rows cascade. **Deploy it:** `npx supabase functions deploy delete-account
  --project-ref <ref>` (no secrets needed), then verify deletion on a device.
- **[ok]** Sign in with Apple is **not required** (email + guest only; it
  becomes mandatory only if you add Google/Facebook-style social logins).
- **[done; deploy + EULA needed]** **User-generated content (Guideline 1.2):**
  in-app Report + Block are on every chat message (long-press); reports go to
  `content_reports`. Deploy `20261029070000_content_reports.sql`, add a
  Terms/EULA (zero tolerance + act within 24h), and publish a report contact.
- **[you]** Age rating questionnaire; export-compliance (uses HTTPS only →
  usually "exempt", declare it).

## In-app purchases
- **[you]** Create the Premium products in **App Store Connect** (monthly
  `$7.99` / annual `$59.99`) with matching product IDs, and attach them to the
  app.
- **[verify]** Test **purchase + restore** on a Sandbox Apple ID on a device.
- **[later]** Server-side **receipt validation** (on the roadmap) — recommended,
  not required for approval.

## Backend readiness
- **[you]** The AI backend (Ollama via the Supabase `ai-proxy` Edge Function)
  must run **24/7 on a hosted box**; otherwise AI features fall back to the
  heuristic. Decide if the fallback is acceptable for launch.
- **[you]** Deploy the pending **`20261029060000_party_quests.sql`** migration
  (party co-op quests are inert until then).
- **[verify]** Social features (parties, guilds, chat, co-op quests, leaderboard)
  with **2 real accounts** — none is device-verified yet.

## Build, QA & submit (all on a Mac)
- **[you / Mac]** `flutter build ipa --release
  --dart-define-from-file=supabase.config.json` (so Supabase keys are baked in).
  Confirm `CAP_SERVER_URL`/web-wrapper leftovers aren't in this Flutter target.
- **[verify]** Device QA: onboarding, add/complete habits, notifications
  permission + firing, photo-picker profile pic, IAP paywall, journal (1–10
  ratings, long-press edit/delete), celebrations, safe-area/notch layout, dark
  appearance.
- **[you]** App Store Connect: screenshots (6.7" + 6.5" + iPad if you ship
  iPad), description, keywords, promo text, category, app icon (1024²),
  privacy, pricing.
- **[you]** Upload via Xcode/Transporter → TestFlight → internal test → submit
  for review.

## Snapshot of what's already solid
`flutter analyze` clean (2 known style infos), 65 tests pass, iOS native layer
(haptics, safe areas, status bar/splash, app icon), photo-permission string,
IAP/Supabase/notifications deps wired, rich feature set.
