import 'product.dart';

class CartItem {
  final Product product;
  int quantity;
  final bool isScanned;

  CartItem({
    required this.product,
    this.quantity = 1,
    this.isScanned = false,
  });

  int get totalPrice => product.mrp * quantity;
}
