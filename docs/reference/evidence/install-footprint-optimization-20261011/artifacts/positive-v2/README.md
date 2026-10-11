# Expense importer

CSV 费用导入工具：把 `category,amount` 格式的 CSV 按类别汇总为精确的整数分。

## 用法

```sh
node src/cli.mjs <input.csv>
```

或通过 npm：

```sh
npm test   # 运行 tests/acceptance.mjs 验收
```

成功时仅向 stdout 打印一行 JSON（退出码 0）：

```json
{"groups":[{"category":"Food","totalCents":122,"count":2}],"totalCents":122,"count":2}
```

## 输入格式（SPEC.md 为准）

- 第一行必须是表头 `category,amount`（自动去除开头一个 UTF-8 BOM）。
- 接受 LF 或 CRLF 行尾；空行忽略，但计入 1-based 行号。
- 非引号 CSV；每个数据行必须恰好两列，两个字段均会 trim。
- 类别必须非空。
- 金额必须是非负十进制数、恰好两位小数（不允许正负号、指数、整数或一位/三位以上小数）。

## 精度与溢出

金额以整数分精确计算，不做浮点累加。单个金额、单类别合计或总合计任一超过 `Number.MAX_SAFE_INTEGER` 时报错。

## 顺序

`groups` 按类别首次出现的顺序排列。

## 错误行为

以下情况向 stderr 输出一行简明错误、stdout 为空、退出码 1，且不打印堆栈：

- 参数个数不为 1（缺少或多于一个路径参数）；
- 文件无法读取；
- 数据无效（错误消息含原始 1-based 行号，空行也计入编号）。

## API

`src/importer.mjs` 导出纯函数 `importExpenses(text)`：输入 CSV 文本，返回 `{groups:[{category,totalCents,count}],totalCents,count}`；数据无效时 `throw Error`（消息含 1-based 行号）。
