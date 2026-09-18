# Jev 调度运行验收（2026-09-18）

## 已验证

- 登录 shell 中已配置的 `TYPESAFE_API_KEY` 可直接调用 TypeSafe System One；两次真实请求均返回三个 Noul 判断，响应模型为 `jev-1.13.0`。未在记录中保存 key。
- 使用临时项目、内存宿主连接和真实 `TaskRuntime`、`JevAdvisor`、Codex 独立检查者完成一次运行。仅凭 key 启用后，运行记录出现 `jev_assessed`；一次模拟执行停滞得到 `stuck=0.88`，随后启动 `process_reviewer`。独立检查返回 `correct` 且未过期，任务保持 `running`，没有把 Jev 概率当作完成裁决。显式停止后任务变为 `paused`。
- 现有完整 `npm test` 回归通过；新增隔离回归覆盖首次变化延后但定时检查保留、过程检查不能完成任务、请求期间停止优先、服务异常回退、全局 key 与项目关闭、近期观察及成员结果有界。宿主桥接测试清除继承的 key，避免回归测试访问真实 TypeSafe。

## 验收边界

临时项目的宿主连接为夹具；上述运行证明真实 Jev、真实运行循环和真实独立 Codex 检查的组合，不能替代普通 Codex、OpenCode、OMP 各宿主的长期现场观察。源码尚未发布或安装到全局 Orbit。现有运行中进程不会自动加载新代码或启动后才设置的环境变量。
