// Money is added up as whole minor units (kobo), because decimal fractions are inexact in
// JavaScript: 0.1 + 0.2 is 0.30000000000000004, but 10 + 20 is exactly 30.
// Amounts in and out are strings with 2 decimals ("3500.00"), the same form MySQL DECIMAL gives us.

// "3500.00" -> 350000    "19.99" -> 1999    "5" -> 500
function toMinor(amount) {
  const [whole, fraction = ''] = String(amount).split('.');
  return Number(whole) * 100 + Number((fraction + '00').slice(0, 2));
}

// 350000 -> "3500.00"    1999 -> "19.99"    5 -> "0.05"
function fromMinor(minor) {
  const whole = Math.trunc(minor / 100);
  const fraction = String(minor % 100).padStart(2, '0');
  return `${whole}.${fraction}`;
}

module.exports = { toMinor, fromMinor };
