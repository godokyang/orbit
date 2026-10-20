# DSH 宿主边界

Orbit 0.2 起以 DSH bundle 形式运行：

- 宿主插件：`@zeen/orbit/host`，由 `cordis.patch.yml` 插入；
- 入口工具：`orbit`（Root/成员）与 `orbit_ask`（成员/headless Root）；
- 检查者：`@deepseek-ai/dsh-subagent-dsh-sdk` 子进程，独立 `DSH_HOME` 与只读 sandbox；
- 控制面：项目内 `.orbit/orbit.sock`，CLI 只读公开合同；
- 旧 OMP 执行路径、Ruby 代码与 `host-omp.md` 已删除。

安装使用 `orbit install`，健康检查使用 `orbit doctor --t0`。
