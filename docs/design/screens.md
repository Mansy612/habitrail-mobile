# Screens

Every route, sheet and dialog in `lib/main.dart` (repo `Mansy612/habitrail-mobile` @ `2a80e3e`), where each one lives in the redesign, and what changes. The mockups are on the Screens cards: Start, Today, Focus, Progress, Friends, You, Nutrition, Moments and Tablet.

## Information architecture

| Old (6 tabs + pushes) | New (5 tabs) |
|---|---|
| Home | **Today** |
| Focus | **Focus** |
| Stats, Awards, Journal, Legacy (push), Share (push) | **Progress** → Calendar · Stats · Awards · Journal; Legacy and Share are pushed |
| Friends | **Friends** → Leaderboard · Friends |
| Settings (via avatar), Account, Appearance, Shop (via coins), Companions, Body profile, Nutrition, AI | **You** (hub) → each one pushed |

Why it changed:

- Six tabs at 10px labels was over the comfortable limit.
- Three of the six (Stats, Awards, Journal) answer the same question: how am I doing over time?
- Settings was reachable only by tapping a 34px avatar that had no label.

## Start

| Screen | Code | Redesign |
|---|---|---|
| Welcome | `WelcomeScreen` | Companion stickers, a bubble and the STREAK pill replace the 🔥 gradient orb and the three-feature glass list. A display-xl headline, then Create account (primary), Log in (secondary) and Continue without an account (ghost). |
| Sign up | `SignUpScreen` | TextField with the live username check (accent "Available" / danger "Unavailable"). The button shows a loading state in place, and the separate `_authSubmit` container is removed. Apple is shown disabled with "Available on iOS". |
| Log in | `LoginScreen` | Inline error under the password field instead of a red banner above the button. |
| Onboarding slides | `OnboardingScreen` | Four slides, each a segmented ring with a companion and a display-xl headline. Dots and Next sit at the bottom, Skip at the top right. The per-slide accent colours are dropped (accent is progress only). |
| Onboarding quiz | `OnboardingQuizScreen` (7 steps) | A progress bar with "Step n of 7". Focus areas use inverted Chips. Numeric fields are 64px tall with unit suffixes, and a Metric/Imperial toggle is added. The summary shows the calorie target, starter habits and a companion reaction. Continue stays disabled until the step is valid, as today. |

## Today

| Screen | Code | Redesign |
|---|---|---|
| Today | `HomeScreen`, `_dashboardBar`, `_DashboardHero` | Title "Today" with the count sticker. Coins pill and a + button. The level bar is now a slim line under the title. The hero is the companion in a 5-segment ring (one segment per habit) with a bubble and the streak pill. |
| Habit list | `_HabitTile` | One card labelled "THE FIVE" holding HabitRows. Done habits are struck through in `text-3`. The drag handle only appears in Edit order mode. Swipe to delete, with an Undo toast. |
| Widgets | `_VictoryCard`, `_BossCard`, `_NutritionCard` | Become a 2×2 Widget grid: Victory (ring + tier word), Weekly boss (gold dots), Nutrition (kcal bar), and Focus (minutes + Start 25), which is new and links to the timer. |
| Quests | `_QuestsPanel` | A card of compact rows with gold XP badges. Claimed quests use the accent check. |
| Companion and Prestige cards | `_CompanionCard`, `_PrestigeCard` | Leave Today. The companion is in the hero; Prestige moves to You → Companions. |
| Perfect day | (new state) | The count sticker turns accent, an accent-tint "Perfect day banked" card appears, and the companion reacts. |
| Empty | `_EmptyState` | Companion, bubble, Add your first habit, plus template chips. |
| New / edit habit | `showHabitEditor` | A sheet with name, icon chips, the AI difficulty card (rarity word + multiplier + XP) and a reminder row with a switch and time. Delete moves to the bottom of edit mode as a danger button. |
| Morning briefing | `_DailyBriefing` (5 panels) | One full-screen briefing instead of five dialog panels: headline, companion line (the coach output), Level / Streak / Today tiles, and today's quests. Single "Start the day" action. |
| Reflect | `showAddReflection` | A sheet with a mood row, a textarea and a character count. The save button states the reward. |
| Reminders | `_checkReminders` SnackBar | A glass NotificationCard from the companion, with Done and Snooze. |

## Focus

| Screen | Code | Redesign |
|---|---|---|
| Focus | `FocusScreen` | A 280px ring that drains as time passes, with a numeral-xl timer. Duration is a SegmentedControl (15/25/45/60) and locks while running. Start is accent; Pause is white; Resume is accent; Reset is secondary. The complete state shows the companion in a full ring plus +XP / Min today / Quest tiles. |
| Live activity | (new spec) | Lock-screen glass cards for the running timer and "Today 3 of 5", using the same layout as the iOS Live Activity and widgets when they are built. |

## Progress

