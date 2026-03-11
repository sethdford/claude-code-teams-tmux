// Dashboard type definitions
export interface DaemonEvent {
  ts: string;
  ts_epoch?: number;
  type: string;
  issue?: number;
  stage?: string;
  duration_s?: number;
  pid?: number;
  issues_found?: number;
  active?: number;
  from?: number;
  to?: number;
  max_by_cpu?: number;
  max_by_mem?: number;
  max_by_budget?: number;
  cpu_cores?: number;
  avail_mem_gb?: number;
  result?: string;
  [key: string]: unknown;
}

export interface Pipeline {
  issue: number;
  title: string;
  stage: string;
  elapsed_s: number;
  worktree: string;
  iteration: number;
  maxIterations: number;
  stagesDone: string[];
  linesWritten: number;
  testsPassing: boolean;
}

export interface QueueItem {
  issue: number;
  title: string;
  score: number;
}

export interface DoraMetric {
  value: number;
  unit: string;
  grade: "Elite" | "High" | "Medium" | "Low";
}

export interface DoraGrades {
  deploy_freq: DoraMetric;
  lead_time: DoraMetric;
  cfr: DoraMetric;
  mttr: DoraMetric;
}

export interface ConnectedDeveloper {
  developer_id: string;
  machine_name: string;
  hostname: string;
  platform: string;
  last_heartbeat: number; // epoch ms
  daemon_running: boolean;
  daemon_pid: number | null;
  active_jobs: Array<{ issue: number; title: string; stage: string }>;
  queued: number[];
  events_since: number; // last synced event timestamp
}

export interface TeamState {
  developers: Array<ConnectedDeveloper & { _presence?: string }>;
  total_online: number;
  total_active_pipelines: number;
  total_queued: number;
}

export interface FleetState {
  timestamp: string;
  daemon: {
    running: boolean;
    pid: number | null;
    uptime_s: number;
    maxParallel: number;
    pollInterval: number;
  };
  pipelines: Pipeline[];
  queue: QueueItem[];
  events: DaemonEvent[];
  scale: {
    from?: number;
    to?: number;
    maxByCpu?: number;
    maxByMem?: number;
    maxByBudget?: number;
    cpuCores?: number;
    availMemGb?: number;
  };
  metrics: {
    cpuCores: number;
    completed: number;
    failed: number;
    successRate?: SuccessRateInfo;
  };
  agents: AgentInfo[];
  machines: MachineInfo[];
  cost: CostInfo;
  dora: DoraGrades;
  team?: TeamState;
}

export interface TemplateBreakdown {
  template: string;
  succeeded: number;
  failed: number;
  rate: number;
}

export interface SuccessRateInfo {
  rate_7d: number;
  rate_30d: number;
  trend: "up" | "down" | "stable";
  total_7d: number;
  total_30d: number;
  succeeded_7d: number;
  succeeded_30d: number;
  consecutive_failures: number;
  alert: boolean;
  breakdown: TemplateBreakdown[];
}

export interface HealthResponse {
  status: "ok";
  uptime_s: number;
  connections: number;
}

export interface Session {
  githubUser: string;
  accessToken: string;
  avatarUrl: string;
  isAdmin: boolean;
  role: "viewer" | "operator" | "admin";
  expiresAt: number;
}

export interface AgentInfo {
  id: string;
  issue: number;
  title: string;
  machine: string;
  stage: string;
  iteration: number;
  activity: string;
  memory_mb: number;
  cpu_pct: number;
  status: "active" | "idle" | "stale" | "dead";
  heartbeat_age_s: number;
  started_at: string;
  elapsed_s: number;
}

export interface MachineInfo {
  name: string;
  status: "online" | "offline";
  location: string;
  workers: number;
  loaded: number;
  capacity: number;
  cost_24h: number;
  last_heartbeat: string;
}

export interface CostInfo {
  today_usd: number;
  month_usd: number;
  trend: number;
}

export interface NotificationConfig {
  enabled: boolean;
  webhooks: Array<{
    url: string;
    label: string;
    events: string[]; // "pipeline.completed", "pipeline.failed", "alert", "all"
    created_at: string;
  }>;
}

export type AuthMode = "oauth" | "pat" | "none";
