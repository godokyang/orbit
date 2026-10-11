# Expense Importer

CSV expense importer: pure `importExpenses(text)` in `src/importer.mjs` and a CLI in `src/cli.mjs`. No dependencies.

## CLI

```sh
node src/cli.mjs <input.csv>
```

Reads the file as UTF-8. On success prints only the result JSON to stdout and exits 0:

```json
{"groups":[{"category":"Food","totalCents":123,"count":2}],"totalCents":123,"count":2}
```

On any failure — wrong number of arguments, unreadable file, or invalid CSV — prints a concise one-line error to stderr (no stack trace), leaves stdout empty, and exits 1.

## Input format

- First line must be the exact header `category,amount`.
- Each data line: `category,amount`, unquoted, exactly two columns, both trimmed.
- Category must be nonempty.
- Amount: nonnegative decimal with exactly two fractional digits (`0.99`, `12.34`); no sign, exponent, or extra decimals.
- A leading BOM is stripped; LF and CRLF line endings are accepted; blank lines are ignored.

## Output and precision

- Amounts are computed as **integer cents** exactly (no floating-point error).
- Categories appear in first-seen order; each group carries `{category,totalCents,count}` plus an overall `totalCents` and `count`.
- Any single amount, per-category sum, or overall sum that exceeds `Number.MAX_SAFE_INTEGER` (9007199254740991 cents) is rejected.

## Errors

Invalid data throws/prints an error containing the offending **one-based line number**, counted including blank lines. The header line is line 1; a bad header reports line 1.

## Tests

```sh
npm test
```

Runs `tests/acceptance.mjs` (pure-function cases plus CLI success/failure behavior).
