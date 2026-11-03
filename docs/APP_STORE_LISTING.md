# Habitrail — App Store listing (draft)

Copy/paste into App Store Connect. Replace **[bracketed]** placeholders. Char
limits noted — Apple enforces them.

## App name  _(≤30 chars)_
`Habitrail: Habits & Streaks`  — 27

## Subtitle  _(≤30 chars)_
`Gamified habit tracker & RPG`  — 28

## Promotional text  _(≤170 chars, editable anytime without review)_
Build habits that stick. Earn XP, keep streaks alive, raise a companion, and
take on co-op quests with friends. Your day, leveled up.

## Keywords  _(≤100 chars, comma-separated, no spaces)_
`habit,tracker,streak,routine,daily,goals,productivity,gamify,rpg,xp,companion,journal,focus,party`

## Description  _(≤4000 chars)_
Habitrail turns building better habits into a game you actually want to play.

Check off your daily habits to earn XP, level up, and keep your streaks alive —
with a companion that grows alongside you and celebrates every win.

WHY HABITRAIL
• Fast, clean "Today" screen — your habits and check-offs come first.
• Streaks, XP, and levels that make consistency feel rewarding.
• A companion creature with its own personality that cheers you on.
• Pick a cosmetic class (Warrior, Mage, Ranger…) — pure flavor, never pay-to-win.

GO DEEPER
• Journal: rate your day, energy, mood, and focus 1–10 and jot a note.
• Focus sessions, nutrition logging, and a daily "Victory Score."
• Challenges, bosses, and quests to keep momentum fun.
• Achievements, prestige, and a progression hub to track it all.

BETTER WITH FRIENDS
• Co-op parties and public guilds with live chat.
• Shared co-op boss quests — your party's combined effort takes the boss down.
• A friends leaderboard and a global chat room.

SMART COACHING
• AI picks a fair difficulty for each new habit and suggests a fitting emoji.
• An AI coach and weekly plans help you keep going (with offline fallbacks).

PREMIUM (optional)
• Deeper insights, weekly reports, exclusive themes, companion customization,
  flexible streak recovery, guided challenges, and AI weekly plans.
• A simple monthly or annual subscription. No pay-to-win — everything that
  affects progress stays earnable by playing.

Your habits live on your device and sync to your account so you never lose a
streak when you change phones. Start free, no account required.

## What's New  _(version 1.0.0)_
First release of Habitrail 🎉 — habits, streaks, XP, companions, journaling,
co-op parties & guilds, quests, and optional Premium.

## URLs
- Support URL: **[https://your-site/support]**  (required; must be a web page,
  not an email. A simple page that lists habitrailapp@gmail.com is enough.)
- Marketing URL: **[https://your-site]**  (optional)
- Privacy Policy URL: **[host docs/PRIVACY_POLICY.md and put its URL here]**  (required)

## Category
- Primary: **Health & Fitness** (or Productivity)
- Secondary: **Productivity**

## Pricing
- Free to download; Premium via auto-renewable subscription
  (monthly $7.99 / annual $59.99 — create these in App Store Connect).

## Age rating — READ THIS
The questionnaire will likely land at **12+** because the app has **user-generated
content** (party/guild chat + a global chat room). Apple Guideline **1.2**
requires UGC apps to provide:
  1. a way to **filter objectionable content**,
  2. a way to **report** content,
  3. a way to **block** abusive users, and
  4. a published contact for reports + a commitment to act.
**In-app Report + Block are now implemented** on every chat message (long-press
→ Report / Block); reports are recorded in a `content_reports` table and blocked
users are hidden on-device. `supabase/migrations/20261029070000_content_reports.sql` is deployed, the
Terms (`docs/TERMS_OF_SERVICE.md`) state zero tolerance and action within 24h,
and the report contact is **habitrailapp@gmail.com** (in the Terms and the
privacy policy). Still to do before you submit: host the Terms publicly. Displayed chat messages are now **profanity-masked** (whole-word mask in
`maskProfanity`); swap in a maintained word list/service for production.

## Review notes (App Review "Notes" field)
- Email sign-up uses Supabase; "Confirm email" is currently off.
- Demo account: **[create one and put credentials here]** so reviewers can test
  social features without signing up.
- IAP: Premium is cosmetic/quality-of-life only; no gameplay advantage.
