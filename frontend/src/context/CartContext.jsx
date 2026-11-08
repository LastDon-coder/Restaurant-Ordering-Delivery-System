import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import * as cartService from '../services/cartService';
import { friendlyDbError } from '../utils/errors';
import { useAuth } from './AuthContext';

const CartContext = createContext(null);
const EMPTY = { items: [], summary: { subtotal: '0.00', delivery_fee: '0.00', discount: '0.00', total: '0.00', item_count: 0 } };

export function CartProvider({ children }) {
  const { user, role } = useAuth();
  const isCustomer = role === 'customer';
  const userId = user?.id;

  const [cart, setCart] = useState(EMPTY);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState('');

  const refresh = useCallback(async () => {
    setLoading(true);
    setLoadError('');
    try {
      setCart(await cartService.getCart());
    } catch (e) {
      console.error(e);
      setLoadError(friendlyDbError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  // Load the cart for signed-in customers; clear it on sign-out or for other roles.
  useEffect(() => {
    if (!userId || !isCustomer) {
      setCart(EMPTY);
      setLoadError('');
      return;
    }
    refresh();
  }, [userId, isCustomer, refresh]);

  // Runs one cart change. Returns { ok, error } so the caller can show a message next to the button.
  const run = useCallback(async (change) => {
    setBusy(true);
    try {
      const updated = await change();
      setCart(updated ?? (await cartService.getCart()));
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
      cart,
      count: cart.summary.item_count,
      loading,
      busy,
      loadError,
      refresh,
      addItem: (foodId, qty = 1) => run(() => cartService.addToCart(foodId, qty)),
      setQuantity: (itemId, qty) => run(() => cartService.setItemQuantity(itemId, qty)),
      removeItem: (itemId) => run(() => cartService.removeItem(itemId)),
    }),
    [cart, loading, busy, loadError, refresh, run],
  );

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}

export function useCart() {
  const ctx = useContext(CartContext);
  if (!ctx) throw new Error('useCart must be used inside <CartProvider>');
  return ctx;
}
