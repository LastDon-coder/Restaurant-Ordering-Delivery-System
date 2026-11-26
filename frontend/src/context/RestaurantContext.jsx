import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { listMyRestaurants } from '../services/restaurantTeamService';
import { useAuth } from './AuthContext';

const Ctx = createContext(null);
const KEY = 'currentRestaurantId';
const read = () => { try { return Number(localStorage.getItem(KEY)) || null; } catch { return null; } };
const write = (id) => { try { localStorage.setItem(KEY, String(id)); } catch { /* private window: fine */ } };

// The restaurants the signed-in person works for, and which one the dashboard is showing.
// (Display state only: every action is checked by the database against the restaurant id it receives.)
export function RestaurantProvider({ children }) {
  const { user, role } = useAuth();
  const works = role === 'staff';
  const userId = user?.id;
  const [restaurants, setRestaurants] = useState([]);
  const [currentId, setCurrentId] = useState(read);
  const [state, setState] = useState('idle'); // idle | loading | ready | error

  const reload = useCallback(async () => {
    setState('loading');
    try {
      setRestaurants(await listMyRestaurants());
      setState('ready');
    } catch (e) {
      console.error(e);
      setState('error');
    }
  }, []);

  useEffect(() => {
    if (!userId || !works) { setRestaurants([]); setState('idle'); return; }
    reload();
  }, [userId, works, reload]);

  const current = restaurants.find((r) => r.id === currentId) ?? restaurants[0] ?? null;
  const value = useMemo(
    () => ({ restaurants, current, state, reload, select: (id) => { setCurrentId(id); write(id); } }),
    [restaurants, current, state, reload],
  );
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useRestaurant() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useRestaurant must be used inside <RestaurantProvider>');
  return ctx;
}
