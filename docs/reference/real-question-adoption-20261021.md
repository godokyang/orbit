# 真实任务提问→答复→采用验证（2026-10-21）

对象：`/tmp/orbit-question-validation`，headless Orbit 真实模型任务。

## 流程

1. Root 用 `orbit_ask` 提问 “Which word should answer.txt contain?”，选项 alpha/beta；
2. CLI `questions` 读到 pending 问题 `question-mvgzrk17...`（source=root）；
3. CLI `answer --selected beta` 写入答复；
4. Root 采用答复，写入 `answer.txt`；
5. declare → check → finalization → complete。

## 证据

- `answer.txt` 内容为 `beta`；
- 任务终态 `complete`；
- 问题状态 `answered`，answer `{"selected":["beta"]}`；
- 事件链：task/created, question/asked, question/answered, work-unit/declared, check/requested, finalization/notice, check/completed, completion/requested, stop/confirmed, task/completed。
