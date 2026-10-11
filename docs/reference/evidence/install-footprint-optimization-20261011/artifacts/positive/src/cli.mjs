#!/usr/bin/env node
import fs from 'node:fs';
import { importExpenses } from './importer.mjs';

const usage = 'usage: node src/cli.mjs <input.csv>';

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length !== 1) fail(usage);

const file = args[0];
let text;
try {
  text = fs.readFileSync(file, 'utf8');
} catch (err) {
  fail(`error: cannot read ${file}: ${err.code ?? err.message}`);
}

let result;
try {
  result = importExpenses(text);
} catch (err) {
  fail(`error: ${err.message}`);
}

process.stdout.write(`${JSON.stringify(result)}\n`);
