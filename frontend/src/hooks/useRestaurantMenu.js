import { useCallback, useEffect, useState } from 'react';
import { fetchRestaurantMenu, getRestaurant } from '../services/restaurantService';

// { restaurant, categories, foods, loading, error, notFound, reload } for /r/:slug
export function useRestaurantMenu(slug) {
  const [state, setState] = useState({ restaurant: null, categories: [], foods: [], loading: true, error: null, notFound: false });

  const load = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: null, notFound: false }));
    try {
      const restaurant = await getRestaurant(slug);
      const menu = await fetchRestaurantMenu(restaurant.id);
      setState({ restaurant, ...menu, loading: false, error: null, notFound: false });
    } catch (e) {
      if (e?.code === 'P0002') {
        setState({ restaurant: null, categories: [], foods: [], loading: false, error: null, notFound: true });
        return;
      }
      console.error(e);
      setState({ restaurant: null, categories: [], foods: [], loading: false, error: 'Could not load this restaurant. Please try again.', notFound: false });
    }
  }, [slug]);

  useEffect(() => { load(); }, [load]);
  return { ...state, reload: load };
}
