#!/usr/bin/env python3
"""Derive the host-runtime report from raw measurements; never run workloads."""
import collections,hashlib,json,math,statistics
from pathlib import Path
C=Path(__file__).resolve().parents[1];R=C/'results'
def read(p):return json.loads(p.read_text())
def q(v,p):return sorted(v)[max(0,math.ceil(len(v)*p)-1)] if v else None
def f(n):return f'{n:.2f}' if n is not None else 'null'
def main():
 raw=read(R/'host-runtime-original-components/all-results.json');rows=[]
 for delay in [0,100]:
  for variant in ['python','rust']:
   runs=[r for r in raw if r['variant']==variant and r['model_delay_ms']==delay]
   for name in runs[0]['workloads']:
    xs=[r['workloads'][name] for r in runs];values=[i['latency_ms'] for x in xs for i in x['rows'] if i['ok']];n=len(values);purposes=collections.Counter()
    for x in xs:purposes.update(x['model_call_purposes'])
    rows.append({'variant':variant,'model_delay_ms':delay,'workload':name,'requests':sum(x['count'] for x in xs),'successes':n,'failures':sum(x['errors'] for x in xs),'p50_ms':q(values,.5),'p95_ms':q(values,.95),'p99_ms':q(values,.99),'throughput':n/sum(x['elapsed_seconds'] for x in xs),'agent_cpu_ms_per_request':sum(x['gateway_cpu_seconds'] for x in xs)*1000/n,'peak_rss_bytes':max(x['gateway_peak_rss_bytes'] for x in xs),'server_cpu_ms_per_request':sum(x['server_cpu_seconds'] for x in xs)*1000/n,'model_calls':sum(x['model_calls'] for x in xs),'model_bytes_per_request':sum(x['model_payload_bytes'] for x in xs)/n,'call_purposes':dict(purposes),'provider_actual_p50_ms':q([i for x in xs for i in x['provider_actual_service_raw_ms']],.5)})
 orig={'runs':len(raw),'requests':sum(r['requests'] for r in rows),'failures':sum(r['failures'] for r in rows),'agent_sha256':sorted(set(r['binary_sha256'] for r in raw if r['variant']=='rust')),'server_sha256':sorted(set(r['server_sha256'] for r in raw)),'summary':rows,'startup':{v:{'online_median_ms':statistics.median(r['startup_online_ms'] for r in raw if r['variant']==v),'first_turn_median_ms':statistics.median(r['first_turn_ms'] for r in raw if r['variant']==v)}for v in ['python','rust']}}
 (R/'host-runtime-original-components/summary.json').write_text(json.dumps(orig,indent=2)+'\n')
 comp=read(R/'host-runtime-release-comparison/comparison.json');py=read(R/'host-runtime-python-main-perf.json');dele=read(R/'host-runtime-delegation-main-perf/summary.json');manifest=read(R/'host-runtime-release/manifest.json');sha=manifest['binary_sha256']
 assert orig['requests']==1920 and orig['failures']==0 and orig['agent_sha256']==[sha]
 assert comp['identities']['candidate']['sha256']==sha and py['agent_sha256']==sha and py['status']=='passed'
 assert all(r[a]['failures']==0 for r in comp['summary'] for a in ['baseline','candidate'])
 state={'agent_sha256':sha,'source_tree_sha256':manifest['source_tree_sha256'],'original_components':orig,'same_configuration_comparison':comp,'python_summary':py['summary'],'python_warnings':py['warnings'],'delegation':dele,'measurement_counts':{'original_components':1920,'same_configuration':sum(r[a]['requests'] for r in comp['summary'] for a in ['baseline','candidate']),'python_main':len(py['cells']),'delegation_main':sum(v['requests']for v in dele['aggregate'].values())}}
 (R/'host-runtime-performance-summary.json').write_text(json.dumps(state,indent=2)+'\n')
 lines=['# 当前宿主扩展 release 性能报告','','## 口径与结果','',f'- Agent SHA256：`{sha}`。',f'- Server SHA256：`{orig["server_sha256"][0]}`，独立控制响应/ledger/TCP_NODELAY补丁版本。','- 原 Python 为固定源码实际 Adapter+AIAgent+SQLite 组件，完整 GatewayRunner 受命名IPC限制未运行；窄Rust对照没有相同的辅助回答和通用宿主功能，不能算纯语言或完整替换对照。','- 原组件1920次、同配置新旧Rust1440次、Python冷暖60次、委派270次全部成功；另5个release组件性能项通过。','- 采样串行执行，无本项目并发编译或重负载测试；共享执行器未绑核，有限样本p99不代表线上SLO。真实模型、WAN/TLS和Flutter渲染未测。','- 原始JSON、逐请求记录、调用数/字节、脚本及哈希均保留于 results/host-runtime-*；本报告由 tests/summarize_host_runtime.py 从结果生成。','','## 实际原Python组件与当前窄Rust','','3轮、0/100ms名义模型延迟；表中CPU为Agent进程树ms/成功请求，RSS为采样峰值。Python聊天每次主模型1次+初始辅助1次，Rust主模型1次；屏幕图片两者均1次vision，但提示词字节并不完全相等。','','|模式|名义模型ms|负载|n|p50/p95/p99 ms|成功/s|CPU ms/请求|RSS MiB|模型字节/请求|','|---|---:|---|---:|---|---:|---:|---:|---:|']
 for r in rows:lines.append(f'|{r["variant"]}|{r["model_delay_ms"]}|{r["workload"]}|{r["successes"]}|{f(r["p50_ms"])}/{f(r["p95_ms"])}/{f(r["p99_ms"])}|{f(r["throughput"])}|{f(r["agent_cpu_ms_per_request"])}|{f(r["peak_rss_bytes"]/2**20)}|{f(r["model_bytes_per_request"])}|')
 lines+=['','在线启动中位数 Python '+f(orig['startup']['python']['online_median_ms'])+'ms、Rust '+f(orig['startup']['rust']['online_median_ms'])+'ms。首轮另含惰性初始化，不能只用online时间代表全部冷启动。完整明细含首轮时间与实际模型服务时间。','','## 相同已有配置的新旧Rust回归','','旧b755与新1c8f分别在同一个Server上3组AB/BA交替。base/full是原有功能开关，不包含新增opt-in Python、委派、native images。full新增schema约258字节/主调用，因此并非完全相同请求体。','','|配置/负载|旧→新 p50 ms|旧→新 p95 ms|旧→新 p99 ms|旧→新 CPU ms/请求|旧→新 RSS MiB|','|---|---|---|---|---|---|']
 for r in comp['summary']:
  a,b=r['baseline'],r['candidate'];lines.append(f'|{r["profile"]}/{r["workload"]}|{f(a["p50_ms"])}→{f(b["p50_ms"])}|{f(a["p95_ms"])}→{f(b["p95_ms"])}|{f(a["p99_ms"])}→{f(b["p99_ms"])}|{f(a["agent_cpu_ms_per_request"])}→{f(b["agent_cpu_ms_per_request"])}|{f(a["agent_peak_rss_bytes"]/2**20)}→{f(b["agent_peak_rss_bytes"]/2**20)}|')
 lines+=['','新版本没有全面变快：基础短文本p50增加约1.67ms、峰RSS增加约3.4MiB；完整短文本p50增加约0.60ms。四并发尾延迟也变差，原始尖峰未剔除。不能把差异全归为安全检查或某个模块，尚无逐函数因果隔离。后续重点是这条基础路径回归而非再宣传总体倍率。','','## 持久Python真实主链','','相同release、相同Python代码与两轮模型调用，每次一次真实native审批，3轮交替、冷暖各30次。冷分支reset实际解释器，暖分支复用，历史长度作了匹配。延迟观测到服务端已持久最终回复，含5ms HTTP轮询量化与测试驱动负载。','','|分支|p50/p95/p99 ms|成功cell/s|Agent树CPU ms/cell|Server CPU ms/cell|','|---|---|---:|---:|---:|']
 for arm,s in py['summary'].items():
  d=s['submit_to_persisted_final_seconds'];cpu=s['timed_block_cpu_seconds'];lines.append(f'|{arm}|{f(d["p50"]*1000)}/{f(d["p95"]*1000)}/{f(d["p99"]*1000)}|{f(s["fixed_load_cells_per_second"])}|{f(cpu["agent"]["tree_cpu_seconds"]*1000/d["n"])}|{f(cpu["server"]["tree_cpu_seconds"]*1000/d["n"])}|')
 peaks={arm:max(c['sampled_peak_rss_kib']['agent']['tree_rss_kib'] for c in py['cells'] if c['arm']==arm and c['sampled_peak_rss_kib'].get('agent') is not None) for arm in ['cold','warm']}
 lines+=['',f'主链p50 {f(py["summary"]["cold"]["submit_to_persisted_final_seconds"]["p50"]*1000)}→{f(py["summary"]["warm"]["submit_to_persisted_final_seconds"]["p50"]*1000)}ms。进程树采样峰RSS cold/warm 为 {f(peaks["cold"]/1024)}/{f(peaks["warm"]/1024)}MiB；测试同时保留冷/暖两个会话kernel，不能当单kernel开销。部分逐cell CPU快照因进程退出不可用，保留null；表格使用完整block的有效计数，见warnings。','组件单kernel25对测量：冷p50 26.87ms、暖1.40ms；宿主8.07MiB、sandbox进程合计9.39MiB，关闭后0残留。这是组件值，不可替代上表主链。','','## 委派与图片热点','','委派默认270次，2个名义20ms子模型并行、2次父模型；不与不存在的旧委派实现做伪A/B。真实mobile WS观测最终回复，再验服务端持久化。','','|负载|n|p50/p95/p99 ms|各轮成功/s|','|---|---:|---|---|']
 for name,r in dele['aggregate'].items():
  d=r['pooled_latency_ms'];lines.append(f'|{name}|{r["requests"]}|{f(d["p50"])}/{f(d["p95"])}/{f(d["p99"])}|'+', '.join(f(v) for v in r['trial_requests_per_second'])+'|')
 lines+=['','全部调用数与任务结果均断言，完整Agent/Server/driver CPU与RSS在该目录summary及逐轮result中。100次无工具委派组件p50 0.308ms、p95 0.474ms。schema编译+验证p50 9.624µs，复用验证0.080µs；收益量级小于模型/SQLite/网络，不因此引入全局无界schema缓存。','', '图片已规范化后的组件：序列化中位0.168ms、SQLite FULL工具receipt 1.111ms、turn finalize 4.447ms，下一轮读取/验证/编码0.809ms。保留耐久性与哈希/预算检查，没有为速度关闭fsync。','', '相同规范化像素，8次native/auxiliary实际loopback HTTP：第一轮中位native47.48ms、aux42.40ms；下一轮2.45/1.20ms。native省一次辅助模型HTTP，但后续主请求约329KB，aux主请求约3.8KB、单独vision约325KB；native的能力更强但此本机零模型等待样本并未更快。无真实视觉质量、计费或公网延迟结论。','','## 全链路优化优先级与未测边界','','1. 已验证收益：持久Python消除反复启动；Server控制链保活和reserved-stop恢复正确性。旧阶段TCP_NODELAY/文档派生缓存的A/B仍有效于其版本，本轮没有重测缓存开关，不能挪用旧倍率充作当前新结果。','2. 当前新增成本：基础路径约1–2ms和约3MiB回归；四并发尾部需进一步采样归因。不能用阈值放宽或少存回执掩盖。','3. 图片实际热点更偏耐久写入/后续大请求，JSON schema不是当前优先热点。可评估内容寻址去重和更细的历史图像选择，但必须先证明回执/重放/质量等价，尚未实施。','4. 首delta是合成mobile WS收到事件，不是Flutter首屏。客户端渲染、移动网络、电量、TLS、公网模型及真实token成本均未测。','5. 原Python完整GatewayRunner、真实Chromium、真实SSH profile-sync、长期浸泡与生产切换未完成；当前结果不是可无条件替换生产的承诺。','','所有请求级原始记录都保留，失败/未知采样不转换成零，组件和主链数值不混算。']
 (C/'docs/PERFORMANCE_HOST_RUNTIME.zh-CN.md').write_text('\n'.join(lines)+'\n')
 print(json.dumps(state['measurement_counts']))
if __name__=='__main__':main()
