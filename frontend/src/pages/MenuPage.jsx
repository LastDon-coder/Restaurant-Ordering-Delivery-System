import { useMemo, useState } from 'react';
import FoodCard from '../components/FoodCard';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useMenu } from '../hooks/useMenu';

export default function MenuPage() {
  const { categories, foods, loading, error, reload } = useMenu();
  const [categoryId, setCategoryId] = useState(null); // null = all

  const visible = useMemo(
    () => (categoryId ? foods.filter((f) => f.category_id === categoryId) : foods),
    [foods, categoryId],
  );

  if (loading) return <Loading label="Loading the menu…" />;
  if (error) return <ErrorMessage message={error} onRetry={reload} />;
  if (foods.length === 0) {
    return <EmptyState title="The menu is empty">Nothing is available right now. Please check back soon.</EmptyState>;
  }

  return (
    <section>
      <h1>Our menu</h1>
      <div className="chips" role="group" aria-label="Filter by category">
        <button type="button" className={`chip ${categoryId === null ? 'chip-active' : ''}`} onClick={() => setCategoryId(null)}>
          All
        </button>
        {categories.map((c) => (
          <button
            key={c.id}
            type="button"
            className={`chip ${categoryId === c.id ? 'chip-active' : ''}`}
            onClick={() => setCategoryId(c.id)}
          >
            {c.category_name}
          </button>
        ))}
      </div>
      {visible.length === 0 ? (
        <EmptyState title="Nothing in this category">Try another category.</EmptyState>
      ) : (
        <div className="grid">
          {visible.map((f) => (
            <FoodCard key={f.id} food={f} />
          ))}
        </div>
      )}
    </section>
  );
}
