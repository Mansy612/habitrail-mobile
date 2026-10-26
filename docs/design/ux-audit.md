# UX audit

Findings from reading `lib/main.dart` and `lib/core.dart` at `2a80e3e`, and how the redesign resolves each one. The contrast figures are WCAG 2 ratios, computed against the old surfaces composited over `kBase`.

## Visual and accessibility

| # | Finding | Evidence | Resolution |
|---|---|---|---|
| 1 | **The primary button ignores the theme.** `GradientButton` hard-codes `_kAccentGradient` (#8B5CF6→#22D3EE) and a violet glow. Buy the Tokyo theme and every primary button stays violet. | `main.dart:1955`, `:1990` | Primary is white; accent buttons read `accent`, which the theme swaps. |
| 2 | **White label on the gradient fails contrast.** Against the cyan end the ratio is 1.8:1; against violet, 4.2:1. | `GradientButton` | Black on white (21:1) and black on accent (≥7.4:1). |
| 3 | **Tertiary text is under 4.5:1.** `kTextTertiary` (45% alpha) measures 3.7–4.1:1 on cards and the hero. It is used for section labels, subtitles, hints and every 11–12px caption. | `core.dart:24` | `text-3` is solid #8E8E93 (5.2:1 on surface, 6.4:1 on bg). |
| 4 | **Text is too small.** It goes down to 9–10px (the ring "today" label, nav labels, the `_stateChip` label at 10.5). | `fontSize: 9` ×5, `10` ×6 | `micro` 11px is the floor. |
| 5 | **The card edge is invisible.** `kBorder` (white 15%) is 1.5:1, so cards are told apart only by the violet gradient. | `core.dart:12` | Black vs `surface` is the boundary (1.3:1 is acceptable for a surface, not a control). Controls get `control-border` (4.1:1). |
| 6 | **Accent on the glass sheen is under 4.5:1.** `kPlasma` used as text (the "Edit order"-type links, the `+xp` in Quests) measures 3.8:1 on the sheen top. | `_QuestsPanel` | Accent text is ≥6:1 on `surface` in every theme. |
| 7 | **The always-on particle background.** A 24-second `AnimationController` repaints 46 particles plus 3 radial orbs at 60fps behind every screen, including static ones. It costs battery and ignores reduced motion. | `_ParticleBackground` | Removed. The ground is a static black. |
| 8 | **Three type families' worth of styles.** Space Grotesk headings, Plus Jakarta body, and a mix of `TextStyle` literals: 30 distinct font sizes in `main.dart`. | grep `fontSize` | One family with 13 named styles. |
| 9 | **Fifteen radii** (4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26 …). | grep `circular(` | Six radius tokens. |
| 10 | **Emoji as UI.** 🔥 is the app's logo; ⚡🏆🐾 sit in feature rows; ♂️♀️⚧️ appear in the gender picker. Emoji render differently on each OS and read oddly to screen readers. | Welcome, quiz | Emoji are kept for user content (habit icons, mood). System UI uses Material Symbols and stickers. |

## Interaction and flow

| # | Finding | Resolution |
|---|---|---|
| 11 | Six bottom tabs, and Settings is reachable only through an unlabelled avatar. | Five tabs; You is a labelled tab. |
| 12 | Coins and Shop are two adjacent targets for the same destination. | One coins pill. |
| 13 | Swipe-to-delete on a habit deletes immediately, with no undo. | Undo toast for 4 seconds. |
| 14 | The habit drag handle shows on every row, all the time. | Only in Edit order mode. |
| 15 | The Daily Briefing is five consecutive dialog panels, blocking (`barrierDismissible: false`), on every first open. | One full-screen briefing with a single action. |
| 16 | Shop lets you tap Buy and only then says "Not enough coins". | The pill is disabled and states the shortfall up front. |
| 17 | The loading button swaps the whole widget (`_authSubmit`), so its size and position jump. | The spinner sits inside the same button. |
| 18 | The focus duration chips stay tappable while a session runs (silently ignored by `if (_started) return`). | The segmented control is visibly disabled while running. |
| 19 | Reminders appear as a generic SnackBar ("⏰ Time for: X"), which is easy to miss and has only a Done action. | A companion NotificationCard with Done and Snooze. |
| 20 | Cloud sync copy says "Supabase wires in later" to end users. | Show sync status (on / last synced / offline), never implementation notes. |
| 21 | Many empty states describe the action ("Tap 'Log food'") instead of offering it. | The empty state contains the button. |
| 22 | There is no keyboard focus styling, although the app ships for desktop (window_manager) and web. | A 2px focus ring on every control. |

## Kept from the old system

The fade + slide page transition, haptics on completion, the animated ring and bar fills (re-timed), rarity and victory tiers, the companion lines, the six purchasable themes (re-coloured for the black ground), and every feature.

## Old values, for reference

The old palette was `kBase` #07040F, `kCard` #1A0F34 @80%, `kElevated` #221445 @85%, `kBorder` #FFFFFF26, `kPlasma` #8B5CF6 / `Bright` #A78BFA / `Glow` #C4B5FD, `kCyan` #22D3EE, `kGold` #FBBF24, `kBlue` #4F7CFF, `kGreen` #34D399, `kRed` #FB7185, and text #F4F1FB at 100 / 62 / 45%.
