import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import * as cartService from '../services/cartService';
import { friendlyDbError } from '../utils/errors';
import { useAuth } from './AuthContext';

const CartContext = createContext(null);
const NO_CARTS = [];

// A customer has one basket per restaurant. `carts` is the list of non-empty baskets; every price in it comes from the database.
export function CartProvider({ children }) {
  const { user, role } = useAuth();
  const isCustomer = role === 'customer';
  const userId = user?.id;

  const [carts, setCarts] = useState(NO_CARTS);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState('');

  const refresh = useCallback(async () => {
    setLoading(true);
    setLoadError('');
    try {
      setCarts(await cartService.getCarts());
    } catch (e) {
      console.error(e);
      setLoadError(friendlyDbError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!userId || !isCustomer) {
      setCarts(NO_CARTS);
      setLoadError('');
      return;
    }
    refresh();
  }, [userId, isCustomer, refresh]);

  // Runs one cart change, then reloads all baskets. Returns { ok, error } so the caller can show a message next to the button.
  const run = useCallback(async (change) => {
    setBusy(true);
    try {
      await change();
      setCarts(await cartService.getCarts());
      return { ok: true };
    } catch (e) {
      console.error(e);
      return { ok: false, error: friendlyDbError(e) };
    } finally {
      setBusy(false);
    }
  }, []);

  const value = useMemo(
    () => ({
      carts,
      count: carts.reduce((n, c) => n + c.summary.item_count, 0),
      cartFor: (restaurantId) => carts.find((c) => c.restaurant.id === Number(restaurantId)) ?? null,
      loading,
      busy,
      loadError,
      refresh,
      addItem: (foodId, qty = 1) => run(() => cartService.addToCart(foodId, qty)),
      setQuantity: (itemId, qty) => run(() => cartService.setItemQuantity(itemId, qty)),
      removeItem: (itemId) => run(() => cartService.removeItem(itemId)),
    }),
    [carts, loading, busy, loadError, refresh, run],
  );

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}

export function useCart() {
  const ctx = useContext(CartContext);
  if (!ctx) throw new Error('useCart must be used inside <CartProvider>');
  return ctx;
}
