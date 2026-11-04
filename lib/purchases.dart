import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'core.dart';

/// Store product IDs — these must match the auto-renewing subscriptions you
/// create in App Store Connect and Google Play Console. See
/// docs/IN_APP_PURCHASE_SETUP.md.
const String kMonthlyProductId = 'habitrail_premium_monthly';
const String kAnnualProductId = 'habitrail_premium_annual';

/// How ready billing is, surfaced to the upgrade UI so it can tell these apart
/// instead of collapsing them into one "not available" bool:
///   • loading     — init is in flight; we don't yet know if billing works;
///   • available   — the store is reachable AND our subscriptions resolved, so
///                   a purchase can be started;
///   • unavailable — the platform has no store, or the store is reachable but
///                   our products aren't configured/approved yet;
///   • failed      — the store errored while we were setting up.
/// Only [available] may start a purchase, and NONE of these ever grants Premium
/// for free in a release build — entitlement is recorded only when the store
/// confirms a purchase on the purchase stream.
enum BillingState { loading, available, unavailable, failed }

/// The slice of `in_app_purchase` the controller uses, behind a seam so tests
/// can drive store states (init delays, failures, purchases, restores, expiry)
/// without a device or App Store sandbox.
abstract class BillingApi {
  Future<bool> isAvailable();
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids);
  Future<void> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchase);
}

/// Real implementation, backed by the plugin. Only constructed on a supported
/// platform (so `InAppPurchase.instance` is never touched where it would
/// assert — e.g. the Windows dev build).
class _StoreBillingApi implements BillingApi {
  final InAppPurchase _iap = InAppPurchase.instance;
  @override
  Future<bool> isAvailable() => _iap.isAvailable();
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) =>
      _iap.queryProductDetails(ids);
  @override
  Future<void> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _iap.buyNonConsumable(purchaseParam: purchaseParam);
  @override
  Future<void> restorePurchases() => _iap.restorePurchases();
  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _iap.completePurchase(purchase);
}

/// Thin wrapper around `in_app_purchase`. iOS/Android only: on every other
/// platform (including the Windows dev build) [state] is [BillingState.unavailable],
/// the product list stays empty, and no purchase can be started.
class PurchaseController extends ChangeNotifier {
  PurchaseController._();

  /// Test seam: inject a fake [BillingApi] and force platform support, so the
  /// whole billing lifecycle can be exercised in `flutter test`.
  @visibleForTesting
  PurchaseController.forTest(BillingApi api, {bool supported = true}) {
    _api = api;
    _supportedOverride = supported;
  }

  static final PurchaseController instance = PurchaseController._();

  BillingApi? _api;
  bool? _supportedOverride;

  bool get _supported =>
      _supportedOverride ?? (!kIsWeb && (Platform.isIOS || Platform.isAndroid));
  // Created lazily and only on a supported platform (or injected in tests).
  BillingApi get _billing => _api ??= _StoreBillingApi();

  StreamSubscription<List<PurchaseDetails>>? _sub;
  BillingState _state = BillingState.loading;
  BillingState get state => _state;

  /// True only when a purchase can actually be started.
  bool get canBuy => _state == BillingState.available;

  /// Back-compat alias used around the UI.
  bool get available => _state == BillingState.available;

  List<ProductDetails> products = const [];
  bool busy = false;
  String? error;
  bool _initialized = false;

  /// Safe to call on any platform and more than once.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!_supported) {
      _setState(BillingState.unavailable);
      return;
    }
    _setState(BillingState.loading);
    try {
      // Attach the purchase observer first so store-pushed renewals / restored
      // transactions are never missed while products load.
      _sub ??= _billing.purchaseStream.listen(
        _onPurchases,
        onError: (_) {
          error = 'The store connection was interrupted.';
          busy = false;
          _setState(BillingState.failed);
        },
      );
      final ok = await _billing.isAvailable();
      if (!ok) {
        _setState(BillingState.unavailable);
        return;
      }
      await _loadProducts();
    } catch (_) {
      _setState(BillingState.failed);
    }
  }

  Future<void> _loadProducts() async {
    final resp =
        await _billing.queryProductDetails({kMonthlyProductId, kAnnualProductId});
    products = resp.productDetails;
    if (resp.error != null) {
      _setState(BillingState.failed);
    } else if (products.isEmpty) {
      // Store is reachable but our subscriptions aren't live yet — can't sell.
      _setState(BillingState.unavailable);
    } else {
      _setState(BillingState.available);
    }
  }

  void _setState(BillingState s) {
    _state = s;
    notifyListeners();
  }

  ProductDetails? productFor(String plan) {
    final id = plan == 'annual' ? kAnnualProductId : kMonthlyProductId;
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Localized store price for [plan], or [fallback] when the store price is
  /// not loaded (e.g. before products resolve, or off iOS/Android).
  String priceFor(String plan, String fallback) =>
      productFor(plan)?.price ?? fallback;

  /// Launch the store purchase flow. Returns false (and changes nothing) unless
  /// billing is [BillingState.available]; it NEVER grants Premium on its own —
  /// the entitlement is recorded only when the store confirms the purchase on
  /// [_onPurchases]. The result arrives asynchronously on the purchase stream.
  Future<bool> buy(String plan) async {
    if (_state != BillingState.available) return false;
    final p = productFor(plan);
    if (p == null) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _billing.buyNonConsumable(
          purchaseParam: PurchaseParam(productDetails: p));
      return true;
    } catch (e) {
      error = e.toString();
      busy = false;
      notifyListeners();
      return false;
    }
  }

  /// Ask the store to re-deliver the user's active purchases (restore on a new
  /// device, or re-verify the current entitlement). Only meaningful when the
  /// store is available; results arrive on the purchase stream.
  Future<void> restore() async {
    if (_state != BillingState.available) return;
    try {
      await _billing.restorePurchases();
    } catch (_) {}
  }

  void _onPurchases(List<PurchaseDetails> list) {
    for (final pd in list) {
      switch (pd.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // A store-confirmed purchase / restore / renewal. Record a *verified*
          // entitlement; its expiry (not a permanent flag) decides access.
          // StoreKit1's PurchaseDetails carries no expiry date, so a server
          // receipt check supplies the authoritative one in production (see
          // docs/IN_APP_PURCHASE_SETUP.md); until then the plan period from now
          // is used and each renewal event extends it.
          appState.applyStoreEntitlement(
              pd.productID == kAnnualProductId ? 'annual' : 'monthly');
          error = null;
          break;
        case PurchaseStatus.error:
          error = pd.error?.message ?? 'The purchase could not be completed.';
          break;
        case PurchaseStatus.canceled:
        case PurchaseStatus.pending:
          break;
      }
      if (pd.pendingCompletePurchase) {
        _billing.completePurchase(pd);
      }
    }
    busy = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final purchases = PurchaseController.instance;
