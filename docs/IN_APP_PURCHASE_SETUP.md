# Habitrail Premium — in-app purchase setup

The app is wired for real subscriptions via the `in_app_purchase` plugin
(`lib/purchases.dart`). The code is done; the steps below are the parts only you
can do (store products, agreements, native capabilities). Until they're
complete, iOS/Android show "Premium unavailable"-style empty products, and the
Windows dev build uses the instant-activate fallback so Premium stays testable.

## Product IDs (must match exactly)

Defined in `lib/purchases.dart`:

- `habitrail_premium_monthly` — monthly auto-renewing subscription (~$7.99/mo)
- `habitrail_premium_annual` — annual auto-renewing subscription (~$59.99/yr)

The displayed prices come from the store once products load; the constants in
`lib/core.dart` (`kPremiumMonthlyPrice` / `kPremiumAnnualPrice`) are only
fallbacks for platforms without a store.

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

- Real purchases run only on iOS/Android. On Windows/desktop,
  `PurchaseController.available` is false and the upgrade page falls back to the
  in-app scaffold activation (the `kDebugMode` toggle and instant "Start
  Premium" still work for QA).
- Sandbox/test purchases do not charge real money but exercise the full flow,
  including restore.

## Production hardening (recommended, not yet done)

- Validate receipts server-side (e.g. via Supabase Edge Functions) before
  granting entitlement, instead of trusting the client. `activatePremium` is
  currently called directly from the client purchase stream.
- Persist/restore entitlement from the store (or your backend) on launch so a
  reinstall restores Premium without a manual "Restore purchases" tap.
