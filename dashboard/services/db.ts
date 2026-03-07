import { Database } from "bun:sqlite";
import { existsSync } from "fs";
import { config } from "./config.js";
import type { DaemonEvent } from "../types/index.js";

let db: Database | null = null;

export function getDb(): Database | null {
  if (db) return db;
  try {
    if (!existsSync(config.dbFile)) return null;
    db = new Database(config.dbFile, { readonly: true });
    db.exec("PRAGMA journal_mode=WAL;");
    return db;
  } catch {
    return null;
  }
}

export function dbQueryEventsByIdGreaterThan(
  afterId: number,
  limit = 100,
): Array<Record<string, unknown>> {
  const conn = getDb();
  if (!conn) return [];
  try {
    return conn
      .query(`SELECT * FROM events WHERE id > ? ORDER BY id ASC LIMIT ?`)
      .all(afterId, limit) as Array<Record<string, unknown>>;
  } catch {
    return [];
  }
}

export function dbQueryEvents(since?: number, limit = 200): DaemonEvent[] {
  const conn = getDb();
  if (!conn) return [];
  try {
    const cutoff = since || 0;
    const rows = conn
      .query(
        `SELECT ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata
         FROM events WHERE ts_epoch >= ? ORDER BY ts_epoch DESC LIMIT ?`,
      )
      .all(cutoff, limit) as Array<Record<string, unknown>>;
    return rows.map((r) => {
      const base: DaemonEvent = {
        ts: r.ts as string,
        ts_epoch: r.ts_epoch as number,
        type: r.type as string,
      };
      if (r.job_id)
        base.issue = parseInt(String(r.job_id).replace(/\D/g, "")) || undefined;
      if (r.stage) base.stage = r.stage as string;
      if (r.duration_secs) base.duration_s = r.duration_secs as number;
      if (r.status) base.result = r.status as string;
      if (r.metadata) {
        try {
          Object.assign(base, JSON.parse(r.metadata as string));
        } catch {
          /* ignore malformed metadata */
        }
      }
      return base;
    });
  } catch {
    return [];
  }
}

export function dbQueryJobs(status?: string): Array<Record<string, unknown>> {
  const conn = getDb();
  if (!conn) return [];
  try {
    if (status) {
      return conn
        .query(
          "SELECT * FROM daemon_state WHERE status = ? ORDER BY started_at DESC",
        )
        .all(status) as Array<Record<string, unknown>>;
    }
    return conn
      .query("SELECT * FROM daemon_state ORDER BY started_at DESC LIMIT 50")
      .all() as Array<Record<string, unknown>>;
  } catch {
    return [];
  }
}

export function dbQueryCostsToday(): { total: number; count: number } {
  const conn = getDb();
  if (!conn) return { total: 0, count: 0 };
  try {
    const todayStart = new Date();
    todayStart.setUTCHours(0, 0, 0, 0);
    const epoch = Math.floor(todayStart.getTime() / 1000);
    const row = conn
      .query(
        "SELECT COALESCE(SUM(cost_usd), 0) as total, COUNT(*) as count FROM cost_entries WHERE ts_epoch >= ?",
      )
      .get(epoch) as { total: number; count: number } | null;
    return row || { total: 0, count: 0 };
  } catch {
    return { total: 0, count: 0 };
  }
}

export function dbQueryHeartbeats(): Array<Record<string, unknown>> {
  const conn = getDb();
  if (!conn) return [];
  try {
    return conn
      .query("SELECT * FROM heartbeats ORDER BY updated_at DESC")
      .all() as Array<Record<string, unknown>>;
  } catch {
    return [];
  }
}
