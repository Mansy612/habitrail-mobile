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

/// Thin wrapper around `in_app_purchase`. iOS/Android only: on every other
/// platform (including the Windows dev build) [available] stays false, the
/// product list stays empty, and the upgrade page falls back to the in-app
/// scaffold activation. All store access is guarded so unsupported platforms
/// never touch `InAppPurchase.instance` (which would assert).
class PurchaseController extends ChangeNotifier {
  PurchaseController._();
  static final PurchaseController instance = PurchaseController._();

  bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);
  InAppPurchase get _iap => InAppPurchase.instance; // lazy; only read when supported

  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _available = false;
  bool get available => _available;
  List<ProductDetails> products = const [];
  bool busy = false;
  String? error;
  bool _initialized = false;

  /// Safe to call on any platform and more than once.
  Future<void> init() async {
    if (_initialized || !_supported) return;
    _initialized = true;
    try {
      _available = await _iap.isAvailable();
      _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
      if (_available) await _loadProducts();
    } catch (_) {
      _available = false;
    }
    notifyListeners();
  }

  Future<void> _loadProducts() async {
    final resp =
        await _iap.queryProductDetails({kMonthlyProductId, kAnnualProductId});
    products = resp.productDetails;
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
  /// not loaded (e.g. on the Windows dev build or before products resolve).
  String priceFor(String plan, String fallback) =>
      productFor(plan)?.price ?? fallback;

  /// Launch the store purchase flow. The result arrives asynchronously on the
  /// purchase stream and, on success, activates Premium.
  Future<void> buy(String plan) async {
    final p = productFor(plan);
    if (p == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _iap.buyNonConsumable(
          purchaseParam: PurchaseParam(productDetails: p));
    } catch (e) {
      error = e.toString();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> restore() async {
    if (!_supported || !_available) return;
    try {
      await _iap.restorePurchases();
    } catch (_) {}
  }

  void _onPurchases(List<PurchaseDetails> list) {
    for (final pd in list) {
      switch (pd.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          appState.activatePremium(
              pd.productID == kAnnualProductId ? 'annual' : 'monthly');
          break;
        case PurchaseStatus.error:
          error = pd.error?.message;
          break;
        case PurchaseStatus.pending:
        case PurchaseStatus.canceled:
          break;
      }
      if (pd.pendingCompletePurchase) {
        _iap.completePurchase(pd);
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
