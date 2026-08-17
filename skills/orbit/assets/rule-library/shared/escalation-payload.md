---
description: Use on every Orbit dispatch — the shared format for what to hand over when a rule escalates. Task rules keep the trigger; this file only owns the payload shape.
---

# 升格 payload

**所有权边界**：本文只拥有「停下时交什么」的统一格式。何时算真边界由本次 attempt 已钉的任务规则拥有，本文不裁定、不复写。

本文是判断依据，不是可以机械勾选的清单。

停下时按类型交 payload，不要混用一种格式：

| 升格类型 | 交什么 |
| --- | --- |
| 裁不了的缺口 | `待裁定：<问题> —— <2–3 个候选与各自代价>`，交付摘要单独列出 |
| 报一条缺陷 | 位置（文件:行）+ 能自己复现的证据 + 影响。三样缺一样是意见，不是缺陷 |
| 发现范围外问题 | 问题描述 + 影响范围 + 建议方案。本 attempt 不改 |

不要自己选一个答案写进代码或合同。不要用「按需返回」「视情况」绕开。裁定后删干净，不留「原本这里有一条，现已裁定」。禁止只在对话中拍板。
