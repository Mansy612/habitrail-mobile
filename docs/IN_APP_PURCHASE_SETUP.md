# Habitrail Premium — in-app purchase setup

The app is wired for real subscriptions via the `in_app_purchase` plugin
(`lib/purchases.dart`). The code is done; the steps below are the parts only you
can do (store products, agreements, native capabilities, server notifications).

The upgrade page reports an explicit billing state — **loading**, **available**,
**unavailable**, or **failed** (`BillingState` in `lib/purchases.dart`) — and
only **available** can start a purchase. A loading, unavailable or failed store
**never** grants Premium in a release build; the only free activation is a
`kDebugMode`-gated developer shortcut that is compiled out of release builds.
Until the store steps below are complete, iOS/Android report `unavailable`
(empty products), so real devices simply can't start a purchase yet.

## Product IDs (must match exactly)

Defined in `lib/purchases.dart`:

- `habitrail_premium_monthly` — monthly auto-renewing subscription (~$7.99/mo)
- `habitrail_premium_annual` — annual auto-renewing subscription (~$59.99/yr)

The displayed prices come from the store once products load; the constants in
`lib/core.dart` (`kPremiumMonthlyPrice` / `kPremiumAnnualPrice`) are only
fallbacks for platforms without a store.

## Billing states & the entitlement model

Access is driven by a **verified subscription with an expiry**, not a saved
"isPremium" flag (`AppState.premiumExpiresAt` / `storeEntitlementActive` in
`lib/core.dart`):

- A store-confirmed purchase, restore or renewal calls
  `appState.applyStoreEntitlement(plan)` from the purchase stream, which records
  the plan and an expiry and marks it store-verified.
- `isPremium` is true only while `now < premiumExpiresAt` (or an admin
  `premiumOverride == 'grant'`). When the period passes, access lapses on its
  own — no event required.
- A refund, revocation or cancellation clears access via
  `appState.applyServerEntitlement(active: false)` (see the server section).

Because StoreKit 1's `PurchaseDetails` does not carry the subscription's expiry,
the client uses the plan length from "now" and extends it on each renewal event.
The **authoritative** expiry (and refunds/revocations) comes from the server
step below. A pre-existing permanent-`isPremium` save is migrated to a 7-day
grace window (not honored forever), so existing users aren't cut off but must
make a verified purchase/restore to continue.

## App Store Connect (iOS)

1. Agreements, Tax, and Banking → accept the Paid Applications agreement.
2. Your app → Subscriptions → create a Subscription Group (e.g. "Habitrail
   Premium").
3. Add two subscriptions with the product IDs above; set duration (monthly /
   yearly) and price; add a localized display name and description.
4. Xcode → `ios/Runner` target → Signing & Capabilities → add the **In-App
   Purchase** capability.
5. Create a Sandbox tester (Users and Access → Sandbox) and sign in to it on a
   real device to test. StoreKit is not available on the iOS Simulator for live
   products (use a device, or a StoreKit configuration file for local testing).

## Google Play Console (Android)

1. Set up a merchant account and accept the agreements.
2. Monetize → Products → Subscriptions → create two subscriptions with the
   product IDs above, each with a base plan (monthly / yearly) and price.
3. Upload at least one build to an internal test track and add license testers
   (Setup → License testing) so purchases are free in test.
4. `in_app_purchase_android` adds the `com.android.vending.BILLING` permission
   via manifest merge — verify it is present in the merged manifest.

## Testing

- Automated: `test/functional/premium_billing_test.dart` drives a fake store
  (the `BillingApi` seam) through init delay → available, unavailable, failed,
  purchase, restore, errored purchase, expiry, renewal, refund/revocation and
  the admin override — no device needed. Run `flutter test`.
- Real purchases run only on iOS/Android. On desktop the state is `unavailable`;
  in a **debug** build the "Start Premium" button then activates Premium locally
  (and a `kDebugMode` Premium toggle sits on the coach card) so QA can exercise
  gated features without a store. Neither path exists in a release build.
- On device, use an App Store **Sandbox** tester (or a local **StoreKit
  configuration file** in Xcode) and a Google Play **license tester**. Sandbox
  renewals are accelerated (a "monthly" sub renews every few minutes), which is
  the easy way to watch renewal and expiration behave.

## Server validation & App Store Server Notifications (required for production)

The client lapses access at the period end and exposes
`appState.applyServerEntitlement(active:, plan:, expiresAt:)` as the hook for
server-authoritative state. To make renewal/expiration **accurate** and to honor
**refunds and revocations** (which the client cannot observe on its own), add a
small backend — the app already uses Supabase Edge Functions (`ai-proxy`), so an
`iap-webhook` function fits the same pattern:

1. **App Store Connect → your app → App Information → App Store Server
   Notifications**: set the Production and Sandbox **Version 2** URLs to the Edge
   Function endpoint. It receives `SUBSCRIBED`, `DID_RENEW`, `EXPIRED`,
   `DID_CHANGE_RENEWAL_STATUS`, `REFUND` and `REVOKE` events.
2. In the function, verify the signed JWS payload against Apple's root certs
   (or use Apple's `app-store-server-library`), then upsert the user's
   entitlement `{active, plan, expires_at}` keyed by account — reuse the
   `profiles` / `user_backups` pattern.
3. (Android) mirror this with **Google Play Real-time Developer Notifications**
   over Pub/Sub, plus a `Purchases.subscriptions.get` check.
4. The app reads that row (on launch / resume, alongside `syncAccountStatus`) and
   calls `applyServerEntitlement(...)`, so a refund or revocation drops Premium
   and a renewal extends the real expiry. Validate the purchase receipt
   server-side before trusting a client purchase event, too.

Until this is deployed, entitlement is client-computed from the plan length: it
is correct for purchase, restore, renewal-while-running and expiry, but refunds
and revocations won't be reflected until the next verified store event.
