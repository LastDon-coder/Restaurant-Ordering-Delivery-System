// A payment reference looks like ORD-12-9f86d081884c7d65: the order id is part of it, so even if a customer
// pays an older attempt, we still know which order the money is for. The server creates every reference.
const REFERENCE_RE = /^ORD-(\d{1,10})-[a-f0-9]{16}$/;

module.exports = { REFERENCE_RE };
