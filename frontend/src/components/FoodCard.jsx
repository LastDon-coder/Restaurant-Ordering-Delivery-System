import { formatMoney } from '../utils/format';

export default function FoodCard({ food }) {
  return (
    <article className="card">
      {food.image_url ? (
        <img className="card-img" src={food.image_url} alt={food.food_name} loading="lazy" />
      ) : (
        <div className="card-img card-img-placeholder" aria-hidden="true">
          🍽️
        </div>
      )}
      <div className="card-body">
        <h3>{food.food_name}</h3>
        {food.description && <p className="muted">{food.description}</p>}
        <p className="price">{formatMoney(food.price)}</p>
      </div>
    </article>
  );
}
