import { useCallback, useEffect, useState } from 'react';
import { fetchMenu } from '../services/menuService';

// Returns { categories, foods, loading, error, reload } so pages can show loading / error / empty states.
export function useMenu() {
  const [state, setState] = useState({ categories: [], foods: [], loading: true, error: null });

  const load = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: null }));
    try {
      const data = await fetchMenu();
      setState({ ...data, loading: false, error: null });
    } catch (e) {
      console.error(e);
      setState({ categories: [], foods: [], loading: false, error: 'Could not load the menu. Please try again.' });
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return { ...state, reload: load };
}
