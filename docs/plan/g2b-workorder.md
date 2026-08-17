# G.2b 工单：评审侧垂直切片与共享正文的耦合验证

- 日期：2026-08-17
- 基线 HEAD：`27a9f72`
- 执行：grok（wA:pG）
- 性质：**派发文件，不拥有裁决。** 裁决在 [`vision-completion-plan.md`](./vision-completion-plan.md) D1–D10；切分在 [`g1-rule-library-design.md`](./g1-rule-library-design.md)。冲突以它们为准。

## 为什么不是「把剩下 7 份写完」

G.2a 证明了实现侧的投递链路。评审侧还有一个没被证明的东西：**reviewer inherit**。设计稿 Q4 说 reviewer 拿 subject attempt 的 `required_rules` 加 `review.md`，而 `control_store.rb:2267-2268` 在新分派时会用 `verify_files: true` 把钉入的 digest 与**当前文件字节**重新比对，不符就报 "new assigned rules do not match current project rule bytes"。

这两条放在一起有一个推论：规则文件被编辑之后，所有已分派但尚未进入评审的 subject，其 reviewer dispatch 会失败。历史 attempt 是安全的（G.2a 已验证 `validate!` 走 `verify_files: false`），但在飞的实现/评审配对不是。

这个推论**没有被实跑验证过**，是从两处代码推出来的。它决定一件具体的事：设计稿 L102 要求升格 payload 表逐字复制进全部 8 份文件。如果推论成立，那 9 行的任何一次修改会同时改掉 8 份文件的字节，让所有在飞配对一起失败——细切要避免的耦合就从这里被装回去了。

所以先验证，再决定那 9 行怎么放。不要先写 6 份文件再回头改。

## 顺序（不要打乱）

### 第一步：写 `review.md`

按 D8 与 G.2a 已落地的 `minimal-implementation.md` 的粒度写。源素材见设计稿 Q2 里去向为 `review` 的各节（含从删除列挪回的 finding 四要素 9 行）。母版落 `skills/orbit/assets/rule-library/tasks/review.md`。

升格 payload 表这一轮**照设计稿原样写进正文**。第三步的结论出来之前不要改放法。

### 第二步：接 reviewer inherit

reviewer 分派时的 `required_rules` = subject attempt 已记录的 `required_rules` + `rules/review.md`（`relation: supplements`）。`RELATION_PRECEDENCE`（`rule_resolution.rb:14-18`）支持这个形状。

继承的是 subject **已记录的** digest，不是按当前文件重新解析——这是设计稿「同一份字节」的原意。如果实现上做不到，停下报我，不要改成重新解析后当作 inherit。

### 第三步：验证耦合推论（本工单的重点）

一个测试，走这条路：dispatch implementer → 改规则文件一个字节 → dispatch reviewer。

如实报告发生了什么：
- 如果 reviewer dispatch 失败，把完整错误码与消息抄回来。
- 如果成功，说明推论不成立，把 `verify_files: true` 那条分支为什么没拦住讲清楚（是 `if policy` 没进，还是继承路径绕开了 canonical_identity）。

**两种结果都是有效结论，不要为了让测试通过而调整场景。** 这一步的产出是事实，不是绿灯。

## 不做

其余 6 份规则正文、`orbit v2 rules update`、退役三个角色文件、参考层文件、按 `description` 做机器选择。都在 G.2c。

## 约束

- 不放宽 `canonicalize_path!` 或任何既有产品校验。
- 不改本仓库根 `AGENTS.md`。
- 测试预算：≤2 个方法、≤150 行。
- CPU 纪律：单方法迭代用 `ORBIT_V2_ONLY`；focused 全量最多 2 次，收口时才跑。
- 否定断言用 `include?` 不用 `start_with?`（G.2a 的教训：错误排在 note 之后时 `start_with?` 会假通过）。

## 停止条件

- 第二步的 inherit 做不到「继承已记录 digest」。
- 第三步的结论意味着设计稿 L102 的复制方案要改——那是裁决，报我，不要自己改设计稿。
- 发现 G.1 切分或 D1–D10 有误。
