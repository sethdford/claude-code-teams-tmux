// Analytics tab - pipeline success rates, failure attribution, trends

import { escapeHtml } from "../core/helpers";
import type { FleetState, View } from "../types/api";

interface AnalyticsData {
  period_days: number;
  generated_at: string;
  summary: {
    total_runs: number;
    successful: number;
    failed: number;
    success_rate: number;
    avg_duration_secs: number;
    total_cost_usd: number;
  };
  by_template: Array<{
    template: string;
    total: number;
    successful: number;
    failed: number;
    success_rate: number;
    avg_duration_secs: number;
  }>;
  by_stage_failure: Array<{
    stage_name: string;
    failure_count: number;
    pct_of_failures: number;
  }>;
  by_complexity: Array<{
    complexity: string;
    total: number;
    successful: number;
    success_rate: number;
  }>;
  by_hour: Array<{
    hour: number;
    total: number;
    successful: number;
    success_rate: number;
  }>;
  trends: {
    periods: Array<{
      label: string;
      total: number;
      success_rate: number;
      avg_duration_secs: number;
    }>;
  };
  active_pipelines: Array<{
    job_id: string;
    issue_number: number;
    goal: string;
    template: string;
    current_stage: string;
    started_at: string;
    elapsed_secs: number;
  }>;
}

let analyticsData: AnalyticsData | null = null;
let currentPeriod = 7;
let refreshTimer: ReturnType<typeof setInterval> | null = null;

function fetchAnalytics(period: number): void {
  fetch(`/api/analytics?period=${period}`)
    .then((r) => r.json())
    .then((data: AnalyticsData) => {
      analyticsData = data;
      renderAnalytics();
    })
    .catch(() => {});
}

