// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import '../../billing_client_wrappers.dart';

/// The class represents the information of a product as registered in at
/// Google Play store front.
class GooglePlayProductDetails extends ProductDetails {
  /// Creates a new Google Play specific product details object with the
  /// provided details.
  GooglePlayProductDetails({
    required super.id,
    required super.title,
    required super.description,
    required super.price,
    required super.rawPrice,
    required super.currencyCode,
    required this.skuDetails,
    required super.currencySymbol,
  });

  /// Generate a [GooglePlayProductDetails] object based on an Android
  /// [SkuDetailsWrapper] object.
  factory GooglePlayProductDetails.fromSkuDetails(
    SkuDetailsWrapper skuDetails,
  ) {
    return GooglePlayProductDetails(
      id: skuDetails.sku,
      title: skuDetails.title,
      description: skuDetails.description,
      price: skuDetails.price,
      rawPrice: skuDetails.priceAmountMicros / 1000000.0,
      currencyCode: skuDetails.priceCurrencyCode,
      currencySymbol: skuDetails.priceCurrencySymbol,
      skuDetails: skuDetails,
    );
  }

  /// Points back to the [SkuDetailsWrapper] object that was used to generate
  /// this [GooglePlayProductDetails] object.
  final SkuDetailsWrapper skuDetails;
}
