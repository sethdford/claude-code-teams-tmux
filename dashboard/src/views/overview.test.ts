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

const OVERVIEW_IDS = [
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
  "success-rate-7d",
  "success-rate-trend",
  "success-rate-30d",
  "success-rate-failures",
  "success-rate-alert",
  "success-rate-breakdown",
  "success-rate-card",
  "success-rate-widget",
];

function createOverviewDOM(): void {
  for (const id of OVERVIEW_IDS) {
    if (!document.getElementById(id)) {
      const el = document.createElement("div");
      el.id = id;
      document.body.appendChild(el);
    }
  }
}

function cleanupOverviewDOM(): void {
  OVERVIEW_IDS.forEach((id) => document.getElementById(id)?.remove());
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

  it("renders success rate with no data", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const valueEl = document.getElementById("success-rate-7d");
    expect(valueEl).toBeTruthy();
    expect(valueEl!.textContent).toBe("—");
  });

  it("renders success rate when successRate is provided", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data.metrics as any).successRate = {
      rate_7d: 85,
      rate_30d: 80,
      trend: "up",
      total_7d: 10,
      total_30d: 20,
      succeeded_7d: 8,
      succeeded_30d: 16,
      consecutive_failures: 0,
      alert: false,
      breakdown: [
        { template: "fast", succeeded: 5, failed: 1, rate: 83 },
        { template: "standard", succeeded: 3, failed: 1, rate: 75 },
      ],
    };
    overviewView.render(data);
    const valueEl = document.getElementById("success-rate-7d");
    expect(valueEl!.textContent).toBe("85%");
    expect(valueEl!.className).toContain("rate-green");
    const trendEl = document.getElementById("success-rate-trend");
    expect(trendEl!.className).toContain("trend-up");
    const secondaryEl = document.getElementById("success-rate-30d");
    expect(secondaryEl!.textContent).toBe("30d: 80%");
    const alertEl = document.getElementById("success-rate-alert");
    expect(alertEl!.style.display).toBe("none");
  });

  it("renders amber color for 60-80% rate", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data.metrics as any).successRate = {
      rate_7d: 70,
      rate_30d: 75,
      trend: "stable",
      total_7d: 10,
      total_30d: 20,
      succeeded_7d: 7,
      succeeded_30d: 15,
      consecutive_failures: 0,
      alert: false,
      breakdown: [],
    };
    overviewView.render(data);
    const valueEl = document.getElementById("success-rate-7d");
    expect(valueEl!.className).toContain("rate-amber");
  });

  it("renders rose color for rate < 60%", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data.metrics as any).successRate = {
      rate_7d: 40,
      rate_30d: 50,
      trend: "down",
      total_7d: 10,
      total_30d: 20,
      succeeded_7d: 4,
      succeeded_30d: 10,
      consecutive_failures: 3,
      alert: true,
      breakdown: [],
    };
    overviewView.render(data);
    const valueEl = document.getElementById("success-rate-7d");
    expect(valueEl!.className).toContain("rate-rose");
    const failuresEl = document.getElementById("success-rate-failures");
    expect(failuresEl!.style.display).not.toBe("none");
    expect(failuresEl!.textContent).toContain("3 consecutive fails");
    const alertEl = document.getElementById("success-rate-alert");
    expect(alertEl!.style.display).not.toBe("none");
  });

  it("renders breakdown rows when breakdown data exists", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data.metrics as any).successRate = {
      rate_7d: 90,
      rate_30d: 85,
      trend: "up",
      total_7d: 10,
      total_30d: 20,
      succeeded_7d: 9,
      succeeded_30d: 17,
      consecutive_failures: 0,
      alert: false,
      breakdown: [
        { template: "fast", succeeded: 5, failed: 0, rate: 100 },
        { template: "standard", succeeded: 4, failed: 1, rate: 80 },
      ],
    };
    overviewView.render(data);
    const breakdownEl = document.getElementById("success-rate-breakdown");
    expect(breakdownEl).toBeTruthy();
    expect(breakdownEl!.innerHTML).toContain("fast");
    expect(breakdownEl!.innerHTML).toContain("standard");
    expect(breakdownEl!.innerHTML).toContain("breakdown-row");
  });

  it("shows trend down arrow", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data.metrics as any).successRate = {
      rate_7d: 50,
      rate_30d: 80,
      trend: "down",
      total_7d: 10,
      total_30d: 20,
      succeeded_7d: 5,
      succeeded_30d: 16,
      consecutive_failures: 2,
      alert: true,
      breakdown: [],
    };
    overviewView.render(data);
    const trendEl = document.getElementById("success-rate-trend");
    expect(trendEl!.className).toContain("trend-down");
    expect(trendEl!.textContent).toBe("\u2193");
  });
});
