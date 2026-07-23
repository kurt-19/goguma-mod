import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const additionalServerSubscriptionId = 'additional_server_monthly';
const _entitlementKey = 'additional_server_subscription_active';

class AdditionalServerSubscription extends ChangeNotifier {
  AdditionalServerSubscription()
      : _store = InAppPurchase.instance,
        _storeEnabled = Platform.isAndroid;

  AdditionalServerSubscription.cached(bool entitled)
      : _store = InAppPurchase.instance,
        _storeEnabled = false,
        _entitled = entitled,
        _initialized = true;

  final InAppPurchase _store;
  final bool _storeEnabled;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  ProductDetails? _product;
  bool _available = false;
  bool _entitled = false;
  bool _initialized = false;
  bool _loading = false;
  bool _activePurchaseSeen = false;
  String? _error;

  bool get available => _available;
  bool get entitled => _entitled;
  bool get loading => _loading;
  String? get error => _error;
  String get price => _product?.price ?? r'$5.00';

  static Future<AdditionalServerSubscription> fromCache() async {
    var prefs = await SharedPreferences.getInstance();
    return AdditionalServerSubscription.cached(
      prefs.getBool(_entitlementKey) ?? false,
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    var prefs = await SharedPreferences.getInstance();
    _entitled = prefs.getBool(_entitlementKey) ?? false;
    if (!_storeEnabled) {
      notifyListeners();
      return;
    }

    _purchaseSub = _store.purchaseStream.listen(
      _handlePurchases,
      onError: (Object error) {
        _error = error.toString();
        _setLoading(false);
      },
    );
    await refresh();
  }

  Future<void> refresh() async {
    if (!_storeEnabled || _loading) return;
    _setLoading(true);
    _error = null;
    try {
      _available = await _store.isAvailable();
      if (!_available) {
        _error = 'Google Play billing is unavailable';
        return;
      }

      var response = await _store.queryProductDetails(
        const {additionalServerSubscriptionId},
      );
      _product = response.productDetails.isEmpty
          ? null
          : response.productDetails.first;
      _error = response.error?.message;
      if (_product == null) {
        _error ??= 'Subscription is not configured in Google Play';
      }

      _activePurchaseSeen = false;
      await _store.restorePurchases();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!_activePurchaseSeen) {
        await _setEntitled(false);
      }
    } on Exception catch (error) {
      _error = error.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> purchase() async {
    if (!_available || _product == null) {
      await refresh();
    }
    var product = _product;
    if (!_available || product == null) return false;

    _error = null;
    _setLoading(true);
    try {
      return await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
    } on Exception catch (error) {
      _error = error.toString();
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> restore() => refresh();

  bool canUseServer(int serverId, Iterable<int> serverIds) {
    if (_entitled) return true;
    int? primaryServerId;
    for (var id in serverIds) {
      if (primaryServerId == null || id < primaryServerId) {
        primaryServerId = id;
      }
    }
    return primaryServerId == null || serverId == primaryServerId;
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (var purchase in purchases) {
      if (purchase.productID != additionalServerSubscriptionId) continue;
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _activePurchaseSeen = true;
          await _setEntitled(true);
          _error = null;
          break;
        case PurchaseStatus.error:
          _error = purchase.error?.message ?? 'Purchase failed';
          break;
        case PurchaseStatus.pending:
          _loading = true;
          break;
        case PurchaseStatus.canceled:
          break;
      }
      if (purchase.pendingCompletePurchase) {
        await _store.completePurchase(purchase);
      }
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> _setEntitled(bool value) async {
    if (_entitled == value) return;
    _entitled = value;
    var prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_entitlementKey, value);
    notifyListeners();
  }

  void _setLoading(bool value) {
    if (_loading == value) return;
    _loading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }
}
