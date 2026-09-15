(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.DocxScheduleParser = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const WEEKDAY_PATTERNS = [/[周星]期?一/, /[周星]期?二/, /[周星]期?三/, /[周星]期?四/, /[周星]期?五/, /[周星]期?六/, /[周星]期?[日天]/];
  const COURSE_COLORS = ["#5B8DEF", "#E66A6A", "#E0A22B", "#54A77B", "#8C6EDB", "#3C9DA7", "#D2699E", "#6D7C8E"];

  function decodeXml(value) {
    return String(value || "")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
      .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)));
  }

  function plainCellText(xml) {
    const paragraphs = String(xml).split(/<\/w:p>/i).map((paragraph) => [...paragraph.matchAll(/<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/gi)].map((match) => decodeXml(match[1])).join(""));
    return paragraphs.map((item) => item.replace(/\s+/g, " ").trim()).filter(Boolean).join(" / ");
  }

  function tableRows(xml) {
    const tables = [...String(xml).matchAll(/<w:tbl(?:\s[^>]*)?>([\s\S]*?)<\/w:tbl>/gi)];
    return tables.map((table) => {
      const vertical = [];
      return [...table[1].matchAll(/<w:tr(?:\s[^>]*)?>([\s\S]*?)<\/w:tr>/gi)].map((row) => {
        const expanded = [];
        [...row[1].matchAll(/<w:tc(?:\s[^>]*)?>([\s\S]*?)<\/w:tc>/gi)].forEach((cellMatch) => {
          const cellXml = cellMatch[1];
          const span = Math.max(1, Number(cellXml.match(/<w:gridSpan[^>]*w:val="(\d+)"/i)?.[1] || 1));
          const mergeTag = cellXml.match(/<w:vMerge(?:\s[^>]*)?\/?\s*>/i)?.[0] || "";
          const mergeRestart = /w:val="restart"/i.test(mergeTag);
          const mergeContinue = Boolean(mergeTag) && !mergeRestart;
          let text = plainCellText(cellXml);
          for (let offset = 0; offset < span; offset += 1) {
            const column = expanded.length;
            if (mergeContinue && !text) text = vertical[column] || "";
            expanded.push(text);
            if (mergeRestart || mergeContinue) vertical[column] = text;
            else vertical[column] = "";
          }
        });
        return expanded;
      });
    });
  }

  function weekdayFor(text) {
    return WEEKDAY_PATTERNS.findIndex((pattern) => pattern.test(String(text || ""))) + 1;
  }

  function parseSection(text) {
    const value = String(text || "");
    const range = value.match(/第?\s*(\d{1,2})\s*(?:[-—~～至]\s*(\d{1,2})\s*)?节/);
    if (!range) return null;
    return { start: Number(range[1]), end: Number(range[2] || range[1]) };
  }

  function parseTime(text) {
    const match = String(text || "").match(/([01]?\d|2[0-3])[:：](\d{2})\s*(?:[-—~～至]\s*)([01]?\d|2[0-3])[:：](\d{2})/);
    if (!match) return null;
    return { startTime: `${String(match[1]).padStart(2, "0")}:${match[2]}`, endTime: `${String(match[3]).padStart(2, "0")}:${match[4]}` };
  }

  function parseWeeks(text, totalWeeks) {
    const result = new Set();
    const value = String(text || "");
    for (const match of value.matchAll(/(\d{1,2})\s*(?:[-—~～至]\s*(\d{1,2}))?\s*周/g)) {
      const start = Math.max(1, Number(match[1]));
      const end = Math.min(Number(totalWeeks) || 20, Number(match[2] || match[1]));
      for (let week = start; week <= end; week += 1) result.add(week);
    }
    const parity = /单周/.test(value) ? 1 : /双周/.test(value) ? 0 : null;
    let weeks = [...result].sort((a, b) => a - b);
    if (!weeks.length) weeks = Array.from({ length: Number(totalWeeks) || 20 }, (_, index) => index + 1);
    if (parity !== null) weeks = weeks.filter((week) => week % 2 === parity);
    return { weeks, inferred: result.size === 0 };
  }

  function courseFromCell(text, context) {
    const cleaned = String(text || "").replace(/\s+/g, " ").replace(/^[-—/\s]+|[-—/\s]+$/g, "").trim();
    if (!cleaned || /^(无|空|选课|休息|午休|课程名称)$/.test(cleaned)) return null;
    const parts = cleaned.split(/\s*[／/]\s*/).map((part) => part.trim()).filter(Boolean);
    let name = (parts[0] || cleaned).replace(/^(?:本|研|专)?[（(][^）)]{1,14}[）)]\s*/, "").trim();
    name = name.replace(/\s*(?:\d{1,2}\s*(?:[-—~～至]\s*\d{1,2})?\s*周.*)$/g, "").trim();
    if (!name || name.length > 80) return null;
    const location = parts.find((part) => /(校区|校园|教学楼|教室|实验室|体育馆|馆|楼|室|堂|C\d|E\d|H\d)/i.test(part)) || "";
    const teacher = parts.slice(1).find((part) => part !== location && /^[\u4e00-\u9fa5·]{2,12}$/.test(part)) || "";
    const weekInfo = parseWeeks(cleaned, context.totalWeeks);
    return {
      name, code: "", campus: location.match(/([^/（(]*?(?:校区|校园))/)?.[1] || "", teacher, location,
      day: context.day, startSection: context.section.start, endSection: context.section.end,
      color: COURSE_COLORS[context.colorIndex % COURSE_COLORS.length], weeks: weekInfo.weeks,
      reminderMinutes: 10,
      notes: `由 Word DOCX 课表导入${weekInfo.inferred ? "；原表未识别到周次，暂按全学期" : ""}`,
      importWarnings: weekInfo.inferred ? ["未识别到周次，暂按全学期"] : []
    };
  }

  function parseScheduleDocumentXml(xml, options = {}) {
    const totalWeeks = Math.max(1, Number(options.totalWeeks) || 20);
    const courses = [];
    const slots = new Map();
    const warnings = [];
    tableRows(xml).forEach((rows, tableIndex) => {
      let weekdayColumns = new Map();
      const headerIndex = rows.findIndex((row) => row.filter((cell) => weekdayFor(cell)).length >= 3);
      if (headerIndex >= 0) rows[headerIndex].forEach((cell, column) => { const day = weekdayFor(cell); if (day) weekdayColumns.set(column, day); });
      rows.slice(Math.max(0, headerIndex + 1)).forEach((row) => {
        const sectionCellIndex = row.findIndex((cell) => parseSection(cell));
        if (sectionCellIndex < 0) return;
        const section = parseSection(row[sectionCellIndex]);
        const time = parseTime(row.join(" "));
        if (time) for (let number = section.start; number <= section.end; number += 1) slots.set(number, { number, ...time });
        let columns = weekdayColumns;
        if (!columns.size && row.length - sectionCellIndex - 1 >= 5) {
          columns = new Map();
          row.slice(sectionCellIndex + 1, sectionCellIndex + 8).forEach((_, index) => columns.set(sectionCellIndex + 1 + index, index + 1));
        }
        columns.forEach((day, column) => {
          const course = courseFromCell(row[column], { totalWeeks, day, section, colorIndex: courses.length });
          if (course) courses.push(course);
        });
      });
      if (headerIndex < 0 && !courses.length) warnings.push(`第 ${tableIndex + 1} 个表格没有识别到星期表头`);
    });
    const merged = [];
    courses.forEach((course) => {
      const previous = merged.find((item) => item.name === course.name && item.day === course.day && item.location === course.location && item.endSection + 1 === course.startSection && JSON.stringify(item.weeks) === JSON.stringify(course.weeks));
      if (previous) previous.endSection = course.endSection;
      else if (!merged.some((item) => item.name === course.name && item.day === course.day && item.startSection === course.startSection && item.endSection === course.endSection && item.location === course.location)) merged.push(course);
    });
    if (!merged.length) warnings.push("没有从 Word 表格中识别到课程，请确认文档包含星期表头和节次行");
    return { courses: merged, timeSlots: [...slots.values()].sort((a, b) => a.number - b.number), warnings };
  }

  async function inflateRaw(bytes) {
    if (typeof DecompressionStream !== "undefined") {
      const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return new Uint8Array(await new Response(stream).arrayBuffer());
    }
    throw new Error("当前浏览器不支持解压 DOCX，请升级浏览器或把表格另存为文本后导入");
  }

  async function extractDocumentXml(arrayBuffer) {
    const bytes = new Uint8Array(arrayBuffer);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let eocd = -1;
    for (let offset = bytes.length - 22; offset >= Math.max(0, bytes.length - 65557); offset -= 1) {
      if (view.getUint32(offset, true) === 0x06054b50) { eocd = offset; break; }
    }
    if (eocd < 0) throw new Error("文件不是有效的 DOCX 压缩包");
    const entries = view.getUint16(eocd + 10, true);
    let offset = view.getUint32(eocd + 16, true);
    const decoder = new TextDecoder("utf-8");
    for (let index = 0; index < entries && offset + 46 <= bytes.length; index += 1) {
      if (view.getUint32(offset, true) !== 0x02014b50) break;
      const method = view.getUint16(offset + 10, true);
      const compressedSize = view.getUint32(offset + 20, true);
      const nameLength = view.getUint16(offset + 28, true);
      const extraLength = view.getUint16(offset + 30, true);
      const commentLength = view.getUint16(offset + 32, true);
      const localOffset = view.getUint32(offset + 42, true);
      const name = decoder.decode(bytes.slice(offset + 46, offset + 46 + nameLength));
      if (name === "word/document.xml") {
        if (view.getUint32(localOffset, true) !== 0x04034b50) throw new Error("DOCX 文档结构损坏");
        const localNameLength = view.getUint16(localOffset + 26, true);
        const localExtraLength = view.getUint16(localOffset + 28, true);
        const dataOffset = localOffset + 30 + localNameLength + localExtraLength;
        const compressed = bytes.slice(dataOffset, dataOffset + compressedSize);
        const content = method === 0 ? compressed : method === 8 ? await inflateRaw(compressed) : null;
        if (!content) throw new Error(`不支持 DOCX 压缩方式 ${method}`);
        return decoder.decode(content);
      }
      offset += 46 + nameLength + extraLength + commentLength;
    }
    throw new Error("DOCX 中没有找到 word/document.xml");
  }

  async function parseDocx(arrayBuffer, options = {}) {
    return parseScheduleDocumentXml(await extractDocumentXml(arrayBuffer), options);
  }

  return { parseDocx, extractDocumentXml, parseScheduleDocumentXml, parseWeeks, parseSection, parseTime };
});
