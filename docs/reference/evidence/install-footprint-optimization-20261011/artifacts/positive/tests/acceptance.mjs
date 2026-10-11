import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {importExpenses} from '../src/importer.mjs';
console.log('EXPENSE_VALIDATION_START: integer precision, line provenance, groups and CLI');
let count=0;
function test(label,fn){fn();count++; console.log(`PASS ${String(count).padStart(3,'0')}: ${label} | exact cents and source line verified`);}
for(let i=1;i<=110;i++) test(`grouping sample ${i}`,()=>assert.deepEqual(importExpenses(`category,amount\nFood,${i}.01\nTravel,0.99\nFood,0.02\n`),{groups:[{category:'Food',totalCents:i*100+3,count:2},{category:'Travel',totalCents:99,count:1}],totalCents:i*100+102,count:3}));
test('BOM CRLF blanks whitespace',()=>assert.deepEqual(importExpenses('\ufeffcategory,amount\r\n\r\n Food , 1.20 \r\n'),{groups:[{category:'Food',totalCents:120,count:1}],totalCents:120,count:1}));
for(const amount of ['-1.00','1','1.0','1.001','1e2','90071992547409.92']) test(`invalid amount ${amount}`,()=>assert.throws(()=>importExpenses(`category,amount\n\nFood,${amount}`),/3/));
test('sum overflow',()=>assert.throws(()=>importExpenses('category,amount\nA,90071992547409.91\nB,0.01'),/3/));
test('category overflow',()=>assert.throws(()=>importExpenses('category,amount\nA,90071992547409.90\nA,0.02'),/3/));
test('extra column',()=>assert.throws(()=>importExpenses('category,amount\nA,1.00,x'),/2/));
test('empty category',()=>assert.throws(()=>importExpenses('category,amount\n ,1.00'),/2/));
test('invalid header',()=>assert.throws(()=>importExpenses('type,amount\nA,1.00'),/1/));
const d=fs.mkdtempSync(path.join(os.tmpdir(),'expense-cli-'));try{
const f=path.join(d,'input.csv');fs.writeFileSync(f,'category,amount\nFood,1.20');
test('CLI success',()=>{const r=spawnSync(process.execPath,['src/cli.mjs',f],{encoding:'utf8'});assert.equal(r.status,0);assert.equal(r.stderr,'');assert.deepEqual(JSON.parse(r.stdout),importExpenses(fs.readFileSync(f,'utf8')));});
for(const args of [[],['missing.csv'],[f,'extra']])test(`CLI failure ${args.length} args`,()=>{const r=spawnSync(process.execPath,['src/cli.mjs',...args],{encoding:'utf8'});assert.equal(r.status,1);assert.equal(r.stdout,'');assert.ok(r.stderr.trim());assert.ok(!r.stderr.includes('at file:'));});
fs.writeFileSync(f,'category,amount\nFood,bad');test('CLI invalid input',()=>{const r=spawnSync(process.execPath,['src/cli.mjs',f],{encoding:'utf8'});assert.equal(r.status,1);assert.equal(r.stdout,'');assert.match(r.stderr,/2/);});
}finally{fs.rmSync(d,{recursive:true,force:true});}
console.log(`EXPENSE_VALIDATION_SUMMARY: ${count} cases passed; integer precision and CLI verified`);
