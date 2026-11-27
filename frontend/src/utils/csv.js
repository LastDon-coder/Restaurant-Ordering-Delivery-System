// Build and download a CSV file in the browser. The rows come from the reports the server already allowed this person to see.
// A cell that starts with = + - @ could run as a formula when opened in Excel, and restaurant names are typed by users,
// so such cells get a leading apostrophe (a standard CSV-injection guard). Numbers are written as plain numbers.
function cell(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number') return String(v);
  let s = String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// columns: [[key, header], ...]
export function toCsv(rows, columns) {
  const head = columns.map(([, h]) => cell(h)).join(',');
  const body = rows.map((r) => columns.map(([k]) => cell(typeof r[k] === 'string' && r[k] !== '' && !Number.isNaN(Number(r[k])) ? Number(r[k]) : r[k])).join(','));
  return [head, ...body].join('\r\n');
}

export function downloadCsv(filename, csv) {
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }); // BOM so Excel reads UTF-8 names correctly
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
