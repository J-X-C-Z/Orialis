const assert = require("node:assert/strict");
const fs = require("node:fs");

const html = fs.readFileSync("index.html", "utf8");
const app = fs.readFileSync("app.js", "utf8");
const parser = fs.readFileSync("smart-parser.js", "utf8");
const docxParser = fs.readFileSync("docx-schedule-parser.js", "utf8");
const worker = fs.readFileSync("service-worker.js", "utf8");
const layout = fs.readFileSync("v22-layout.css", "utf8");
const installer = fs.readFileSync("deploy/install.sh", "utf8");

assert.match(html, /class="nav-item active" data-view="today"/, "今天应是默认主入口");
assert.match(html, /<section class="view active" id="todayView">/, "今天工作台应默认可见");
assert.match(html, /id="todayNextSchedule"[\s\S]*id="todayFocusList"[\s\S]*id="todayLaterList"[\s\S]*id="todayDeadlineList"/, "今天页应形成连续工作流");
assert.match(html, /id="mobileNavCreate"/, "手机底栏应有唯一中央创建按钮");
assert.match(app, /focusTasks\(3\)/, "今日专注推荐最多三件");
assert.match(app, /function deadlineState/, "期限状态必须由统一函数提供");
assert.match(app, /function stageScheduleImport/, "课表导入必须先暂存预览");
assert.match(app, /function undoScheduleImport/, "课表导入必须可撤销");
assert.match(html, /id="smartCaptureIssues"/, "智能识别必须显示字段级不确定性");
assert.match(parser, /confidence: issues\.length \? "needs-confirmation" : "high"/, "解析器必须返回字段级确认状态");
assert.match(worker, /message[\s\S]*SKIP_WAITING/, "PWA 只能在收到用户确认消息后激活更新");
assert.doesNotMatch(worker, /install[\s\S]{0,180}self\.skipWaiting/, "安装阶段不能静默强制切换版本");
assert.match(layout, /grid-template-rows:minmax\(0,1fr\) auto/, "移动端必须采用内容加底栏的稳定网格");
assert.match(installer, /styles\.css v22-layout\.css smart-parser\.js/, "部署脚本必须复制 v2.2 移动布局");
assert.match(html, /id="taskEstimate"/, "事项应支持预计时长");
assert.match(html, /id="wordScheduleInput"/, "课表导入必须支持 Word DOCX 入口");
assert.match(docxParser, /parseScheduleDocumentXml/, "Word 导入必须在本机解析表格并进入预览流程");
assert.match(app, /function reparseInboxTask/, "升级前遗留的待确认事项必须支持重新识别");
assert.match(layout, /#projectsView \.project-dashboard \{ position:static/, "手机项目统计不得悬浮遮挡第一张项目卡");
assert.match(layout, /#projectsView \.project-card-actions \{[^}]*grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\)/, "手机项目行动和编辑按钮必须使用等宽触控区");
assert.match(html, /id="outlookIntegrationSetting"[\s\S]*id="googleIntegrationSetting"[\s\S]*id="systemCalendarSetting"/, "日历页必须同时提供 Outlook、Google 和 Android 双向同步入口");
assert.match(app, /function syncOutlookNow[\s\S]*function syncGoogleNow[\s\S]*function reconcileNativeCalendar/, "网页端必须接通 Outlook、Google 与系统日历双向合并逻辑");
assert.match(installer, /server\.js outlook-sync\.js google-sync\.js package\.json/, "部署脚本必须复制外部日历同步服务端模块");

console.log("v2.7 核心流程检查通过：今天首页、智能确认、导入撤销、手机项目布局、三端双向日历入口与显式 PWA 更新均已覆盖。");
