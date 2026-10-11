// Expense importer: pure text -> grouped totals in exact integer cents.
// Implements the contract in SPEC.md. No I/O, no globals, no dependencies.

const HEADER = 'category,amount';
const AMOUNT_RE = /^\d+\.\d{2}$/;
const MAX_SAFE_CENTS = BigInt(Number.MAX_SAFE_INTEGER);

export function importExpenses(text) {
  let body = String(text);
  // Strip one leading BOM (U+FEFF), if present.
  if (body.charCodeAt(0) === 0xfeff) body = body.slice(1);

  // Accept LF or CRLF: split on LF, then drop one trailing CR per line.
  const lines = body
    .split('\n')
    .map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line));

  // The header is the first line, exact match after BOM strip.
  if (lines[0] !== HEADER) {
    throw new Error('line 1: invalid header, expected "category,amount"');
  }

  const groups = new Map(); // category -> {category, totalCents, count}, first-seen order
  let totalCents = 0;
  let count = 0;

  for (let i = 1; i < lines.length; i++) {
    const lineNo = i + 1; // 1-based; blank lines still count
    const line = lines[i];
    if (line.trim() === '') continue; // blank line: ignored as data

    const cols = line.split(',');
    if (cols.length !== 2) {
      throw new Error(`line ${lineNo}: expected exactly two columns "category,amount"`);
    }
    const category = cols[0].trim();
    const amount = cols[1].trim();
    if (category === '') {
      throw new Error(`line ${lineNo}: category must be nonempty`);
    }
    if (!AMOUNT_RE.test(amount)) {
      throw new Error(
        `line ${lineNo}: invalid amount "${amount}", expected unsigned decimal with exactly two fractional digits`
      );
    }

    // Exact integer cents via string splitting; BigInt stays exact for any digit count.
    const dot = amount.indexOf('.');
    const centsBig = BigInt(amount.slice(0, dot)) * 100n + BigInt(amount.slice(dot + 1));
    if (centsBig > MAX_SAFE_CENTS) {
      throw new Error(`line ${lineNo}: amount exceeds Number.MAX_SAFE_INTEGER cents`);
    }
    const cents = Number(centsBig);

    let group = groups.get(category);
    if (group === undefined) {
      group = { category, totalCents: 0, count: 0 };
      groups.set(category, group);
    }

    // Both operands are integers <= MAX_SAFE_INTEGER, so the sum is exact and
    // the overflow check is reliable.
    const groupTotal = group.totalCents + cents;
    if (groupTotal > Number.MAX_SAFE_INTEGER) {
      throw new Error(`line ${lineNo}: category total exceeds Number.MAX_SAFE_INTEGER cents`);
    }
    const grandTotal = totalCents + cents;
    if (grandTotal > Number.MAX_SAFE_INTEGER) {
      throw new Error(`line ${lineNo}: overall total exceeds Number.MAX_SAFE_INTEGER cents`);
    }

    group.totalCents = groupTotal;
    group.count += 1;
    totalCents = grandTotal;
    count += 1;
  }

  return { groups: [...groups.values()], totalCents, count };
}
