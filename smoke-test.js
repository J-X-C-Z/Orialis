const fs = require("node:fs");

const html = fs.readFileSync("index.html", "utf8");
const app = fs.readFileSync("app.js", "utf8");
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
const referencedIds = [...app.matchAll(/\$\("#([A-Za-z][\w-]*)"\)/g)].map((match) => match[1]);
const missing = [...new Set(referencedIds)].filter((id) => !ids.includes(id));
const dialogTargets = [...html.matchAll(/data-close-dialog="([^"]+)"/g)].map((match) => match[1]).filter((id) => !ids.includes(id));

JSON.parse(fs.readFileSync("manifest.webmanifest", "utf8"));

if (duplicates.length || missing.length || dialogTargets.length) {
  console.error({ duplicateIds: duplicates, missingScriptTargets: missing, missingDialogTargets: dialogTargets });
  process.exit(1);
}

if (!html.includes('id="remindersModal"')) throw new Error("提醒设置弹窗不存在");
for (const marker of ["reminderSettingsBtn", "testNotificationBtn", "testSystemAlarmBtn"]) {
  if (!html.includes(`id="${marker}"`) || !app.includes(`$("#${marker}").addEventListener`)) throw new Error(`提醒入口未完成事件连接：${marker}`);
}
if (/小爱|voiceAssistantSetting|\/api\/voice\//.test(html + app)) throw new Error("界面或脚本仍残留已停用的小爱功能");
if (!html.includes('id="weekCalendar"') || !html.includes('data-schedule-mode="timetable"') || !app.includes("data-calendar-slot-date")) throw new Error("通用日历周视图未与课表分离或不能直接新建日程");
if (!app.includes("localStorage.removeItem(TEST_REMINDER_KEY)")) throw new Error("网页测试提醒到期后不会触发或清理");

const parser = require("./smart-parser");
const parsedEvent = parser.parseNaturalInput("提醒我明天下午三点在图书馆开会一小时，提前十分钟提醒", { now: "2026-09-04T12:00:00", courses: [], projects: [] });
if (parsedEvent.type !== "event" || parsedEvent.startDate !== "2026-09-05" || parsedEvent.startTime !== "15:00" || parsedEvent.endTime !== "16:00" || parsedEvent.location !== "图书馆") throw new Error("自然语言识别未正确生成单点时间日程");
const parsedCourseTask = parser.parseNaturalInput("明晚九点交物理作业", { now: "2026-09-04T12:00:00", courses: [{ id: "physics", name: "大学物理A（上）" }], projects: [] });
if (parsedCourseTask.courseId !== "physics" || parsedCourseTask.dueTime !== "21:00") throw new Error("自然语言识别未完成课程模糊关联或晚间时间转换");

console.log(`静态检查通过：${ids.length} 个界面节点，${new Set(referencedIds).size} 个脚本引用。`);
