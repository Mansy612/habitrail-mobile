// Premium billing: the upgrade flow must distinguish loading / available /
// unavailable / failed, must NEVER grant Premium for free when the store is
// loading, unavailable or failed, and access must follow a VERIFIED store
// subscription's expiry (purchase, restore, renewal, expiration, refund,
// revocation) rather than a permanent saved flag.
//
// The store is driven through a fake BillingApi (the controller's test seam),
// so init delays, failures, purchases, restores and expiry are all exercised
// without a device or App Store sandbox.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';
import 'package:habitrail/purchases.dart';

ProductDetails _prod(String id, String price) => ProductDetails(
      id: id,
      title: id,
      description: 'desc',
      price: price,
      rawPrice: 1.0,
      currencyCode: 'USD',
    );

final _bothProducts = [
  _prod(kMonthlyProductId, r'$7.99'),
  _prod(kAnnualProductId, r'$59.99'),
];

/// Fake store. Behaviour is set per test; purchase events are pushed with
/// [emit] exactly as the real `in_app_purchase` plugin would deliver them.
class FakeBilling implements BillingApi {
  FakeBilling({
    this.available = true,
    this.products = const [],
    this.productError,
    this.throwOnAvailable = false,
  });

  bool available;
  List<ProductDetails> products;
  IAPError? productError;
  bool throwOnAvailable;

  /// When set, isAvailable() blocks on this until the test completes it — used
  /// to observe the `loading` state before billing resolves.
  Completer<bool>? availableGate;

  final StreamController<List<PurchaseDetails>> _stream =
      StreamController<List<PurchaseDetails>>.broadcast();
  int buyCount = 0;
  int restoreCount = 0;
  final List<PurchaseDetails> completed = [];

  @override
  Future<bool> isAvailable() async {
    if (availableGate != null) await availableGate!.future;
    if (throwOnAvailable) throw Exception('store down');
    return available;
  }

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _stream.stream;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      ProductDetailsResponse(
          productDetails: products,
          notFoundIDs: const [],
          error: productError);

  @override
  Future<void> buyNonConsumable(
      {required PurchaseParam purchaseParam}) async {
    buyCount++;
  }