function renderAnalytics(): void {
  const panel = document.getElementById("analytics-content");
  if (!panel || !analyticsData) return;

  const d = analyticsData;
  const s = d.summary;

  // Rate color
  let rateClass = "c-green";
  if (s.success_rate < 50) rateClass = "c-red";
  else if (s.success_rate < 80) rateClass = "c-amber";

  let html = "";

  // Period selector
  html += `<div class="analytics-toolbar">
    <div class="analytics-period-btns">
      <button class="period-btn ${currentPeriod === 7 ? "active" : ""}" data-period="7">7 days</button>
      <button class="period-btn ${currentPeriod === 30 ? "active" : ""}" data-period="30">30 days</button>
      <button class="period-btn ${currentPeriod === 90 ? "active" : ""}" data-period="90">90 days</button>
    </div>
  </div>`;

  // Summary cards
  html += `<div class="analytics-summary">
    <div class="analytics-card"><div class="stat-value">${s.total_runs}</div><div class="stat-label">Total Runs</div></div>
    <div class="analytics-card"><div class="stat-value c-green">${s.successful}</div><div class="stat-label">Successful</div></div>
    <div class="analytics-card"><div class="stat-value c-red">${s.failed}</div><div class="stat-label">Failed</div></div>
    <div class="analytics-card"><div class="stat-value ${rateClass}">${s.success_rate}%</div><div class="stat-label">Success Rate</div></div>
    <div class="analytics-card"><div class="stat-value">${formatDuration(s.avg_duration_secs)}</div><div class="stat-label">Avg Duration</div></div>
    <div class="analytics-card"><div class="stat-value">$${s.total_cost_usd.toFixed(2)}</div><div class="stat-label">Total Cost</div></div>
  </div>`;

  if (s.total_runs === 0) {
    html += `<div class="empty-state"><p>No pipeline data for the last ${d.period_days} days.</p></div>`;
    panel.innerHTML = html;
    wireUpPeriodButtons(panel);
    return;
  }

  // Trends
  if (d.trends.periods.length > 0) {
    html += `<div class="analytics-section"><h3>Trends</h3><div class="analytics-trends">`;
    for (const t of d.trends.periods) {
      let tClass = "c-green";
      if (t.success_rate < 50) tClass = "c-red";
      else if (t.success_rate < 80) tClass = "c-amber";
      html += `<div class="analytics-trend-card">
        <div class="trend-label">${escapeHtml(t.label)}</div>
        <div class="trend-rate ${tClass}">${t.success_rate}%</div>
        <div class="trend-detail">${t.total} runs &middot; ${formatDuration(t.avg_duration_secs)} avg</div>
      </div>`;
    }
    html += `</div></div>`;
  }

  // By Template
  if (d.by_template.length > 0) {
    html += `<div class="analytics-section"><h3>By Template</h3><table class="analytics-table">
      <thead><tr><th>Template</th><th>Total</th><th>Pass</th><th>Fail</th><th>Rate</th><th>Avg Duration</th></tr></thead><tbody>`;
    for (const t of d.by_template) {
      let rc = "c-green";
      if (t.success_rate < 50) rc = "c-red";
      else if (t.success_rate < 80) rc = "c-amber";
      html += `<tr>
        <td>${escapeHtml(t.template)}</td><td>${t.total}</td>
        <td class="c-green">${t.successful}</td><td class="c-red">${t.failed}</td>
        <td class="${rc}">${t.success_rate}%</td><td>${formatDuration(t.avg_duration_secs)}</td></tr>`;
    }
    html += `</tbody></table></div>`;
  }

  // Stage Failures
  if (d.by_stage_failure.length > 0) {
    html += `<div class="analytics-section"><h3>Failure Attribution (by Stage)</h3>
      <div class="analytics-failures">`;
    for (const f of d.by_stage_failure) {
      const barWidth = Math.max(f.pct_of_failures, 2);
      html += `<div class="failure-row">
        <span class="failure-stage">${escapeHtml(f.stage_name)}</span>
        <div class="failure-bar-container">
          <div class="failure-bar" style="width: ${barWidth}%"></div>
        </div>
        <span class="failure-count">${f.failure_count} (${f.pct_of_failures}%)</span>
      </div>`;
    }
    html += `</div></div>`;
  }

  // By Complexity
  if (d.by_complexity.length > 0) {
    html += `<div class="analytics-section"><h3>By Complexity</h3><table class="analytics-table">
      <thead><tr><th>Complexity</th><th>Total</th><th>Pass</th><th>Rate</th></tr></thead><tbody>`;
    for (const c of d.by_complexity) {
      let rc = "c-green";
      if (c.success_rate < 50) rc = "c-red";
      else if (c.success_rate < 80) rc = "c-amber";
      html += `<tr><td>${escapeHtml(c.complexity)}</td><td>${c.total}</td>
        <td class="c-green">${c.successful}</td><td class="${rc}">${c.success_rate}%</td></tr>`;
    }
    html += `</tbody></table></div>`;
  }

  // Hourly Distribution
  if (d.by_hour.length > 0) {
    const maxHourTotal = Math.max(...d.by_hour.map((h) => h.total), 1);
    html += `<div class="analytics-section"><h3>Hourly Distribution (UTC)</h3>
      <div class="analytics-hourly">`;
    for (const h of d.by_hour) {
      const barHeight = Math.round((h.total / maxHourTotal) * 60);
      let barClass = "bar-green";
      if (h.success_rate < 50) barClass = "bar-red";
      else if (h.success_rate < 80) barClass = "bar-amber";
      html += `<div class="hour-bar-col" title="${h.hour}:00 UTC - ${h.total} runs, ${h.success_rate}% success">
        <div class="hour-bar ${barClass}" style="height: ${barHeight}px"></div>
        <div class="hour-label">${h.hour}</div>
      </div>`;
    }
    html += `</div></div>`;
  }

  // Active Pipelines
  if (d.active_pipelines.length > 0) {
    html += `<div class="analytics-section"><h3>Active Pipelines (${d.active_pipelines.length})</h3><table class="analytics-table">
      <thead><tr><th>Job</th><th>Template</th><th>Stage</th><th>Elapsed</th><th>Goal</th></tr></thead><tbody>`;
    for (const p of d.active_pipelines) {
      const goal = p.goal.length > 50 ? p.goal.substring(0, 47) + "..." : p.goal;
      html += `<tr><td>${escapeHtml(p.job_id)}</td><td>${escapeHtml(p.template)}</td>
        <td>${escapeHtml(p.current_stage)}</td><td>${formatDuration(p.elapsed_secs)}</td>
        <td>${escapeHtml(goal)}</td></tr>`;
    }
    html += `</tbody></table></div>`;
  }

  panel.innerHTML = html;
  wireUpPeriodButtons(panel);
}

function wireUpPeriodButtons(panel: HTMLElement): void {
  panel.querySelectorAll(".period-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const period = parseInt(btn.getAttribute("data-period") || "7");
      currentPeriod = period;
      fetchAnalytics(period);
    });
  });
}

function formatDuration(secs: number): string {
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ${secs % 60}s`;
  return `${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`;
}

export const analyticsView: View = {
  init() {
    fetchAnalytics(currentPeriod);
    refreshTimer = setInterval(() => fetchAnalytics(currentPeriod), 30000);
  },
  render(_data: FleetState) {
    if (analyticsData) renderAnalytics();
  },
  destroy() {
    if (refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = null;
    }
  },
};
