Habitrail is a habit tracker that plays like a game: five habits a day, XP, streaks, a weekly boss, and a companion who keeps you honest. The interface is **black, white and one accent**. Personality comes from stickers and the companion's voice, not from gradients or glow.

## Principles

1. **Black ground, grey surfaces, white type.** Depth is `bg` → `surface` → `surface-2`. No gradients on surfaces, no glow, no drop shadows on cards.
2. **One accent means progress.** `accent` marks only things that are done or advancing: checks, filled dots, ring arcs, perfect days. If it isn't progress, it isn't accent.
3. **Every colour has one job.** `streak` (orange) is fire. `gold` is coins, XP and the boss. `danger` is destructive and error. `info` is neutral highlights. Never reuse one for another's job.
4. **Stickers carry personality.** These are the die-cut companion, the count sticker (`3/5`), the big STREAK pill and the speech bubble. Use at most two stickers on a screen, never on a form, and never as the only carrier of information.
5. **One primary action per screen.** It is the white pill (`btn-primary`). Everything else is `surface-2` or ghost.
6. **Numbers are the headline.** Lead with the number: 3/5, 12 days, 72, 1,240. Set it big, in tabular figures, with the label small beneath.

## Content and voice

- The **app** speaks plainly, in second person and sentence case: "Add your first habit", "You're #2 of 5". Button labels start with a verb and are three words at most. Never use "OK"; name the action ("Reset everything", "Claim").
- The **companion** speaks only in a SpeechBubble. It is short, dry and a little harsh, and never cruel about the person. "Two left. Don't make me watch you stop at 3/5." Lines come from `kCompanionLines`, which each companion keys by trigger. The new triggers this design needs (`behind`, `perfect_day`, `empty`, `briefing`) must be written in each companion's voice. Shade stays "." for every trigger.
- Use emoji only where the user chose them (habit icons, reflection mood) and in moment headlines. Never use emoji as decoration on cards or rows. System icons are Material Symbols Rounded.
- Use numbers with separators (1,240) and units (kcal, min, g). Abbreviate thousands only inside stat tiles (8.2k).

## Colour

- `bg` #000 is the page. `surface` holds cards, widgets, grouped lists and sheets. `surface-2` holds inputs, chips, secondary buttons and pressed rows. `surface-3` is for tracks only.
- Text is `text` (primary), `text-2` (secondary, the default for card body) or `text-3` (labels, metadata, completed habits). Don't put `text-3` on `surface-2` or `accent-surface`; use `text-2` there. `text-disabled` is for disabled controls only.
- Anything filled with `accent` carries `on-accent` (black) content. All six accents are bright, so white on them fails contrast in every theme.
- `accent-surface` is the dark tint used for streak bands on the calendar, accent badges and the perfect-day card.
- Rarity uses `rarity-common` / `rare` / `epic` / `legendary` / `mythic`. Victory score uses `victory-elite` / `great` / `good` / `fair` / `low`. Always show the word with the colour.
- The **Appearance themes** (Rail Green default, Habitrail Violet, Neon Tokyo, Solar Gold, Crimson, Arctic) change `accent`, `accent-pressed` and `accent-surface` only. Nothing else changes. On Crimson the accent is close to `danger-text`, so missed and error states must keep their icon and word.
- Use `glass` (blue-grey over a 24px blur) only for things that float over content: notifications, live activity and the reminder card. It is never used for static cards.

## Type

- One family: **Plus Jakarta Sans** (already loaded through `google_fonts`), with the system font as fallback. Space Grotesk is retired.
- `display-xl` is the one headline on onboarding and moments. `display` is the tab title. `title-1` is for heroes and sheet titles, `title-2` for card titles, `body` 600 for habit and row titles, `caption` for metadata. `label-caps` is the uppercase `text-3` section label. `micro` is the floor: nothing renders smaller than 11px. The old 9–10px labels are gone.
- Numerals use `numeral-xl` (timer, level), `stat` (tiles) and `sticker` (the count sticker), always with tabular figures.
- Letter-spacing tightens as size grows (−1.2px at 40). Use line-height around 1.05 for display and 1.35–1.4 for body.

## Space, shape and layout

