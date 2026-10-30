# Android 屏幕记忆压缩保存与上传缓存清理

来源：2026-10-31 用户要求压缩上传、减少存储占用。当前上传链路已有最长边 1600 像素、JPEG 80（大图回退 55）、900 KiB 上限，保持该协议。

新增：MemoryStore.save 对新截图/分享图片尝试原分辨率 JPEG 88，本地编码副本尺寸读回一致且实际字节数更小时才使用；先原子落盘记录，再删除临时 PNG。编码或写盘失败保留原图。超过 2000 万像素的分享图片保留原图，避免再次大规模解码。读取同时兼容旧 PNG 与新 JPEG，路径仍限制在账号与记录所属位置；不批量转换已有记忆。后台理解 completed/failed 状态落盘后删除可再生成的上传缓存。

验证：Android :app:compileDebugKotlin --offline 成功；memory_analyzer、memory_background、memory_analysis_api、memory_record 共 44 项回归通过；git diff --check 通过。Flutter 测试通过模拟原生通道验证上传协议，不是 Bitmap 压缩率验证。未安装新手机包，未运行真机图片压缩/文字清晰度验收，没有声称具体节省比例。