  @override
  Future<void> restorePurchases() async {
    restoreCount++;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  void emit(PurchaseStatus status,
      {String productId = kAnnualProductId, IAPError? error}) {
    final pd = PurchaseDetails(
      purchaseID: 'pid_${DateTime.now().microsecondsSinceEpoch}',
      productID: productId,
      verificationData: PurchaseVerificationData(
          localVerificationData: 'l', serverVerificationData: 's', source: 'test'),
      transactionDate: DateTime.now().toIso8601String(),
      status: status,
    )
      ..error = error
      ..pendingCompletePurchase = false;
    _stream.add([pd]);
  }

  Future<void> close() => _stream.close();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await appState.load();
    appState.resetAll();
    appState.cancelPremium(); // clear any entitlement carried over
    appState.setPremiumOverride(''); // clear any admin override
  });

  // Build a controller over the fake, close its stream when the test ends.
  PurchaseController controller(FakeBilling fake) {
    addTearDown(fake.close);
    return PurchaseController.forTest(fake);
  }

  group('billing states are distinct', () {
    test('stays loading until the store resolves, then becomes available',
        () async {
      final fake = FakeBilling(products: _bothProducts)
        ..availableGate = Completer<bool>();
      final c = controller(fake);

      final f = c.init();
      expect(c.state, BillingState.loading);
      expect(c.canBuy, isFalse);

      fake.availableGate!.complete(true);
      await f;
      expect(c.state, BillingState.available);
      expect(c.canBuy, isTrue);
    });

    test('no store on the platform → unavailable', () async {
      final c = PurchaseController.forTest(FakeBilling(), supported: false);
      await c.init();
      expect(c.state, BillingState.unavailable);
    });

    test('store reachable but products not configured → unavailable', () async {
      final c = controller(FakeBilling(available: true, products: const []));
      await c.init();
      expect(c.state, BillingState.unavailable);
    });

    test('store errors during setup → failed', () async {
      final c = controller(FakeBilling(throwOnAvailable: true));
      await c.init();
      expect(c.state, BillingState.failed);
    });

    test('product query error → failed', () async {
      final c = controller(FakeBilling(
        available: true,
        products: const [],
        productError:
            IAPError(source: 'test', code: 'e', message: 'bad'),
      ));
      await c.init();
      expect(c.state, BillingState.failed);
    });
  });

  group('a non-available store never grants free Premium', () {
    test('loading store: buy is refused and nothing is granted', () async {
      final fake = FakeBilling(products: _bothProducts)
        ..availableGate = Completer<bool>();
      final c = controller(fake);
      final f = c.init(); // left in loading
      expect(await c.buy('annual'), isFalse);
      await pumpEventQueue();
      expect(appState.isPremium, isFalse);
      fake.availableGate!.complete(true);
      await f;
    });

    test('unavailable store: buy is refused and nothing is granted', () async {
      final c = controller(FakeBilling(available: false));
      await c.init();
      expect(await c.buy('annual'), isFalse);
      await pumpEventQueue();
      expect(appState.isPremium, isFalse);
    });

    test('failed store: buy is refused and nothing is granted', () async {
      final c = controller(FakeBilling(throwOnAvailable: true));
      await c.init();
      expect(await c.buy('annual'), isFalse);
      await pumpEventQueue();
      expect(appState.isPremium, isFalse);
    });
  });

  group('access follows the verified store entitlement', () {
    test('a confirmed purchase activates Premium with a future expiry',
        () async {
      final fake = FakeBilling(products: _bothProducts);
      final c = controller(fake);
      await c.init();
      expect(c.state, BillingState.available);

      expect(await c.buy('annual'), isTrue);
      expect(fake.buyCount, 1);
      expect(appState.isPremium, isFalse, reason: 'not granted before confirm');

      fake.emit(PurchaseStatus.purchased, productId: kAnnualProductId);
      await pumpEventQueue();

      expect(appState.isPremium, isTrue);
      expect(appState.premiumPlan, 'annual');
      expect(appState.premiumVerifiedAt, isNotEmpty, reason: 'store-verified');
      expect(DateTime.parse(appState.premiumExpiresAt).isAfter(DateTime.now()),
          isTrue);
    });

    test('a restored purchase re-activates Premium', () async {
      final fake = FakeBilling(products: _bothProducts);
      final c = controller(fake);
      await c.init();

      fake.emit(PurchaseStatus.restored, productId: kMonthlyProductId);
      await pumpEventQueue();

      expect(appState.isPremium, isTrue);
      expect(appState.premiumPlan, 'monthly');
    });

    test('an errored purchase surfaces the error and grants nothing', () async {
      final fake = FakeBilling(products: _bothProducts);
      final c = controller(fake);
      await c.init();

      fake.emit(PurchaseStatus.error,
          error: IAPError(source: 'test', code: 'x', message: 'declined'));
      await pumpEventQueue();

      expect(appState.isPremium, isFalse);
      expect(c.error, isNotNull);
    });

    test('an expired entitlement is not Premium; a renewal restores it', () {
      appState.applyStoreEntitlement('annual',
          expiresAt: DateTime.now().subtract(const Duration(days: 1)));
      expect(appState.storeEntitlementActive, isFalse);
      expect(appState.isPremium, isFalse, reason: 'subscription lapsed');

      appState.applyStoreEntitlement('annual'); // renewal → future expiry
      expect(appState.isPremium, isTrue);
    });

    test('a refund / revocation from the server clears Premium', () {
      appState.applyStoreEntitlement('annual');
      expect(appState.isPremium, isTrue);

      appState.applyServerEntitlement(active: false); // refunded / revoked
      expect(appState.isPremium, isFalse);
      expect(appState.premiumExpiresAt, isEmpty);
    });

    test('admin override still wins over the store entitlement', () {
      appState.setPremiumOverride('grant');
      expect(appState.isPremium, isTrue, reason: 'gifted, no subscription');

      appState.setPremiumOverride('revoke');
      appState.applyStoreEntitlement('annual');
      expect(appState.isPremium, isFalse, reason: 'revoke beats a real sub');

      appState.setPremiumOverride('');
      expect(appState.isPremium, isTrue);
    });
  });

  group('migration off the permanent boolean', () {
    test('a legacy isPremium:true save gets a grace window, not forever',
        () async {
      SharedPreferences.setMockInitialValues({
        'habitrail.meta.v2': jsonEncode({'isPremium': true}),
      });
      await appState.load();

      expect(appState.isPremium, isTrue, reason: 'not cut off immediately');
      final exp = DateTime.parse(appState.premiumExpiresAt);
      expect(exp.isAfter(DateTime.now()), isTrue);
      expect(exp.isBefore(DateTime.now().add(const Duration(days: 8))), isTrue,
          reason: 'grace window, not a permanent entitlement');
      expect(appState.premiumVerifiedAt, isEmpty,
          reason: 'still needs a real purchase/restore to verify');
    });
  });
}
