// Centralized configuration for dashboard services
import { join } from "path";

const HOME = process.env.HOME || "";

export const config = {
  port: parseInt(
    process.argv[2] || process.env.SHIPWRIGHT_DASHBOARD_PORT || "8767",
  ),
  home: HOME,
  eventsFile: join(HOME, ".shipwright", "events.jsonl"),
  daemonState: join(HOME, ".shipwright", "daemon-state.json"),
  logsDir: join(HOME, ".shipwright", "logs"),
  heartbeatDir: join(HOME, ".shipwright", "heartbeats"),
  machinesFile: join(HOME, ".shipwright", "machines.json"),
  costsFile: join(HOME, ".shipwright", "costs.json"),
  budgetFile: join(HOME, ".shipwright", "budget.json"),
  memoryDir: join(HOME, ".shipwright", "memory"),
  publicDir: join(import.meta.dir, "../public"),
  dbFile: join(HOME, ".shipwright", "shipwright.db"),
  sessionsFile: join(HOME, ".shipwright", "sessions.json"),
  developerRegistryFile: join(HOME, ".shipwright", "developer-registry.json"),
  teamEventsFile: join(HOME, ".shipwright", "team-events.jsonl"),
  inviteTokensFile: join(HOME, ".shipwright", "invite-tokens.json"),
  notificationsConfigFile: join(HOME, ".shipwright", "notifications.json"),
};
