const naira = new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' });

// Display only. The server always recalculates the real price.
export const formatMoney = (amount) => naira.format(Number(amount));
