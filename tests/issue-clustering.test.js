// Unit tests for the Semantic Issue Clustering Engine.
// Uses Node's built-in test runner (node:test) so it runs with zero install
// footprint, matching the engine's dependency-free design:
//   node --test tests/issue-clustering.test.js
const { test } = require("node:test");
const assert = require("node:assert");
const {
  tokenize,
  extractIssues,
  cosineSim,
  buildTfIdf,
  confidenceTier,
  clusterIssues,
  matchIssueToCluster,
  DEFAULT_TIERS,
} = require("../src/issue-clustering");

const DAEMON_ISSUES = [
  {
    issue_id: "1",
    title: "API timeout in auth daemon",
    description: "daemon crashes with SIGKILL after timeout",
    files: ["scripts/sw-daemon.sh"],
    success: true,
  },
  {
    issue_id: "2",
    title: "timeout in auth middleware daemon",
    description: "SIGKILL timeout crash on daemon",
    files: ["scripts/sw-daemon.sh"],
    success: true,
  },
  {
    issue_id: "3",
    title: "auth daemon timeout SIGKILL",
    description: "daemon timeout crash",
    files: ["scripts/sw-daemon.sh"],
    success: false,
  },
];
const DASHBOARD_ISSUES = [
  {
    issue_id: "4",
    title: "add dark mode to dashboard css",
    description: "styling colors theme dashboard frontend",
    files: ["dashboard/public/style.css"],
    success: true,
  },
  {
    issue_id: "5",
    title: "dashboard dark theme css colors styling",
    description: "frontend theme dark mode",
    files: ["dashboard/public/style.css"],
    success: true,
  },
];
const ALL = [...DAEMON_ISSUES, ...DASHBOARD_ISSUES];

// ─── tokenize ───────────────────────────────────────────────────────────────
test("tokenize: lowercases and strips punctuation/stopwords", () => {
  assert.deepStrictEqual(tokenize("The API Timeout, on Daemon!"), [
    "api",
    "timeout",
    "daemon",
  ]);
});
test("tokenize: handles empty / non-string input", () => {
  assert.deepStrictEqual(tokenize(""), []);
  assert.deepStrictEqual(tokenize(null), []);
  assert.deepStrictEqual(tokenize(42), []);
});

// ─── extractIssues ───────────────────────────────────────────────────────────
test("extractIssues: merges events by id and resolves outcome", () => {
  const issues = extractIssues([
    { issue_id: "x", title: "boom", files: ["a.sh"] },
    {
      issue_id: "x",
      description: "more detail",
      success: true,
      files: ["b.sh"],
    },
  ]);
  assert.strictEqual(issues.length, 1);
  assert.strictEqual(issues[0].id, "x");
  assert.strictEqual(issues[0].success, true);
  assert.deepStrictEqual(issues[0].files.sort(), ["a.sh", "b.sh"]);
});
test("extractIssues: returns [] for non-array input", () => {
  assert.deepStrictEqual(extractIssues(null), []);
  assert.deepStrictEqual(extractIssues({}), []);
});
test("extractIssues: drops events with no text", () => {
  assert.deepStrictEqual(extractIssues([{ issue_id: "e" }]), []);
});

// ─── cosineSim ───────────────────────────────────────────────────────────────
test("cosineSim: identical vectors → 1", () => {
  const [v] = buildTfIdf([tokenize("daemon timeout crash")]);
  assert.ok(Math.abs(cosineSim(v, v) - 1) < 1e-9);
});
test("cosineSim: disjoint vectors → 0", () => {
  const [a, b] = buildTfIdf([
    tokenize("daemon timeout"),
    tokenize("banana xylophone"),
  ]);
  assert.strictEqual(cosineSim(a, b), 0);
});
test("cosineSim: empty maps → 0", () => {
  assert.strictEqual(cosineSim(new Map(), new Map([["x", 1]])), 0);
});

// ─── confidenceTier ──────────────────────────────────────────────────────────
test("confidenceTier: maps scores to tiers using defaults", () => {
  assert.strictEqual(confidenceTier(0.9, DEFAULT_TIERS), "high");
  assert.strictEqual(confidenceTier(0.75, DEFAULT_TIERS), "medium");
  assert.strictEqual(confidenceTier(0.55, DEFAULT_TIERS), "low");
  assert.strictEqual(confidenceTier(0.2, DEFAULT_TIERS), "none");
});

// ─── clusterIssues ───────────────────────────────────────────────────────────
test("clusterIssues: separates topically distinct issues into 2 clusters", () => {
  const doc = clusterIssues(extractIssues(ALL), {
    threshold: 0.15,
    generatedAt: "T",
  });
  assert.strictEqual(doc.clusters.length, 2);
  assert.deepStrictEqual(doc.clusters.map((c) => c.size).sort(), [2, 3]);
});
test("clusterIssues: computes success_rate from outcomes", () => {
  const doc = clusterIssues(extractIssues(DAEMON_ISSUES), {
    threshold: 0.15,
    generatedAt: "T",
  });
  assert.ok(
    Math.abs(doc.clusters[0].success_metrics.success_rate - 2 / 3) < 1e-9,
  );
});
test("clusterIssues: respects minClusterSize", () => {
  const doc = clusterIssues(extractIssues(DAEMON_ISSUES), {
    threshold: 0.15,
    minClusterSize: 5,
    generatedAt: "T",
  });
  assert.strictEqual(doc.clusters.length, 0);
});
test("clusterIssues: empty input yields a valid empty document", () => {
  const doc = clusterIssues([], { generatedAt: "T" });
  assert.deepStrictEqual(doc.clusters, []);
  assert.strictEqual(doc.metadata.total_issues_processed, 0);
  assert.ok(doc.version);
});
test("clusterIssues: assigns stable padded cluster ids", () => {
  const doc = clusterIssues(extractIssues(ALL), {
    threshold: 0.15,
    generatedAt: "T",
  });
  assert.strictEqual(doc.clusters[0].id, "cluster-001");
});

// ─── matchIssueToCluster ─────────────────────────────────────────────────────
test("matchIssueToCluster: matches a new issue to the nearest cluster", () => {
  const doc = clusterIssues(extractIssues(ALL), {
    threshold: 0.15,
    generatedAt: "T",
  });
  const daemonId = doc.clusters.find((c) => c.issue_ids.includes("1")).id;
  const m = matchIssueToCluster(
    { title: "daemon timeout SIGKILL auth crash" },
    doc,
    0.1,
  );
  assert.ok(m);
  assert.strictEqual(m.cluster_id, daemonId);
  assert.ok(m.confidence_tier);
  assert.ok(m.similarity_score > 0.1);
});
test("matchIssueToCluster: returns null when nothing exceeds threshold", () => {
  const doc = clusterIssues(extractIssues(ALL), {
    threshold: 0.15,
    generatedAt: "T",
  });
  assert.strictEqual(
    matchIssueToCluster({ title: "quantum banana xylophone" }, doc, 0.9),
    null,
  );
});
test("matchIssueToCluster: returns null for empty cluster document", () => {
  assert.strictEqual(
    matchIssueToCluster({ title: "x" }, { clusters: [] }, 0.1),
    null,
  );
});
test("matchIssueToCluster: returns null for an issue with no tokens", () => {
  const doc = clusterIssues(extractIssues(ALL), {
    threshold: 0.15,
    generatedAt: "T",
  });
  assert.strictEqual(matchIssueToCluster({ title: "" }, doc, 0.1), null);
});
