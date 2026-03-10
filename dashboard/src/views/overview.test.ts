import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { store } from "../core/state";
import type { FleetState } from "../types/api";

vi.mock("../core/api", () => ({
  fetchQueueDetailed: vi.fn().mockResolvedValue({ items: [] }),
}));

vi.mock("./pipelines", () => ({
  fetchPipelineDetail: vi.fn(),
}));

vi.mock("../components/header", () => ({
  renderCostTicker: vi.fn(),
}));

function createOverviewDOM(): void {
  const ids = [
    "stat-status",
    "status-dot",
    "stat-active",
    "stat-active-bar",
    "stat-queue",
    "stat-queue-sub",
    "stat-completed",
    "stat-failed-sub",
    "active-pipelines",
    "queue-list",
    "activity-feed",
    "res-cpu-bar",
    "res-cpu-info",
    "res-mem-bar",
    "res-mem-info",
    "res-budget-bar",
    "res-budget-info",
    "resource-constraint",
    "machines-section",
    "machines-grid",
  ];
  for (const id of ids) {
    if (!document.getElementById(id)) {
      const el = document.createElement("div");
      el.id = id;
      document.body.appendChild(el);
    }
  }
}

function cleanupOverviewDOM(): void {
  const ids = [
    "stat-status",
    "status-dot",
    "stat-active",
    "stat-active-bar",
    "stat-queue",
    "stat-queue-sub",
    "stat-completed",
    "stat-failed-sub",
    "active-pipelines",
    "queue-list",
    "activity-feed",
    "res-cpu-bar",
    "res-cpu-info",
    "res-mem-bar",
    "res-mem-info",
    "res-budget-bar",
    "res-budget-info",
    "resource-constraint",
    "machines-section",
    "machines-grid",
  ];
  ids.forEach((id) => document.getElementById(id)?.remove());
}

function emptyFleetState(): FleetState {
  return {
    timestamp: new Date().toISOString(),
    daemon: {
      running: false,
      pid: null,
      uptime_s: 0,
      maxParallel: 0,
      pollInterval: 5,
    },
    pipelines: [],
    queue: [],
    events: [],
    scale: {},
    metrics: {},
    agents: [],
    machines: [],
    cost: { today_spent: 0, daily_budget: 0, pct_used: 0 },
    dora: {} as any,
  };
}

describe("OverviewView", () => {
  beforeEach(() => {
    store.set("firstRender", false);
    createOverviewDOM();
  });

  afterEach(() => {
    cleanupOverviewDOM();
    vi.clearAllMocks();
  });

  it("renders without crashing when given empty data", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    expect(() => overviewView.render(data)).not.toThrow();
  });

  it("renders pipeline summary section with empty pipelines", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).toContain("No active pipelines");
  });

  it("renders pipeline cards when pipelines exist", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 42,
        title: "Fix bug",
        stage: "code",
        stagesDone: ["plan"],
        elapsed_s: 120,
        iteration: 2,
        maxIterations: 20,
      },
    ];
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).toContain("#42");
    expect(container!.innerHTML).toContain("Fix bug");
    expect(container!.innerHTML).toContain("pipeline-card");
  });

  it("handles null/undefined state gracefully", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data as any).pipelines = null;
    (data as any).queue = undefined;
    (data as any).events = undefined;
    expect(() => overviewView.render(data)).not.toThrow();
    const pipelinesEl = document.getElementById("active-pipelines");
    expect(pipelinesEl!.innerHTML).toContain("No active pipelines");
  });

  it("renders queue empty state", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const queueEl = document.getElementById("queue-list");
    expect(queueEl).toBeTruthy();
    expect(queueEl!.innerHTML).toContain("Queue clear");
  });

  it("renders activity empty state", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const activityEl = document.getElementById("activity-feed");
    expect(activityEl).toBeTruthy();
    expect(activityEl!.innerHTML).toContain("Awaiting events");
  });

  it("renders build loop metrics widget when buildLoop data present", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 99,
        title: "Feature work",
        stage: "build",
        stagesDone: ["plan"],
        elapsed_s: 600,
        iteration: 5,
        maxIterations: 20,
        buildLoop: {
          iteration: 5,
          maxIterations: 20,
          status: "running",
          testStatus: "passing",
          testPassStreak: 3,
          testFailStreak: 0,
          filesChangedCount: 12,
          totalCommits: 4,
          contextUsagePercent: 25,
          timeElapsedS: 600,
          consecutiveLowProgress: 0,
          model: "opus",
          goal: "Build feature",
          timestamp: "2026-03-10T16:00:00Z",
          linesWritten: 12,
          testsPassing: true,
        },
      } as any,
    ];
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).toContain("build-loop-metrics");
    expect(container!.innerHTML).toContain("passing");
    expect(container!.innerHTML).toContain("improving");
    expect(container!.innerHTML).toContain("opus");
  });

  it("renders pipeline card without build loop when buildLoop is absent", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 100,
        title: "Quick fix",
        stage: "build",
        stagesDone: [],
        elapsed_s: 30,
        iteration: 1,
        maxIterations: 10,
      },
    ];
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).not.toContain("build-loop-metrics");
    expect(container!.innerHTML).toContain("#100");
  });

  it("shows degrading trend when test fail streak is high", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 101,
        title: "Failing build",
        stage: "build",
        stagesDone: [],
        elapsed_s: 900,
        iteration: 8,
        maxIterations: 20,
        buildLoop: {
          iteration: 8,
          maxIterations: 20,
          status: "running",
          testStatus: "failing",
          testPassStreak: 0,
          testFailStreak: 3,
          filesChangedCount: 5,
          totalCommits: 2,
          contextUsagePercent: 40,
          timeElapsedS: 900,
          consecutiveLowProgress: 2,
          model: "sonnet",
          goal: "Fix tests",
          timestamp: "2026-03-10T16:15:00Z",
          linesWritten: 5,
          testsPassing: false,
        },
      } as any,
    ];
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container!.innerHTML).toContain("degrading");
    expect(container!.innerHTML).toContain("failing");
  });
});
