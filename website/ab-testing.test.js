const assert = require("node:assert/strict");
const test = require("node:test");

const {
  EXPERIMENT_ID,
  assignedVariant,
  createClient,
  debugOverride,
  fnv1a32,
  resolveAssignment,
} = require("./ab-testing.js");

function memoryStorage(initialValues = {}) {
  const values = new Map(Object.entries(initialValues));

  return {
    getItem(key) {
      return values.has(key) ? values.get(key) : null;
    },
    removeItem(key) {
      values.delete(key);
    },
    setItem(key, value) {
      values.set(key, String(value));
    },
  };
}

test("FNV-1a fixtures remain compatible with the Swift implementation", () => {
  assert.equal(
    fnv1a32(
      "website.hero-repository-cta-copy.v1:" +
        "00000000-0000-4000-8000-000000000000",
    ),
    1404061537,
  );
  assert.equal(
    fnv1a32("macos.popup-empty-state-guidance.v1:1"),
    1564713247,
  );
});

test("assignment splits fixed subjects into control and treatment", () => {
  assert.equal(
    assignedVariant(
      EXPERIMENT_ID,
      "00000000-0000-4000-8000-000000000000",
    ),
    "control",
  );
  assert.equal(assignedVariant(EXPERIMENT_ID, "1"), "treatment");
});

test("a stored assignment remains sticky", () => {
  const storage = memoryStorage({
    "semper.ab.subject.v1": "1",
    [`semper.ab.assignment.${EXPERIMENT_ID}`]: "control",
  });

  const assignment = resolveAssignment({
    experimentID: EXPERIMENT_ID,
    storage,
    search: "",
    makeUUID: () => "unused",
  });

  assert.equal(assignment.variant, "control");
  assert.equal(assignment.source, "bucket");
});

test("a debug override is scoped to the requested experiment", () => {
  assert.equal(
    debugOverride(
      `?semper_ab=${EXPERIMENT_ID}:treatment`,
      EXPERIMENT_ID,
    ),
    "treatment",
  );
  assert.equal(
    debugOverride("?semper_ab=another-experiment:control", EXPERIMENT_ID),
    null,
  );
  assert.equal(
    debugOverride(`?semper_ab=${EXPERIMENT_ID}:unknown`, EXPERIMENT_ID),
    null,
  );
});

test("a debug override is not saved as the sticky assignment", () => {
  const storage = memoryStorage({
    "semper.ab.subject.v1": "1",
  });

  const forced = resolveAssignment({
    experimentID: EXPERIMENT_ID,
    storage,
    search: `?semper_ab=${EXPERIMENT_ID}:control`,
    makeUUID: () => "unused",
  });
  const bucketed = resolveAssignment({
    experimentID: EXPERIMENT_ID,
    storage,
    search: "",
    makeUUID: () => "unused",
  });

  assert.equal(forced.variant, "control");
  assert.equal(forced.source, "debug_override");
  assert.equal(bucketed.variant, "treatment");
  assert.equal(bucketed.source, "bucket");
});

test("events are local, ordered, and emitted once per metric", () => {
  const events = [];
  let uuidIndex = 0;
  const client = createClient({
    experimentID: EXPERIMENT_ID,
    storage: memoryStorage({
      "semper.ab.subject.v1": "1",
    }),
    makeUUID: () => `uuid-${(uuidIndex += 1)}`,
    emit: (event) => events.push(event),
    now: () => new Date("2026-07-31T12:00:00.000Z"),
  });

  assert.equal(client.recordOutcome("hero_repository_clicked"), false);
  assert.equal(client.recordExposure(), true);
  assert.equal(client.recordExposure(), false);
  assert.equal(client.recordOutcome("hero_repository_clicked"), true);
  assert.equal(client.recordOutcome("hero_repository_clicked"), false);

  assert.deepEqual(
    events.map((event) => [event.event_name, event.metric_key]),
    [
      ["experiment_exposure", null],
      ["experiment_outcome", "hero_repository_clicked"],
    ],
  );
  assert.equal(events[0].collection_mode, "local");
  assert.equal(events[0].surface, "website");
  assert.equal(events[0].subject_id, "1");
  assert.equal("path" in events[0], false);
  assert.equal("referrer" in events[0], false);
});

test("missing storage keeps the visitor in control", () => {
  const assignment = resolveAssignment({
    experimentID: EXPERIMENT_ID,
    storage: null,
    search: "",
    makeUUID: () => "ephemeral-subject",
  });

  assert.equal(assignment.variant, "control");
  assert.equal(assignment.source, "fallback");
});
