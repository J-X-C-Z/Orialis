#!/usr/bin/env python3
"""Rebuild the final profiling report from preserved raw/pooled measurements.

This only reads benchmark results and writes a report and combined summary. It
does not run a benchmark, modify runtime code, or infer production equivalence.
"""
import argparse
import collections
import datetime
import json
import math
import statistics
from pathlib import Path


def read(path):
    return json.loads(path.read_text())


def quantile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def row_for(rows, **criteria):
    return next(row for row in rows if all(row[key] == value for key, value in criteria.items()))


def main(args):
    components = read(args.components / "summary.json")
    raw_components = read(args.components / "all-results.json")
    integrated = read(args.integrated / "summary.json")
    cache = read(args.cache / "summary.json")
    prior = read(args.prior_components / "summary.json")
    assert components["measured_requests"] == 1920 and components["request_errors"] == 0
    assert components["runs"] == 12 and components["setup_failures"] == []
    assert sum(row["requests"] for row in integrated["summary"]) == 720
    assert sum(row["failures"] for row in integrated["summary"]) == 0
    assert cache["operations"] == 2520 and cache["canonical_inputs_and_outputs_equal"]
    agent_hashes = {run["binary_sha256"] for run in raw_components if run["variant"] == "rust"}
    server_hashes = {run["server_sha256"] for run in raw_components}
    assert agent_hashes == {integrated["binary_sha256"]}
    assert server_hashes == {integrated["server_binary_sha256"]}

    purposes = collections.defaultdict(collections.Counter)
    per_run = []
    provider_rows = []
    for run in raw_components:
        counts = collections.Counter()
        for workload in run["workloads"].values():
            counts.update(workload["model_call_purposes"])
        purposes[run["variant"]].update(counts)
        per_run.append({"variant": run["variant"], "trial": run["trial"],
                        "model_delay_ms": run["model_delay_ms"], "purposes": dict(counts)})
    for row in components["workloads"]:
        workloads = [run["workloads"][row["workload"]] for run in raw_components
                     if run["variant"] == row["variant"] and run["model_delay_ms"] == row["model_delay_ms"]]
        actual = [value for workload in workloads for value in workload["provider_actual_service_raw_ms"]]
        provider_rows.append({"variant": row["variant"], "model_delay_ms": row["model_delay_ms"],
                              "workload": row["workload"], "provider_actual_p50_ms": quantile(actual, .5),
                              "provider_actual_p95_ms": quantile(actual, .95),
                              "all_model_body_bytes_per_user_request": row["model_payload_bytes"] / row["successes"],
                              "model_calls": row["model_calls"]})
    provider_metrics = {"purposes": dict(purposes), "per_run": per_run, "pooled_workloads": provider_rows}
    if not args.report_only:
        (args.components / "provider-metrics.json").write_text(json.dumps(provider_metrics, indent=2) + "\n")

    prior_vision = row_for(prior["workloads"], variant="rust", model_delay_ms=100, workload="memory_jpeg_c4")
    final_vision = row_for(components["workloads"], variant="rust", model_delay_ms=100, workload="memory_jpeg_c4")
    python_vision = row_for(components["workloads"], variant="python", model_delay_ms=100, workload="memory_jpeg_c4")
    base_short = row_for(integrated["summary"], profile="base", workload="fresh_text_sequential")
    full_short = row_for(integrated["summary"], profile="full", workload="fresh_text_sequential")
    history = row_for(integrated["summary"], profile="full", workload="history_8_pdf")
    improvements = []
    for file in ["pdf-2pages.pdf", "docx-1500paragraphs.docx", "xlsx-2000rows.xlsx"]:
        off = row_for(cache["summary"], variant="cache_off", file=file, operation="hydrate", history=8)
        on = row_for(cache["summary"], variant="cache_on", file=file, operation="hydrate", history=8)
        improvements.append({"file": file, "history": 8, "off": off, "on": on,
                             "p50_reduction_percent": 100 * (1 - on["p50_ms"] / off["p50_ms"])})

    integrated_startup = {}
    integrated_observations = []
    integrated_tail_diagnostics = []
    history_reaped_cpu = []
    for profile in ["base", "full"]:
        runs = [run for run in integrated["runs"] if run["profile"] == profile]
        integrated_startup[profile] = {
            "startup_online_median_ms": statistics.median(run["startup_online_ms"] for run in runs),
            "idle_rss_median_mib": statistics.median(run["idle_rss_bytes"] / 1048576 for run in runs),
            "idle_cpu_ms_each_2s": [run["idle_cpu_ms"] for run in runs],
        }
    for summary in integrated["summary"]:
        rows = [row for path in args.integrated.glob(f'trial-*-{summary["profile"]}/{summary["workload"]}.json')
                for row in read(path)["rows"]]
        observed = {"profile": summary["profile"], "workload": summary["workload"], "requests": len(rows),
                    "ws_final_observations": sum("mobile_final_ms" in row for row in rows),
                    "ws_first_delta_observations": sum("mobile_first_delta_ms" in row for row in rows)}
        assert observed["requests"] == summary["requests"]
        assert observed["ws_final_observations"] == observed["requests"]
        if summary["profile"] == "full":
            assert observed["ws_first_delta_observations"] == observed["requests"]
        integrated_observations.append(observed)
        for row in sorted(rows, key=lambda r: r["latency_ms"], reverse=True)[:3]:
            integrated_tail_diagnostics.append({"profile": summary["profile"], "workload": summary["workload"],
                **{key: row.get(key) for key in ["marker", "latency_ms", "submit_to_primary_ms", "primary_actual_total_ms", "mobile_final_ms", "mobile_first_delta_ms"]}})
    for path in args.integrated.glob("trial-*-full/history_8_pdf.json"):
        history_reaped_cpu.append(read(path)["agent_reaped_children_cpu_ms_per_request"])

    final_summary = {
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "agent_sha256": integrated["binary_sha256"], "example_sha256": cache["binary_sha256"],
        "server_sha256": integrated["server_binary_sha256"], "server_variant": integrated["server_variant"],
        "measurement_counts": {"original_components_requests": 1920, "integrated_requests": 720,
                               "cache_operations": 2520, "failures": 0},
        "original_components": components, "provider_metrics": provider_metrics,
        "integrated": integrated, "integrated_startup": integrated_startup,
        "integrated_observation_counts": integrated_observations,
        "integrated_tail_diagnostics": integrated_tail_diagnostics,
        "history_reaped_children_cpu_ms_per_request": history_reaped_cpu, "cache": cache,
        "vision_concurrency_before_after": {"prior_rust": prior_vision, "final_rust": final_vision,
                                            "current_python": python_vision,
                                            "comparison_scope": "Sequential frozen-build runs, same harness and server; not simultaneous paired randomized trials."},
        "history_cache_before_after": improvements,
        "result_directories": {"original_components": str(args.components), "integrated": str(args.integrated),
                               "cache": str(args.cache), "prior_components": str(args.prior_components)},
        "limitations": ["Original Python is its actual Adapter+AIAgent+SessionDB component harness, not full GatewayRunner.",
                        "Full/base is a feature envelope comparison, not equal payloads or equal auxiliary behavior.",
                        "Model delays are synthetic and actual durations are recorded separately.",
                        "HTTP polling is laboratory observation load; WS observer is not the Flutter renderer.",
                        "No project compilation or heavy project tests ran concurrently; shared host was not pinned or isolated.",
                        "No live model quality/cost, WAN/TLS, cold disk, UI/power or production capacity measurements."]}
    if not args.report_only:
        args.output.write_text(json.dumps(final_summary, indent=2) + "\n")

    lines = ["# 最终冻结版性能报告", "",
             "本报告对应下列冻结产物。原 d397 阶段的全部结果与四路图片记忆反例保留，本次不覆盖旧数据。客户端→Server→Agent→模型/文件的静态梳理见 `docs/PIPELINE_PROFILING.zh-CN.md`。", "",
             f'- Agent SHA256：`{integrated["binary_sha256"]}`。',
             f'- profiling example SHA256：`{cache["binary_sha256"]}`。',
             f'- 实际 Server SHA256：`{integrated["server_binary_sha256"]}`，variant 为原固定 baseline + TCP_NODELAY + command-ledger 独立补丁；原 baseline 未覆盖。',
             '- Orialis 固定 commit：`f9a064bf05b18265afd26905e7240777d4ce355c`；原 Hermes：`36b98bcced7f3c22d08dd1119240e726b3928e3d`。',
             '- 测量时未并行进行本项目编译/重负载测试；共享执行器未绑核、未隔离 CPU，没有置信区间。账号、文件、模型均为合成，无部署、推送或真实付费模型。', "",
             "## 结果概览", "",
             '- 原 Python 实际组件 vs 窄 Rust：**1920/1920 请求成功**，12 次进程启动无 setup 失败。',
             '- 同 Rust 基础/完整配置：**720/720 请求成功**，本轮统一包含已修正的首 delta 观察，不另加补样。',
             '- 同 example 派生缓存开关：**2520/2520 操作成功**，输入/输出 SHA 相同，0 重下载，真实命中计数断言通过。',
             f'- 四路图片记忆、模型名义等待 100ms：Rust p50 从旧版 **{prior_vision["p50_ms"]:.2f}ms** 降至 **{final_vision["p50_ms"]:.2f}ms**；本轮 Python 为 **{python_vision["p50_ms"]:.2f}ms**。具体并发/CPU/RSS 代价见下表。', "",
             '## 一、原 Python 实际组件与窄 Rust', "",
             'Python 执行原 OrialisAdapter、真实 AIAgent.run_conversation 和 SessionDB，不是重写的 Python 替身；但仍是组件 harness，**不是生产 GatewayRunner**。完整 GatewayRunner 的 AF_UNIX EPERM 边界未绕过、未重试。Rust 本组仅启用窄 QA/screen-memory 功能，未以 full 配置同窄 Python 比较。两边都重新运行于同一 patched Server，没有拼接旧 Server 的基线数字。', "",
             f'问题和最终答案受控相同，system prompt、工具 schema、辅助行为不同。已测 Python 为 {purposes["python"]["primary_chat"]} 次主 chat、{purposes["python"]["initial_auxiliary"]} 次 initial 辅助、{purposes["python"]["vision"]} 次 vision；Rust 为 {purposes["rust"]["primary_chat"]} 次主 chat、{purposes["rust"]["vision"]} 次 vision，没有 initial 辅助。辅助请求可与主请求重叠，因此不能将两次名义等待直接相加解释端到端延迟；这些差异也使本组结果不能直接解释为语言本身的加速倍率。', "",
             '每个 QA 行 120 样本，每个 memory 行 60 样本，均 3 轮。memory JPEG 沿用原 harness 的最小 JPEG 边界 fixture，不是截图质量/真实图像识别测试。', "",
             '吞吐为多轮成功请求数之和/负载墙钟时间之和，单位请求/秒。它包含模型等待和实验 HTTP 观察开销，不含组末 ACK drain；仅代表表中固定并发与观察负载下的吞吐，**不是饱和容量或生产 QPS 上限**。', "",
             '| 名义模型等待 ms | 负载 | 实现 | p50 ms | p95 ms | p99 ms | 吞吐 请求/秒 | Agent CPU ms/请求 | 峰 RSS MiB |',
             '|---:|---|---|---:|---:|---:|---:|---:|---:|']
    labels = {"chat_cold_c1": "新会话 QA 串行", "chat_warm_c1": "连续会话 QA 串行", "chat_c4": "QA 四并发",
              "memory_text_c1": "memory 文本串行", "memory_jpeg_c4": "memory JPEG 四并发"}
    for row in components["workloads"]:
        lines.append(f'| {row["model_delay_ms"]} | {labels[row["workload"]]} | {row["variant"]} | {row["p50_ms"]:.2f} | {row["p95_ms"]:.2f} | {row["p99_ms"]:.2f} | {row["throughput_per_s"]:.2f} | {row["gateway_cpu_ms_per_success"]:.2f} | {row["gateway_peak_rss_mib"]:.2f} |')
    lines += ["", '| 实现 | WS 在线启动中位 ms | idle RSS 中位 MiB | 完成负载后 RSS 中位 MiB |', '|---|---:|---:|---:|']
    for name, row in components["startup"].items():
        lines.append(f'| {name} | {row["startup_online_median_ms"]:.2f} | {row["idle_rss_median_mib"]:.2f} | {row["loaded_rss_median_mib"]:.2f} |')
    lines += ["", '启动包含名义 50ms 在线轮询，不应与下一组 10ms 在线轮询直接交叉比较。CPU 包含负载后的 100ms ACK drain；通常 10ms 的 CPU 计时粒度使单轮短负载可能显示 0，不能解释为不耗 CPU。RSS 为各自实际进程树，不含 Server 或远程模型，20ms 采样可能漏短峰。', "",
              '### 模型实际服务时间与请求体差异', "",
              '下表 body bytes 是所有模型调用的 JSON 请求体字节总和/用户请求，包含 Python 辅助调用；不是 IP/TCP/TLS 线上流量，也不是 token 数。实际服务时间含 fixture 的等待与请求处理，不等于名义 sleep。', "",
              '| 名义等待 ms | 负载 | 实现 | 模型实际 p50 ms | 模型实际 p95 ms | 所有 model body bytes/用户请求 |', '|---:|---|---|---:|---:|---:|']
    for row in provider_rows:
        lines.append(f'| {row["model_delay_ms"]} | {labels[row["workload"]]} | {row["variant"]} | {row["provider_actual_p50_ms"]:.3f} | {row["provider_actual_p95_ms"]:.3f} | {row["all_model_body_bytes_per_user_request"]:.0f} |')
    lines += ["", '### 四路图片记忆反例修复', "",
              '旧版 host admission=4，但内部 vision permits=2，四个有等待的请求形成两批。最终 CLI 的 `--memory-concurrency` 默认 4，同时传入外部 admission 和内部 client；仍有界且可配置。本实验使用默认值。', "",
              '| 同负载（100ms 模型、4 并发） | p50 ms | p95 ms | 吞吐 请求/秒 | CPU ms/请求 | 峰 RSS MiB | model body bytes/请求 |', '|---|---:|---:|---:|---:|---:|---:|']
    for label, row in [("旧 Rust d397（内部 2）", prior_vision), ("最终 Rust（内部 4）", final_vision), ("本轮 Python", python_vision)]:
        lines.append(f'| {label} | {row["p50_ms"]:.2f} | {row["p95_ms"]:.2f} | {row["throughput_per_s"]:.2f} | {row["gateway_cpu_ms_per_success"]:.2f} | {row["gateway_peak_rss_mib"]:.2f} | {row["model_payload_bytes"]/row["successes"]:.0f} |')
    lines += ["", '旧/新 Rust 为同 harness、同 Server 的先后冻结版本测量，不是同时配对随机试验；旧反例位于 `docs/PERFORMANCE_D397.zh-CN.md`。提高并发允许更多在途供应方请求及其资源占用，并不保证实际供应商配额或其他负载下同样收益。每个 memory 请求仍一次 vision 调用，请求数和字节差异如表所示。', "",
              f'原始数据：`results/{args.components.name}/`，包含 `summary.json`、`provider-metrics.json`、各 run 的结果/采样及 Python startup receipt。', "",
              '## 二、同二进制基础与完整配置开销', "",
              'base 为 owner 验证 + durable context。full 增加 domain、web_extract、stream、documents、interactions、output_files、scheduler、local tools、turn_updates。未配置 search 时 web_search 不广告；local execute=deny、write=ask；workspace 仅指向合成 root、terminal=false。full 使用独立 auxiliary HTTP endpoint。开关启用不等于所有功能均经过本组压力测试，只能推及下面的实际负载。', "",
              '主模型每次分 8 个等待间隔，名义总 20ms；辅助模型名义 2ms。表中另外记录实际时长。', "",
              '吞吐同样取多轮成功请求数/负载墙钟时间，包含模型等待和 HTTP 观察，不含组末 drain。concurrent4 为 4 并发，其余行串行；这些是固定并发、固定观察负载的结果，**不是饱和容量**。', "",
              '| 模式 | 负载 | N | p50 ms | p95 ms | p99 ms | 吞吐 请求/秒 | CPU ms/请求 | 峰 RSS MiB | 主/辅调用 | 主 body bytes/请求 | 辅 body bytes/请求 | 主实际 p50 ms |',
              '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for row in integrated["summary"]:
        lines.append(f'| {row["profile"]} | {row["workload"]} | {row["requests"]} | {row["p50_ms"]:.2f} | {row["p95_ms"]:.2f} | {row["p99_ms"]:.2f} | {row["requests_per_second"]:.2f} | {row["agent_cpu_ms_per_request"]:.2f} | {row["agent_peak_rss_bytes"]/1048576:.2f} | {row["primary_calls"]}/{row["auxiliary_calls"]} | {row["primary_body_bytes_per_request"]:.0f} | {row["auxiliary_body_bytes_per_request"]:.0f} | {row["primary_actual_p50_ms"]:.2f} |')
    lines += ["", '| 模式 | 在线启动中位 ms | idle RSS 中位 MiB | 每轮 2 秒 idle CPU ms |', '|---|---:|---:|---|']
    for profile, row in integrated_startup.items():
        lines.append(f'| {profile} | {row["startup_online_median_ms"]:.2f} | {row["idle_rss_median_mib"]:.2f} | {", ".join(f"{value:.0f}" for value in row["idle_cpu_ms_each_2s"])} |')
    lines += ["", '本组在线观察间隔为名义 10ms。idle CPU 接近计时粒度，显示 0 时不代表绝对零开销。']
    lines += ["", f'完整配置短文本串行 p50 从 {base_short["p50_ms"]:.2f}ms 到 {full_short["p50_ms"]:.2f}ms，CPU 从 {base_short["agent_cpu_ms_per_request"]:.2f} 到 {full_short["agent_cpu_ms_per_request"]:.2f}ms/请求，采样峰 RSS 从 {base_short["agent_peak_rss_bytes"]/1048576:.2f} 到 {full_short["agent_peak_rss_bytes"]/1048576:.2f}MiB。功能、流式预览、持久化与辅助请求共同变化，不能将差值单独归因于一个模块。full 新会话短请求为 1 主 + 2 辅助调用（initial、title）；工具负载为每请求 2 次主调用。', "",
              f'8 条历史 PDF 经真实 Server 上传和先前 turn 建立，再测 follow-up 热阶段；各轮已回收 Poppler CPU 增量均为 0，p50 {history["p50_ms"]:.2f}ms。主请求体仍有 {history["primary_body_bytes_per_request"]:.0f} bytes/用户请求；本地派生缓存不消除模型历史传输、prefill 或 token 成本。', "",
              'CPU 统计包含已回收子进程；RSS 20ms 采样可能漏短命 Poppler。各 case 的 Server CPU/RSS 单独保留。HTTP 每 2ms 查询持久回复只是**实验观察负载**，额外增加 Server 请求量，不是实际 mobile 默认轮询，也不是生产容量结论。', "",
              '### 合成 mobile WS 观察', "",
              '本轮直接采用已兼容 Server 外层 conversationId 的采集脚本。同一批请求同时记录 HTTP 最终、WS 最终和首 delta。base 未开 stream，首 delta 为不适用。', "",
              '| 模式 | 负载 | HTTP 最终 p50 ms | WS 最终 p50 ms | WS 首 delta p50 ms |', '|---|---|---:|---:|---:|']
    for row in integrated["summary"]:
        delta = '不适用' if row["mobile_first_delta_p50_ms"] is None else f'{row["mobile_first_delta_p50_ms"]:.2f}'
        final = '未记录' if row["mobile_final_p50_ms"] is None else f'{row["mobile_final_p50_ms"]:.2f}'
        lines.append(f'| {row["profile"]} | {row["workload"]} | {row["p50_ms"]:.2f} | {final} | {delta} |')
    worst = max((row for row in integrated_tail_diagnostics if row["profile"] == "full" and row["workload"] == "history_8_pdf"), key=lambda row: row["latency_ms"])
    lines += ["", f'尾部保留而不剔除：full 历史样本最大延迟 {worst["latency_ms"]:.2f}ms，其中提交到主模型接收 {worst["submit_to_primary_ms"]:.2f}ms、受控主模型实际服务 {worst["primary_actual_total_ms"]:.2f}ms。名义 20ms 不代表每个样本恰好 20ms；延迟来自多个阶段，现有数据不能将峰值单独归因于某个 Rust 模块或真实模型。各负载最慢三例的阶段时间另存综合 summary。']
    lines += ["", '这些是合成 subscriber 收到事件的时间，**不是 Flutter 首屏渲染、触屏到首字或 WAN/TLS 体验**。首 delta 只统计 agent.delta/stream.delta，initial/title 普通辅助回复不纳入此字段；事件计数、关联时间和模型时间分别保存，不能外推真实模型的首 token 性能。', "",
              f'原始数据：`results/{args.integrated.name}/`。', "", '## 三、真实派生缓存开关对照', "",
              '同一最终 example、同一显式 synthetic owner、同配置、同文件字节。cache_off 只将 max_entries/max_bytes 置零；两模式仍走安全打开、实际内容 hash、Poppler 二进制身份及同 FD 验证。每行 90 次操作，3 次 warmup 不计入热阶段。cache_on 每次真实命中被断言，cache_off 为 0 条目。返回 canonical SHA 相同，测量期间下载数为 0。', "",
              '| 文件 / 历史数 / 预算 | 缓存 | p50 ms | p95 ms | CPU ms/次 | 成功 hit 数 | 派生缓存计账 bytes |', '|---|---|---:|---:|---:|---:|---:|']
    for row in cache["summary"]:
        if row["operation"] == 'hydrate':
            lines.append(f'| {row["file"]} / {row["history"]} / {row["budget"]} | {row["variant"]} | {row["p50_ms"]:.3f} | {row["p95_ms"]:.3f} | {row["cpu_ms"]:.3f} | {row["measured_cache_hits"]} | {row["cache_bytes"]} |')
    lines += ["", '8 条组件历史使用同 fixture 字节和显示名、不同 source IDs，因此可共享同 conversation 的一条派生条目；不是 8 种实际文档的代表分布。完整链路历史 case 上传了 8 个不同名字的文件。key 绑定 owner/transport/conversation、实际内容 SHA、解析配置/版本/Poppler 身份、精确剩余预算，不仅依赖路径。', "",
              '默认上限为 16MiB 派生数据、256 条、15 分钟 TTL。缓存增加常驻派生数据和有界索引/allocator 开销。采样峰 RSS 包含首次未缓存解析及 Poppler 预热，不能据此声称缓存不耗内存或同幅度减少内存。hash/fetch/未 scoped 低级 extract 的对照和首次未预热耗时保留在 summary。', "",
              f'原始数据：`results/{args.cache.name}/`。收益来自同最终 example 的开关对照，不将旧 API 或未绑定 owner 时未触发缓存的运行冒充命中。', "",
              '## 后续候选与适用边界', "",
              '1. **完整模型 schema/历史字节。** full 主请求比 base 大很多。可继续研究任务相关 schema 和供应方支持的 prefix cache；保留必需工具、授权和功能语义，真实 token/计费/prefill 收益仍需另测。',
              '2. **附件原始 cache 目录维护。** 先前独立微基准中 1 到 512 目录使 hit 约 0.015 到 1.96ms。本轮未改扫描算法，不能将安全配额维护的变化混入派生缓存收益。',
              '3. **PDF 输出排空。** 8KiB 读取后的等待是静态候选，本轮未改或做隔离 A/B，不给出收益倍率。',
              '4. **供应方并发与总预算。** 4 路默认解决了本次已测两批等待，但更高并发不是无限制的性能提升；真实供应方配额、峰内存和 p95/p99 应在目标环境再测。', "",
              '未测真实模型质量/计费、WAN/TLS、移动 UI 帧率/功耗、冷磁盘、OCR 或生产多租户容量。有限样本 p99，尤其每行 60 个 memory 样本时接近最大值，不能当作稳定线上 SLO。完整 GatewayRunner 仍未在此环境跑通，不能宣称所有生产组合完全等价。', "",
              '## 复现与数据', "",
              '所有命令从仓库工作区执行，要求已有冻结二进制与固定 fixtures。三个脚本按顺序运行，不同时运行重负载。结果目录必须不存在。', "",
              '先按 `docs/REPRODUCE_FINAL.zh-CN.md` 准备固定上游 Hermes 的 Python 依赖环境。下面 `PYTHON_BASELINE` 是占位路径，必须替换为已准备完成的解释器绝对路径，不能直接照抄运行；不依赖本次环境的 `/tmp` 默认解释器。', "",
              '```sh',
              'ROOT="$PWD"',
              'PYTHON_BASELINE=/absolute/path/to/prepared-hermes-venv/bin/python',
              'AGENT="$ROOT/hermes-rust-core/results/final-release/orialis_agent"',
              'EXAMPLE="$ROOT/hermes-rust-core/results/final-release/profile_documents"',
              'SERVER="$ROOT/orialis-command-ledger/verification/server-ledger-nodelay"',
              'VARIANT=baseline-plus-tcp-nodelay-plus-command-ledger',
              'python hermes-rust-core/tests/compare_original_components.py --python-binary "$PYTHON_BASELINE" --rust-binary "$AGENT" --server-binary "$SERVER" --server-variant "$VARIANT" --out "$ROOT/hermes-rust-core/results/reproduce-components" --trials 3 --n 40 --delays 0 100',
              'python orialis-full-eval/harness/summarize.py hermes-rust-core/results/reproduce-components',
              'python hermes-rust-core/tests/benchmark_integrated_profile.py --binary "$AGENT" --server "$SERVER" --server-variant "$VARIANT" --out "$ROOT/hermes-rust-core/results/reproduce-integrated" --trials 3 --iterations 40 --deep-iterations 20',
              'python hermes-rust-core/tests/compare_document_cache.py --binary "$EXAMPLE" --out "$ROOT/hermes-rust-core/results/reproduce-cache" --iterations 30 --trials 3',
              '```', "",
              '每个结果目录保留本次实际执行脚本副本及 hash。综合机器可读结果在 `results/final2-summary.json`，逐请求指标、事件观察时间、模型调用记录和分布在三个 `results/final2-*` 目录中。']
    args.report.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--components", type=Path, default=root / "results/final2-original-components")
    parser.add_argument("--integrated", type=Path, default=root / "results/final2-integrated-profile")
    parser.add_argument("--cache", type=Path, default=root / "results/final2-document-cache-ab")
    parser.add_argument("--prior-components", type=Path, default=root / "results/final-original-components")
    parser.add_argument("--output", type=Path, default=root / "results/final2-summary.json")
    parser.add_argument("--report", type=Path, default=root / "docs/PERFORMANCE_FINAL.zh-CN.md")
    parser.add_argument("--report-only", action="store_true", help="Only rewrite Markdown; preserve all result JSON files.")
    main(parser.parse_args())
