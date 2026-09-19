# Graph 状态克隆与 ReAct 历史分配优化

最后验证日期：2026-09-19（Asia/Shanghai）。本文用于评审 Graph Core 的状态克隆优化，以及复现同机性能对比。

## 依据与范围

调研来源为 [benchmark 开发参考报告](https://github.com/agentic-spring-ai/agentic-spring-ai-benchmark/blob/8831f26d7812838eed78b5d0bca3093ef5dba049/reports/2026-09-03-development-reference.md) 和 [完整报告](https://github.com/agentic-spring-ai/agentic-spring-ai-benchmark/blob/8831f26d7812838eed78b5d0bca3093ef5dba049/reports/2026-09-03-full.md)，访问日期为 2026-09-19。筛选场景为状态宽度、ReAct 历史长度、共享 Agent 吞吐和 Graph 调度控制组。

历史报告把宽状态复制、历史消息复制和序列化列为优先热点。报告使用的核心提交为 `c128f025`，与当前代码不同，因此本文重新测量当前基线，不直接用历史耗时计算收益。

本次比较的基线为 `976fcdf68550222f6be5418cf77c83bd47811fd3`，已经包含空 GraphResponse metadata 的优化。下表的改善来自新增的状态克隆修改，不重复计入此前的 metadata 收益。

## 实现

- 在 `TypeMapper` 实例内复用关闭默认类型推断后的 Jackson mapper，覆盖显式类型恢复、类型化 List 和数组回退路径。避免每条历史消息重复复制 mapper 及其缓存；首次初始化同步发布，热路径读取不加锁。
- 缓存核对源 mapper、序列化配置、反序列化配置及相关工厂，配置或模块发生变化时重新创建副本。没有增加全局 mapper 注册表；没有默认类型推断的 mapper 直接复用。
- `JacksonStateSerializer.cloneObject` 直接进行 JSON 字节往返，省去 Java 对象流、长度前缀及多次 UTF-8 转换。状态规范化、类型恢复、自定义 state factory 和深拷贝隔离仍然执行。

复用现有 Jackson API 和 JDK 同步机制，没有新增运行时依赖。`writeData`、`readData` 的持久化格式及公开方法签名保持不变。应用仍应在并发读写开始前完成 mapper 配置；本次不增加并发修改 mapper 配置的支持。

## 测量环境与方法

| 项目 | 固定值 |
| --- | --- |
| 设备 | `Mac16,10`，10 核，24 GiB 内存，AC Power |
| 系统 | macOS 26.5.2（25F84），arm64 |
| JDK | Temurin 17.0.19+10 |
| Maven / JMH | 3.9.16 / 1.37 |
| benchmark 提交 | `8831f26d7812838eed78b5d0bca3093ef5dba049` |
| JVM 堆 | `-Xms512m -Xmx512m` |
| 正式采样 | 5 × 1 秒预热，8 × 1 秒测量，3 forks |
| 指标 | 平均耗时、吞吐、`gc.alloc.rate.norm`（B/op） |

使用原 benchmark 场景和本地确定性模型，不包含网络或真实 LLM 推理。前后测量串行执行，测试及构建不与正式测量并行。误差为 JMH 输出的 99.9% 置信区间半宽，KB/MB 使用十进制。

## 正式结果

| 场景 | 基线 μs/op | 优化后 μs/op | 耗时降低 | 基线 B/op | 优化后 B/op | 分配降低 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 20 节点、50 个附加状态键 | 173.864 ± 1.568 | 156.229 ± 4.106 | 10.1% | 816,615 | 627,703 | 23.1% |
| ReAct、0 轮历史 | 61.130 ± 1.646 | 36.397 ± 0.396 | 40.5% | 383,720 | 149,467 | 61.0% |
| ReAct、25 轮历史 | 1,436.836 ± 7.499 | 774.298 ± 8.086 | 46.1% | 10,041,820 | 2,698,757 | 73.1% |

20 节点、1 个附加状态键的分配量从 270,512 降为 156,339 B/op，减少 42.2%。该组基线耗时为 `37.905 ± 11.110 μs/op`，与优化后 `26.019 ± 0.351 μs/op` 的区间重叠，因此不据此宣称确定的延迟改善。

共享 ReactAgent 的 8 线程吞吐从 `59,103 ± 4,403 ops/s` 提高到 `88,150 ± 4,390 ops/s`，提升 49.1%；分配量从 382,483 降为 149,666 B/op。两组均采用上表的正式采样配置。

另外执行了 10 节点顺序图、100 次条件循环、8 分支并行和 MemorySaver 四个控制场景，均正常完成。控制组采用 2 × 500 毫秒预热、3 × 500 毫秒测量和 1 fork，仅用于趋势检查，不据此给出精确延迟收益。四组 B/op 分别从 143,615、1,200,078、131,567、59,266 降为 81,560、675,504、111,570、33,494。

JFR 定位运行在长历史场景中观察到 Jackson 符号表、类型解析和 `ObjectMapper.copy()` 相关分配。JFR 采样只用于定位，未混入上表的正式 GC profiler 结果。25 轮历史优化后仍分配约 2.70 MB/次；本次结果不等价于线上 GC 暂停时长或服务级 p95/p99 的改善。

原始 JMH 指标与逐轮样本已归档到 [基线 JSON](data/2026-09-19-state-cloning-baseline.json) 和 [优化后 JSON](data/2026-09-19-state-cloning-optimized.json)，各包含 9 组结果，仅移除了 JVM 可执行文件的本机绝对路径。完整日志和定位用 JFR 保存在本地 `target/benchmark-review/`，该目录不纳入版本控制。

## 复现

在基线与优化版本分别执行以下构建，再将生成的两个 `benchmarks.jar` 分别保存为独立目录中的 `graph.jar`、`react.jar`。benchmark 仓库放置于当前工作区的 `target/benchmark-review/repository`，并固定到上表提交。

```shell
mise exec java@temurin-17.0.19+10 -- ./mvnw -B \
  -pl :agentic-spring-ai-agent-framework -am install -DskipTests
mise exec java@temurin-17.0.19+10 -- ./mvnw -B \
  -f target/benchmark-review/repository/pom.xml verify

mise exec java@temurin-17.0.19+10 -- bash tools/benchmarks/run-state-cloning.sh \
  target/benchmark-review/baseline target/benchmark-review/baseline-results
mise exec java@temurin-17.0.19+10 -- bash tools/benchmarks/run-state-cloning.sh \
  target/benchmark-review/optimized target/benchmark-review/optimized-results
```

运行脚本会保留 JMH JSON、各轮原始样本和日志。`checks` 模式只运行并发吞吐及短控制组，便于在正式状态宽度和历史测量之后补充验证。默认 `full` 模式完整执行本次选定的矩阵，不代表 benchmark 仓库的全部参数组合。

## 兼容性与验证

Graph Core 全模块回归 428 项：0 失败、0 错误、59 项跳过。Agent Framework 回归 688 项：0 失败、0 错误、162 项跳过。跳过项包括缺少 Docker 的持久化测试，以及外部模型条件测试。Agent 测试进程移除 `AI_DASHSCOPE_API_KEY`、`AI_DEEPSEEK_API_KEY`、`OPENAI_API_KEY`，避免启用网络模型测试。最初未移除凭据的 Agent 运行遇到外部模型 404 后已停止，不作为通过证据。

最后补充的数组回退测试及大文本调整通过定向回归，两个新增测试类合计 10/10。覆盖长历史消息、类型化集合、不同 serializer 的配置隔离、配置更新、并发首次使用、数组回退、嵌套可变值、大文本、数字及特殊响应值的克隆。benchmark 原有冒烟测试 5/5 通过。编译、Checkstyle、`git diff --check` 及脚本语法检查通过。

JaCoCo 对本轮生产代码新增可执行行的覆盖为 26/26（100%）。模块整体覆盖率未达到 90%，不能把增量覆盖率视为整体覆盖率。未执行真实模型/远程存储端到端测试、长时间压力、容量极限、混沌测试和依赖 CVE 扫描。

无迁移，直接替换。已持久化的 checkpoint 无需重写。回滚本轮状态克隆提交即可恢复旧克隆路径，前一项 GraphResponse metadata 优化可独立保留。
