const assert = require("node:assert/strict");
const parser = require("./docx-schedule-parser.js");

const cell = (text, props = "") => `<w:tc><w:tcPr>${props}</w:tcPr>${text ? `<w:p><w:r><w:t>${text}</w:t></w:r></w:p>` : ""}</w:tc>`;
const row = (cells) => `<w:tr>${cells.join("")}</w:tr>`;
const emptyDays = () => Array.from({ length: 6 }, () => cell(""));
const xml = `<w:document xmlns:w="urn:test"><w:body><w:tbl>${row([cell("节次"), ...["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"].map((day) => cell(day))])}${row([cell("第1节 08:00~08:45"), cell("高等数学 / 张三 / 湖畔校区B12-101 / 1-16周", '<w:vMerge w:val="restart"/>'), ...emptyDays()])}${row([cell("第2节 08:55~09:40"), cell("", "<w:vMerge/>"), ...emptyDays()])}</w:tbl></w:body></w:document>`;

const result = parser.parseScheduleDocumentXml(xml, { totalWeeks: 20 });
assert.equal(result.courses.length, 1, "纵向合并的 Word 单元格应合并为一条连续课程");
assert.deepEqual({ name: result.courses[0].name, day: result.courses[0].day, start: result.courses[0].startSection, end: result.courses[0].endSection }, { name: "高等数学", day: 1, start: 1, end: 2 });
assert.equal(result.courses[0].weeks.length, 16, "应识别 1-16 周");
assert.equal(result.courses[0].teacher, "张三", "应识别教师");
assert.match(result.courses[0].location, /B12-101/, "应识别教室");
assert.equal(result.timeSlots.length, 2, "应识别 Word 表格中的节次时间");
assert.deepEqual(parser.parseWeeks("1-16周 单周", 20).weeks.slice(0, 4), [1, 3, 5, 7]);

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) { crc ^= byte; for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
  return (crc ^ 0xffffffff) >>> 0;
}

function storedDocx(documentXml) {
  const name = Buffer.from("word/document.xml");
  const body = Buffer.from(documentXml);
  const checksum = crc32(body);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt32LE(checksum, 14); local.writeUInt32LE(body.length, 18); local.writeUInt32LE(body.length, 22); local.writeUInt16LE(name.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt32LE(checksum, 16); central.writeUInt32LE(body.length, 20); central.writeUInt32LE(body.length, 24); central.writeUInt16LE(name.length, 28);
  const directoryOffset = local.length + name.length + body.length;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(central.length + name.length, 12); end.writeUInt32LE(directoryOffset, 16);
  return Buffer.concat([local, name, body, central, name, end]);
}

(async () => {
  const extracted = await parser.extractDocumentXml(storedDocx(xml));
  assert.match(extracted, /高等数学/, "应从真实 DOCX ZIP 结构中读取 document.xml");
  console.log("Word DOCX 课表检查通过：DOCX 解包、表格、星期、节次、纵向合并、教师、教室与周次均可识别。");
})().catch((error) => { console.error(error); process.exitCode = 1; });