- Phones have a 20px gutter (`space-20`). Sections sit `space-16` apart and cards use `space-16` padding. The widget grid has a `space-12` gap. A primary button block sits `space-24` below the content.
- Radii: `radius-lg` (22) for cards, widgets, groups and the calendar. `radius-xl` (28) for sheets and dialogs. `radius-md` (14) for inputs and stat tiles. `radius-sm` (10) for icon tiles. `radius-full` for buttons, chips and pills.
- Shadows: `shadow-float` only on things that float (sheets, dialogs, toasts, notifications). `shadow-sticker` (a hard 4px offset) only on stickers.
- **Breakpoints.** Below 600px: a single column and the bottom TabBar. From 600 to 1024px: a navigation rail and two columns (list on the left, widgets or detail on the right), as on the Tablet page. Above 1024px: the same layout with the content capped at 1,200px. The desktop build's phone-shaped window (400×860) stays a phone layout.

## Navigation

The app has five tabs: **Today · Focus · Progress · Friends · You**.

- Progress uses a SegmentedControl: Calendar · Stats · Awards · Journal. Legacy and Share card are pushed from it.
- You holds the profile, Companions, Shop, Account, Appearance, Body profile, Nutrition and AI difficulty, plus Reset and Log out.
- Create and edit flows open as sheets. Destructive confirmations open as dialogs. Celebrations are full-screen moments.
- The full screen-by-screen map is in the Screens section.

## Components

Each component card has its guidelines. The ones that define the look:

- **HabitRow** inside one Card with the section label "THE FIVE"
- **CountSticker**
- **SegmentedRing** around a **CompanionSticker**
- **StreakPill**
- **SpeechBubble**
- **Calendar** with streak bands
- **Widget** tiles

Previews here are hand-written HTML/CSS renditions of the Flutter widgets. They are specs, not shipped code. The Flutter implementation lives in `lib/ui/` (see the Screens section).

## States

- **Pressed:** buttons scale to 0.97, cards to 0.98, and rows take a `surface-2` fill.
- **Focus:** a 2px solid `focus-ring` with 2px offset on every control, which keyboard users on desktop and web will see.
- **Disabled:** a `surface-2` fill with `text-disabled`. Opacity hacks are not used.
- **Loading:** a spinner inside the button for actions, and a Skeleton for content, shown only after 300ms.
- **Error:** inline, under the field or in a `danger-surface` card, with an icon and a sentence that says what to do next.
- **Success:** confirmations appear as a Toast. Reversible actions (delete habit, remove friend) get a Toast with Undo instead of a confirm dialog.

## Motion

- **Durations:** 120ms (press), 200ms (state changes, tabs, segments), 320ms (enter, sheets, moments), 460–520ms (bars and rings filling).
- **Easing:** standard `cubic-bezier(.2,0,0,1)`, plus the `easeOutBack` spring for checks and sticker pops.
- **Page transitions:** keep the existing fade + 3.5% slide (`_FadeSlidePageTransitionsBuilder`).
- **Lists:** stagger 40ms per item, capped at 200ms.
- **Haptics:** `selectionClick` when a habit is checked, `mediumImpact` on moments.
- **Reduced motion** (`MediaQuery.disableAnimations` / `prefers-reduced-motion`): no stagger, pop or confetti. Values jump to their end state and cross-fades drop to 1ms.
- **Removed:** the always-running particle background (a 24s loop at 60fps, a battery cost on every screen) and the glow blurs.

## Iconography

- Use Material Symbols **Rounded**: outline when inactive, filled when active or selected. This is the same family the app already uses through `Icons.*_rounded`. In Flutter the icons stay `Icons.*_rounded`, and the HTML previews load Material Symbols Rounded from Google Fonts.
- Sizes: 22 (rows), 26 (tabs), 18–20 (inside buttons and pills).
- Icons always pair with text in rows and buttons. Icon-only buttons carry a tooltip or semantic label.

## Logo

The repository has no logo. The launcher icons are still Flutter's defaults, and the welcome screen used a 🔥 emoji. Until there is a mark, set the name in Plus Jakarta Sans 800 and use the Ember companion sticker as the app icon placeholder. Commission a real mark before release.

## Accessibility

- Text pairs meet 4.5:1 in every theme; each token's usage note states its ratios. Accents against their tracks meet 3:1.
- Status is never colour alone. Missed, partial and perfect days have different glyphs, rarity and victory tiers show the word, and dots and rings carry an `aria-label` or `Semantics`.
- Hit targets are at least 44×44.
- Text scales with the system setting up to 200%. Count stickers and the timer cap at 1.3× and wrap.
