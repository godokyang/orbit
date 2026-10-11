#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { importExpenses } from './importer.mjs';

const args = process.argv.slice(2);

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

if (args.length !== 1) {
  fail('usage: node src/cli.mjs <input.csv>');
}

let text;
try {
  text = readFileSync(args[0], 'utf8');
} catch (err) {
  fail(`error: cannot read ${args[0]}: ${err.message}`);
}

let result;
try {
  result = importExpenses(text);
} catch (err) {
  fail(`error: ${err.message}`);
}

process.stdout.write(`${JSON.stringify(result)}\n`);