| Screen | Code | Redesign |
|---|---|---|
| Calendar | `_HeatmapCard`, `_WeekTrendCard` | A 7-segment week ring around the companion, the big STREAK pill, and a month Calendar with streak bands. Tapping a day opens the **Day detail** sheet (new): score ring, habits, reflection, and Use Streak Shield on missed days. |
| Stats | `StatsScreen`, `_StatCard`, `_HabitStreaksCard` | Six StatTiles, a 7-bar weekly victory chart coloured by tier, habit streaks, and a link to Legacy. |
| Awards | `AwardsScreen`, `_awardsHero`, `_AchievementCard` | A gold progress ring with "next achievement" guidance, and a 2-column grid. Locked awards show a lock icon and stay readable. |
| Journal | `JournalScreen` | The Reflect button sits at the top (the FAB is removed). Entries are cards with date, mood, text, habits count and score badge. |
| Legacy | `LegacyScreen`, `_MilestoneTile` | Career-best tiles and a vertical timeline coloured by milestone type. |
| Share card | `ShareCardScreen` | A black 4:5 card: headline "12 days. Still going.", companion, streak sticker and three stats. The export is the card itself. |

## Friends

| Screen | Code | Redesign |
|---|---|---|
| Leaderboard | `_friendsRankHero`, `_leaderRow` | A podium for the top 3, a companion bubble with the gap to the next rank, and a ranked group in which your own row is tinted `accent-surface`. |
| Friends | `_friendCard`, `_suggestionCard`, `_AddFriendField` | An inline add field, a friends group with quiet streak pills, and suggested friends with a secondary Add. |
| Friend profile | `FriendProfileScreen` | Avatar sticker and three stats. "Compared to you" uses split bars per metric. Send a nudge is new, and Remove friend is a danger button. |
| Empty / error / loading | — | Empty companion card, an inline "No user called @x" error, and a skeleton for suggestions. |

## You

| Screen | Code | Redesign |
|---|---|---|
| You | `SettingsScreen` | Profile card with level bar, Companion and Shop shortcuts, then grouped ListRows: Account, Preferences, Data. |
| Account | `AccountScreen` | Avatar with camera badge, stats, Edit name, Cloud sync status, and Delete account as a danger row. |
| Appearance | `AppearanceScreen` | A live preview of the accent (ring, dots, bar) above a theme grid with an Active badge, Apply, or a price. |
| Shop | `ShopScreen`, `_balanceHero`, `_buyPill`, `_shopItem` | Balance card, then Power-ups · Borders · Themes segments. Gold buy pills when affordable; disabled with "760 to go" when not, replacing the "Not enough coins" toast after the fact. |
| Companions | `CompanionsScreen`, `_CompanionCard`, `_PrestigeCard` | Active companion with its line, a 3-column sticker grid (locked ones show their unlock level), and the Prestige card. |
| Body profile | `BodyProfileScreen`, `_dropdown` | Dropdowns become SegmentedControls and Chips. A computed-targets card updates live. Save sits in the top bar. |
| AI difficulty | `AiSettingsScreen` | A switch row, URL and model fields, Test connection with an in-button spinner, and a danger card when the server can't be reached, plus How it works and Setup. |
| Nutrition | `NutritionScreen`, `_macroBar`, `_FoodTile` | Calorie ring, nutrition score, macro bars (protein accent, carbs info, fat gold), and the meal list. |
| Log food | `showAddFood` | A sheet: describe the meal → Estimate with AI → an editable estimate. When offline, an error card plus manual fields, with Add disabled until calories are entered. |

## Moments

| Moment | Code | Redesign |
|---|---|---|
| Level up | `_showLevelUp` | A full-screen ring with the numeral, the new title and the companion's level_up line. Confetti respects reduced motion. |
| Achievement | `_showAchievementUnlocked` | A gold sticker, the name, the rarity word, and "+N more unlocked". |
| Boss defeated | `_showBossDefeat` | A gold-lit takeover with five gold dots, the rewards as tiles, the companion line, and a gold Claim button. |
| Prestige confirm / reborn | `_confirmPrestige`, `_showPrestige` | A consequence dialog that says what resets and what stays, then a reborn takeover. |
| New season | `_showSeasonIntro` | A 4-segment gold ring (four bosses) and Begin. |
| Reset | `_confirmReset` | A danger dialog: "Reset everything" / Cancel. |
| Toasts | `_toast`, SnackBars | A single surface-2 pill above the tab bar, with Undo for reversible actions and an offline notice. |

## Building it in Flutter

Order of work, each step shippable:

1. **Tokens and theme.** `lib/ui/hr_tokens.dart` + `hr_theme.dart` from this system's `tokens.json`. Replace `k*` colour constants and `_kGlassSheen` / `_kAccentGradient` / `glassDecoration`. Keep `applyThemeColors` but point it at the six accent triples. Remove `_ParticleBackground`.
2. **Primitives.** `HrButton`, `HrCard`, `HabitRow`, `ProgressDots`, `SegmentedRing`, `CountSticker`, `StreakPill`, `CompanionSticker`, `SpeechBubble`, `HrTabBar`, `HrSegmented`, `HrToast`.
3. **Navigation.** Move to 5 tabs and fold Stats, Awards and Journal into Progress.
4. **Screens**, in order of traffic: Today → Focus → Progress → You → Friends → Start → Moments.
5. Split `main.dart` (7,221 lines) into `lib/screens/<area>/…` as each screen is rebuilt.
