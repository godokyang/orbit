C08 只复核已修的 coverage 非空和去重，C06 只读当前首执行检查和已通过的测试。不再扩字符边界，也不写文件。
## C08

NBSP（U+00A0）和全角空格（U+3000）的 coverage 非空、去重，两侧现在走同一裁边。本回合只读了这三处，没有重跑校验器，也没有再扫其他字符。

- Ruby `trim_coverage_text`（`lib/orbit/check_runner.rb` 1227–1228）从两端去掉的字符包含 U+00A0 和 U+3000。requirement 非空（1265）、verified 的 evidence 非空（1273）、requirement 去重（1277）都用它。
- TS 仍是 `requirement.trim()`（`runners/omp-reviewer/check-result.ts` 211、214）和 `evidence.trim()`（219）。ECMAScript `trim` 同样把这两个字符当空白。
- 共享样例 `tests/fixtures/check-result-samples.json` 两条都是拒绝：verified 的 evidence 只有 U+00A0 U+3000；两条 requirement 只差首部 U+3000 和尾部 U+00A0。

就这两类空白的 coverage 非空和去重，当前没有剩余分歧。

## C06

`assertCommandReadable`（`plugins/work-unit-scope.mjs` 439–474）只看首个裸可执行文件的前两字节。读权限没有扩大：profile 仍是 `(allow process*)`，file-read-data 仍只覆盖允许路径和系统目录。

- **二进制**：文件头不是 `#!` 时，realpath 在数据读集外也放行。测试把当前 Node 复制到项目外，`node --version` 的 preflight 为 ok，成员门返回沙箱命令，并断言该沙箱执行 exit 0。
- **脚本**：文件头是 `#!` 且 realpath 不在读集时，preflight 和成员门都在执行前拒绝，原因包含脚本路径。项目外 `npm` → `npm-cli.js` 被拒绝，`src/npm-ran` 不存在。`.runtime` 在 `allowed_paths` 内时，`npm test` 的 preflight 为 ok；这是静态接受，测试没有执行项目内 npm 脚本。node/npm/npx 的恢复文字仍是复制到项目内 `.runtime`。
- **复杂 shell**：含重定向等元字符时，静态检查不给出可行性结论。`printf allowed > src/allowed.txt` 的 preflight 为 ok，这一段不执行命令。真正执行仍走成员门的 `sandbox-exec`；同一命令在后面的内核写范围断言里执行。解释器参数、包脚本和缓存仍未证明。

按这三条，当前 helper 与 `tests/work_unit_scope_test.mjs` 的断言一致。本回合没有重跑该测试，通过结论沿这些断言和已给出的全过结果。没有改代码，也没有新建临时文件。