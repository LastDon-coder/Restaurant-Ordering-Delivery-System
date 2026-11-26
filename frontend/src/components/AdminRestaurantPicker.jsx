import { useEffect, useState } from 'react';
import { adminListRestaurants } from '../services/restaurantAdminService';
import { EmptyState, ErrorMessage, Loading } from './StateMessage';

// The platform admin works on one live restaurant at a time: pick it, then render the page for that id.
export default function AdminRestaurantPicker({ children }) {
  const [list, setList] = useState([]);
  const [id, setId] = useState(null);
  const [state, setState] = useState('loading');

  async function load() {
    setState('loading');
    try {
      const rows = [...(await adminListRestaurants('active'))].sort((a, b) => a.id - b.id); // oldest first: Restaurant #1 is the default
      setList(rows);
      setId((cur) => (rows.some((r) => r.id === cur) ? cur : rows[0]?.id ?? null));
      setState('ready');
    } catch (e) {
      console.error(e);
      setState('error');
    }
  }
  useEffect(() => { load(); }, []);

  if (state === 'loading') return <Loading label="Loading restaurants…" />;
  if (state === 'error') return <ErrorMessage message="Could not load restaurants." onRetry={load} />;
  if (list.length === 0) return <EmptyState title="No live restaurants yet">Approve an application first.</EmptyState>;
  return (
    <>
      <label className="small">
        Restaurant{' '}
        <select value={id ?? ''} onChange={(e) => setId(Number(e.target.value))} aria-label="Restaurant">
          {list.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
        </select>
      </label>
      {children(id)}
    </>
  );
}
