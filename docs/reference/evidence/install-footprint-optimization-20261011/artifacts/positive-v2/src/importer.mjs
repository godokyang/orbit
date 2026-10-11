// Expense importer: parses "category,amount" CSV text per SPEC.md.
// Unquoted CSV, exact integer-cent arithmetic via BigInt, first-seen
// category order, 1-based line numbers (blank lines included) in errors.

const MAX_SAFE_CENTS = BigInt(Number.MAX_SAFE_INTEGER); // 9007199254740991n
const AMOUNT_RE = /^\d+\.\d{2}$/;

export function importExpenses(text) {
  if (typeof text !== 'string') {
    throw new Error('line 1: input must be a string');
  }

  // Strip one leading BOM.
  if (text.charCodeAt(0) === 0xfeff) {
    text = text.slice(1);
  }

  // Accept LF or CRLF.
  const lines = text.split(/\r\n|\n/);

  if (lines[0] !== 'category,amount') {
    throw new Error('line 1: invalid header, expected "category,amount"');
  }

  const groups = [];
  const byCategory = new Map();
  let totalCents = 0n;
  let count = 0;

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    const lineNo = i + 1;

    // Blank lines are ignored but still counted in line numbering.
    if (line.trim() === '') continue;

    const cols = line.split(',');
    if (cols.length !== 2) {
      throw new Error(`line ${lineNo}: expected exactly two columns, got ${cols.length}`);
    }

    const category = cols[0].trim();
    const amount = cols[1].trim();

    if (category === '') {
      throw new Error(`line ${lineNo}: category must be nonempty`);
    }

    if (!AMOUNT_RE.test(amount)) {
      throw new Error(`line ${lineNo}: invalid amount "${amount}" (need nonnegative decimal with exactly two fractional digits)`);
    }

    // Exact integer cents, no floating point.
    const dot = amount.indexOf('.');
    const cents = BigInt(amount.slice(0, dot)) * 100n + BigInt(amount.slice(dot + 1));

    if (cents > MAX_SAFE_CENTS) {
      throw new Error(`line ${lineNo}: amount exceeds Number.MAX_SAFE_INTEGER cents`);
    }

    let group = byCategory.get(category);
    if (group === undefined) {
      group = { category, totalCents: 0n, count: 0 };
      byCategory.set(category, group);
      groups.push(group);
    }

    const groupTotal = group.totalCents + cents;
    if (groupTotal > MAX_SAFE_CENTS) {
      throw new Error(`line ${lineNo}: category "${category}" total exceeds Number.MAX_SAFE_INTEGER cents`);
    }

    const newTotal = totalCents + cents;
    if (newTotal > MAX_SAFE_CENTS) {
      throw new Error(`line ${lineNo}: overall total exceeds Number.MAX_SAFE_INTEGER cents`);
    }

    group.totalCents = groupTotal;
    group.count += 1;
    totalCents = newTotal;
    count += 1;
  }

  return {
    groups: groups.map((g) => ({ category: g.category, totalCents: Number(g.totalCents), count: g.count })),
    totalCents: Number(totalCents),
    count,
  };
}
