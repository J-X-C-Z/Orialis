# B站412继续排查（2026-10-25）

状态：服务器单文件发布及公网完整验收已通过。扫码登录后视频获取恢复，异常字幕整轨弃用、仅含音乐标记时使用抽样画面；测试视频返回completed、category=ai、videoStatus=analyzed，实际概述准确。43项最终相关测试通过。本次未改动或部署手机端。

## 最终发布与验收

发布目录：`/home/hermes/.hermes/releases/orialis-bili-memory-20261025-022225`；回滚文件：同目录`memory_video.previous.py`。仅替换生产`memory_video.py`，SHA256为53727070ec4489565f630547a26f7a1a049469054114fc64da5615f3ab856422。其余插件Python源码逐字节保留，API程序、环境和数据库结构均未改动；只重启Hermes网关。

最终切换成功，无需回滚。Hermes PID1727629、active/running、NRestarts=0、Orialis connected；API PID1713674保持不变、active/running、NRestarts=0，本地`/api/health`返回200。

Mac公网客户端通过正式API、短期测试Session提交BV1d8pU6xEZX，线上API转交Azure Hermes后完成视频理解：原链接保持不变，category=ai，videoStatus=analyzed，videoError为空。概述准确指出画面中的手动刷视频与关键词/标签搜索，并明确仅基于三张抽样画面及画面内字幕。重复POST复用同一任务，持久化1条测试任务；临时Session和任务均按精确ID清理，无对应测试聊天记录。

可复核证据：交付目录的`promotion.json`、`postflight.json`、`acceptance-public.json`、`model-frame-verification.json`和`final-tests.log`。账号Cookie不进入这些证据。B站权限、登录失效或未来平台限制仍按真实结果返回不可用，不声称任意视频均可完整理解。

## 实测

固定公开演示视频BV1d8pU6xEZX。Azure侧有界请求共11次，结果：

- 自写http.client、公网IP绑定、完整Chrome UA的curl HTTP/1.1和HTTP/2、第二个DNS节点、view/detail都返回412。
- 官方bilibili-api-python17.4.1 + aiohttp，fresh匿名Credential，自动访客领取SPI200/code0、ExClimbWuzhi激活200/code0，随后带buvid3/4和opus访客Cookie的view仍412。
- 同一官方SDK + curl_cffi0.16.3、Chrome131 TLS与HTTP/2，SPI和激活同样成功，view仍412。
- 另一个已有自有Nagi服务器的普通公开view请求也返回412。

以上是匿名请求阶段的结果，当时没有取得CID。现有证据排除了仅调整UA、HTTP版本、单个DNS节点、匿名初始化或直接重复请求即可修复的说法；不能仅凭这些结果断言账号状态不会影响平台判断。

第二轮扫码后的实测：登录nav与SDK view均200/code0，isLogin为真、CID存在。候选memory_video.py未包裹或修改HTTP客户端，直接collect_video初次取得677字平台字幕，耗时1.46秒。进一步核对发现该分段157秒，但字幕到180.7秒且内容讲手表；view和player的BV、aid、CID均匹配，不能将这份异常字幕当作正确视频证据。早期候选探针因包装连接初始化而在发送HTTP前失败，属于无效探针，不代表候选读取失败。

最终实现先核验整条字幕轨时间，非法时间或超过max(3秒,时长×2%)即弃用整轨；另一次发布前复查返回仅含“♪ 音乐 ♪”标记的有效时间字幕，已增加音乐标记轨使用故事板的处理。第一轮单文件发布预检因此停止，未切换线上模块；最终43项测试通过后重新发布。正确分段故事板取得37、75、115秒3张画面，人工目视确认DSH配置界面及“手动刷视频”“关键词或标签搜索”的画面内字幕。真实生产模型基于这些画面返回准确视频概述和AI分类，明确仅依据抽样画面。第一次画面模型请求遇到临时限流，短暂退避后的同一配置调用23.34秒成功；没有更换模型配置。原始证据仅保存在服务器私有release目录，未复制登录Cookie到本机。

## 参考项目实际做法

核对c1overzz/dsh-bili-scroll提交5be5f6d57c47c7e79ad9bc4ce39457b68a160dfa，HEAD未变。依赖bilibili-api-python>=17.4.1,<18与aiohttp。

字幕工具通过get_cred要求扫码登录；故事板通过可空load_credential允许匿名请求。SDK17.4.1 get_info仍调用未签名的/x/web-interface/view；其默认访客激活和会话复用与当前自写HTTP客户端不同，但实测补齐这些流程仍未解Azure412。SDK不自动重试HTTP412，WBI接口JSON -403的刷新签名处理也不是当前view失败的根因证据。

账号授权由用户在B站App内完成正常扫码确认，私有文件位于服务器Hermes目录，权限600；不读取其他应用的Cookie。首轮流程经过awaiting_confirmation后返回缺少登录状态，未保存凭据、未改线上插件或重启服务。SDK17.4.1源码仅从poll返回URL手动切分会话字段；上游使用者报告当前平台已通过Set-Cookie返回会话（见下方issue32），需读取实际响应Cookie并校验。授权后仍需以真实字幕/画面和后台模型结果验证是否解决。

修复后的独立CLI通过SDK底层HTTP客户端请求相同的官方WEB generate/poll接口，读取成功响应的Cookie；仅poll成功码0且SESSDATA有效时按600权限原子保存。保留SDK的SESSDATA编码规则和正常领取的访客字段，不把未知状态当成成功，也不因后续视频API受限而丢弃已授权的会话。授权码、登录Cookie及其值均不写入诊断日志。

## 线上保全与证据

发布前API oris.service及hermes-gateway.service均active、NRestarts0。生产memory_video.py原始SHA256为d06031da3f131c9fb106c597375018b450875156a815e5ee2ab6c58223f2e600；最终候选为53727070ec4489565f630547a26f7a1a049469054114fc64da5615f3ab856422。memory_analysis.py仍为ba3cc7b6584a678be653309434dd46b900e20ed3912851565106b9c86af67d77。其他会话已更新adapter.py和response_ui.py，本次以实时哈希保护其更改，仅切换memory_video.py，不恢复整个旧插件或API。

诊断证据在projects/orialis/deliveries/bili-412-20261025/。SDK仅安装于服务器/tmp隔离环境，未写入Hermes运行环境；访客Cookie不含SESSDATA/bili_jct，不记录Cookie值。

服务器登录工具运行环境已独立放在Hermes私有release目录，生产视频读取仍只使用原有标准库与Pillow。凭据权限600、所有者Hermes，只保留服务器本地专用文件。

API的健康路由为`/api/health`或`/api/v1/health`，不是`/health`。一次单文件切换在网关已连回、其他源码保留检查通过后，因为发布脚本误用`/health`而自动回滚；修正检查路径后重新发布。该回滚只恢复memory_video.py并重启Hermes，不回滚数据库、API或其他会话代码；过程记录为promotion-rolled-back-health-path.json。

源码依据：
- https://github.com/c1overzz/dsh-bili-scroll/blob/5be5f6d57c47c7e79ad9bc4ce39457b68a160dfa/vendor/bilibili-mcp/mcp_server.py
- https://pypi.org/project/bilibili-api-python/17.4.1/
- https://github.com/public-clis/bilibili-cli/issues/32
