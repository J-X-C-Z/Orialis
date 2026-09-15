const assert = require("node:assert/strict");
<<<<<<< HEAD
const { SCHEMA, VERSION, buildMockSnapshot, buildSnapshot, validateSnapshot } = require("./link-contract");
=======
const { SCHEMA, VERSION, buildMockSnapshot, buildSnapshot } = require("./link-contract");
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

const mock = buildMockSnapshot();
assert.equal(mock.schema, SCHEMA);
assert.equal(mock.version, VERSION);
assert.equal(mock.dataState, "mock");
assert.equal(mock.sync.mode, "pull-only");
assert.equal(mock.sync.canWrite, false);
assert.ok(Array.isArray(mock.payload.tasks.items));
assert.ok(Array.isArray(mock.payload.schedule.items));
<<<<<<< HEAD
assert.ok(Array.isArray(mock.payload.projects.items));
assert.equal(validateSnapshot(mock), true);
assert.equal(validateSnapshot({ ...mock, schema: "invalid" }), false);
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

const empty = buildSnapshot({ dataState: "empty" });
assert.equal(empty.payload.tasks.pendingCount, 0);
assert.equal(empty.payload.schedule.items.length, 0);
<<<<<<< HEAD
assert.equal(empty.payload.projects.count, 0);
assert.equal(empty.sync.cursor, null);
assert.equal(validateSnapshot(empty), true);

const projectSnapshot = buildSnapshot({
  dataState: "live",
  revision: 4,
  document: {
    tasks: [{ id: "action-1", title: "推进实验", projectId: "project-1", completed: false }],
    projects: [{ id: "project-1", name: "毕业设计", milestones: [{ id: "m-1", title: "完成开题", completed: true }] }],
    courses: [],
  },
});
assert.equal(projectSnapshot.payload.projects.items[0].name, "毕业设计");
assert.equal(projectSnapshot.payload.projects.items[0].progress.percent, 50);
assert.equal(projectSnapshot.payload.projects.items[0].pendingActions[0].title, "推进实验");
=======
assert.equal(empty.sync.cursor, null);
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
console.log("link-contract-smoke: ok");
