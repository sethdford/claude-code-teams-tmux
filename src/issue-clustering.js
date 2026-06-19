/**
 * Semantic Issue Clustering Engine
 *
 * Clusters historical issues from events.jsonl using TF-IDF vectorization and
 * cosine similarity, so that when a new issue arrives the pipeline can match it
 * to a cluster of similar past issues and reuse the approach that worked.
 *
 * Dependency-free by design: TF-IDF, cosine similarity, and threshold-based
 * agglomerative (connected-components) clustering are implemented in plain JS so
 * the engine has no install footprint and runs anywhere Node does.
 *
 * Usage (CLI):
 *   node src/issue-clustering.js cluster [--threshold N] [--min-size N] \
 *       [--max-clusters N] [--generated-at ISO]   < events-array.json   > clusters.json
 *   node src/issue-clustering.js match [--threshold N]  < {issue,clusters}.json
 *
 * Usage (module):
 *   const C = require('./issue-clustering');
 *   const clusters = C.clusterIssues(C.extractIssues(events), opts);
 *   const match = C.matchIssueToCluster(issue, clusters, threshold);
 */

"use strict";

const ALGORITHM_VERSION = "1";

// Confidence tiers for a similarity score (0.0–1.0). Mirrors daemon-config.json
// clustering.confidence_tiers; kept here as the algorithm-side default.
const DEFAULT_TIERS = { high: 0.85, medium: 0.7, low: 0.5 };

// Small English stopword set — removing these sharpens TF-IDF on content words.
const STOPWORDS = new Set([
  "the",
  "a",
  "an",
  "and",
  "or",
  "but",
  "if",
  "in",
  "on",
  "at",
  "to",
  "for",
  "of",
  "with",
  "by",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "being",
  "as",
  "it",
  "its",
  "this",
  "that",
  "these",
  "those",
  "from",
  "into",
  "out",
  "up",
  "down",
  "no",
  "not",
  "than",
  "then",
  "when",
  "while",
  "we",
  "you",
  "i",
  "he",
  "she",
  "they",
  "them",
  "his",
  "her",
  "their",
  "our",
  "your",
  "my",
  "me",
  "do",
  "does",
  "did",
  "has",
  "have",
  "had",
  "will",
  "would",
  "should",
  "could",
  "can",
]);

/**
 * Tokenize free text into lowercase content words (length >= 2, non-stopword).
 * @param {string} text
 * @returns {string[]}
 */
function tokenize(text) {
  if (!text || typeof text !== "string") return [];
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length >= 2 && !STOPWORDS.has(t));
}

/**
 * Extract a normalized list of issues from raw events.jsonl objects.
 *
 * Events that describe the same issue (same issue_id / issue) are merged: their
 * text fields are concatenated, files unioned, and the outcome resolved from any
 * success/failure signal present. Permissive by design — events from many
 * Shipwright producers use slightly different field names.
 *
 * @param {Array<object>} events
 * @returns {Array<{id:string,title:string,text:string,files:string[],
 *   errorSignature:string,success:(boolean|null)}>}
 */
function extractIssues(events) {
  if (!Array.isArray(events)) return [];
  const byId = new Map();
  let anon = 0;

  for (const ev of events) {
    if (!ev || typeof ev !== "object") continue;
    const id = String(
      ev.issue_id || ev.issue || ev.id || ev.goal_id || `auto-${anon++}`,
    );
    const title = ev.title || ev.goal || ev.name || ev.summary || "";
    const desc = ev.description || ev.body || ev.detail || "";
    const err =
      ev.error || ev.error_signature || ev.error_message || ev.failure || "";
    const files = Array.isArray(ev.files)
      ? ev.files
      : Array.isArray(ev.changed_files)
        ? ev.changed_files
        : [];

    let outcome = null;
    if (typeof ev.success === "boolean") outcome = ev.success;
    else if (ev.outcome === "success" || ev.result === "success")
      outcome = true;
    else if (ev.outcome === "failure" || ev.result === "failure")
      outcome = false;
    else if (ev.type === "pipeline_completed" && ev.status)
      outcome = ev.status === "success" || ev.status === "merged";

    if (!byId.has(id)) {
      byId.set(id, {
        id,
        title: "",
        text: "",
        files: new Set(),
        errorSignature: "",
        success: null,
      });
    }
    const issue = byId.get(id);
    if (title && !issue.title) issue.title = String(title);
    issue.text = `${issue.text} ${title} ${desc} ${err}`.trim();
    for (const f of files) if (f) issue.files.add(String(f));
    if (err) issue.errorSignature = `${issue.errorSignature} ${err}`.trim();
    if (outcome !== null) issue.success = outcome;
  }

  return Array.from(byId.values())
    .map((i) => ({ ...i, files: Array.from(i.files) }))
    .filter((i) => i.text.length > 0);
}

/**
 * Build sparse TF-IDF vectors for a list of token arrays.
 * @param {string[][]} docsTokens
 * @returns {Array<Map<string,number>>} one term→weight map per document
 */
function buildTfIdf(docsTokens) {
  const N = docsTokens.length;
  const df = new Map();
  for (const tokens of docsTokens) {
    for (const term of new Set(tokens)) df.set(term, (df.get(term) || 0) + 1);
  }
  return docsTokens.map((tokens) => {
    const tf = new Map();
    for (const term of tokens) tf.set(term, (tf.get(term) || 0) + 1);
    const vec = new Map();
    const len = tokens.length || 1;
    for (const [term, count] of tf) {
      const idf = Math.log((1 + N) / (1 + df.get(term))) + 1;
      vec.set(term, (count / len) * idf);
    }
    return vec;
  });
}

/**
 * Cosine similarity between two sparse term→weight maps. Range [0, 1].
 * @param {Map<string,number>} a
 * @param {Map<string,number>} b
 * @returns {number}
 */
function cosineSim(a, b) {
  if (!a || !b || a.size === 0 || b.size === 0) return 0;
  // Iterate the smaller map for the dot product.
  const [small, large] = a.size <= b.size ? [a, b] : [b, a];
  let dot = 0;
  for (const [term, w] of small) {
    const o = large.get(term);
    if (o) dot += w * o;
  }
  let magA = 0;
  for (const w of a.values()) magA += w * w;
  let magB = 0;
  for (const w of b.values()) magB += w * w;
  const denom = Math.sqrt(magA) * Math.sqrt(magB);
  return denom === 0 ? 0 : dot / denom;
}

/**
 * Resolve a similarity score to a confidence tier label.
 * @param {number} score
 * @param {{high:number,medium:number,low:number}} tiers
 * @returns {('high'|'medium'|'low'|'none')}
 */
function confidenceTier(score, tiers) {
  const t = tiers || DEFAULT_TIERS;
  if (score >= t.high) return "high";
  if (score >= t.medium) return "medium";
  if (score >= t.low) return "low";
  return "none";
}

// Pick the most frequent items from an array, returning [{value,count}, ...].
function topByFrequency(items, limit) {
  const freq = new Map();
  for (const it of items) freq.set(it, (freq.get(it) || 0) + 1);
  return Array.from(freq.entries())
    .sort((x, y) => y[1] - x[1] || String(x[0]).localeCompare(String(y[0])))
    .slice(0, limit)
    .map(([value, count]) => ({ value, count }));
}

// Build a cluster's centroid term-weight map (mean of member vectors), keeping
// only the heaviest `limit` terms so the stored representation stays compact and
// matchable without the original corpus.
function centroidTerms(vectors, limit) {
  const sum = new Map();
  for (const vec of vectors) {
    for (const [term, w] of vec) sum.set(term, (sum.get(term) || 0) + w);
  }
  const n = vectors.length || 1;
  return Array.from(sum.entries())
    .map(([term, w]) => [term, w / n])
    .sort((x, y) => y[1] - x[1])
    .slice(0, limit);
}

/**
 * Threshold-based agglomerative clustering via connected components.
 *
 * Two issues share a cluster when their cosine similarity >= threshold. The
 * transitive closure of those edges forms each cluster. This needs no preset
 * cluster count (unlike k-means) and is deterministic.
 *
 * @param {Array<object>} issues  output of extractIssues()
 * @param {object} [options]
 * @param {number} [options.threshold=0.5]   edge similarity cutoff
 * @param {number} [options.minClusterSize=2] drop clusters smaller than this
 * @param {number} [options.maxClusters=50]   keep only the N largest clusters
 * @param {string} [options.generatedAt]      ISO timestamp for the document
 * @returns {object} clusters document (see schema in plan)
 */
function clusterIssues(issues, options) {
  const opts = options || {};
  const threshold = typeof opts.threshold === "number" ? opts.threshold : 0.5;
  const minClusterSize =
    typeof opts.minClusterSize === "number" ? opts.minClusterSize : 2;
  const maxClusters =
    typeof opts.maxClusters === "number" ? opts.maxClusters : 50;
  const generatedAt = opts.generatedAt || new Date().toISOString();

  const base = {
    version: ALGORITHM_VERSION,
    generated_at: generatedAt,
    metadata: {
      algorithm: "agglomerative-connected-components",
      distance_metric: "cosine",
      vectorization: "tf-idf",
      similarity_threshold: threshold,
      min_cluster_size: minClusterSize,
      total_issues_processed: issues ? issues.length : 0,
    },
    clusters: [],
  };

  if (!Array.isArray(issues) || issues.length === 0) return base;

  const vectors = buildTfIdf(issues.map((i) => tokenize(i.text)));

  // Union-Find over the similarity graph.
  const parent = issues.map((_, i) => i);
  const find = (x) => {
    while (parent[x] !== x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  };
  const union = (a, b) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[Math.max(ra, rb)] = Math.min(ra, rb);
  };

  for (let i = 0; i < issues.length; i++) {
    for (let j = i + 1; j < issues.length; j++) {
      if (cosineSim(vectors[i], vectors[j]) >= threshold) union(i, j);
    }
  }

  const groups = new Map();
  for (let i = 0; i < issues.length; i++) {
    const root = find(i);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(i);
  }

  let clusters = Array.from(groups.values())
    .filter((members) => members.length >= minClusterSize)
    .map((members) => buildClusterRecord(members, issues, vectors));

  clusters.sort((a, b) => b.size - a.size);
  clusters = clusters.slice(0, maxClusters);
  clusters.forEach((c, idx) => {
    c.id = `cluster-${String(idx + 1).padStart(3, "0")}`;
  });

  base.clusters = clusters;
  base.metadata.cluster_count = clusters.length;
  return base;
}

// Build the stored record for one cluster of member indices.
function buildClusterRecord(members, issues, vectors) {
  const memberIssues = members.map((m) => issues[m]);
  const memberVectors = members.map((m) => vectors[m]);

  const withOutcome = memberIssues.filter((i) => i.success !== null);
  const successCount = withOutcome.filter((i) => i.success === true).length;
  const successRate = withOutcome.length
    ? successCount / withOutcome.length
    : null;

  // Representative = the member most central to the cluster (highest mean
  // similarity to the others), which best summarizes the group.
  let repIdx = 0;
  let bestCentrality = -1;
  for (let a = 0; a < members.length; a++) {
    let sum = 0;
    for (let b = 0; b < members.length; b++) {
      if (a !== b) sum += cosineSim(memberVectors[a], memberVectors[b]);
    }
    const centrality = members.length > 1 ? sum / (members.length - 1) : 0;
    if (centrality > bestCentrality) {
      bestCentrality = centrality;
      repIdx = a;
    }
  }
  const rep = memberIssues[repIdx];

  const commonFiles = topByFrequency(
    memberIssues.flatMap((i) => i.files),
    10,
  )
    .filter((f) => f.count >= Math.max(2, Math.ceil(members.length * 0.3)))
    .map((f) => f.value);

  const errorTokens = memberIssues.flatMap((i) => tokenize(i.errorSignature));
  const errorPatterns = topByFrequency(errorTokens, 5).map((e) => e.value);

  return {
    id: "",
    size: members.length,
    success_metrics: {
      success_count: successCount,
      total_with_outcome: withOutcome.length,
      success_rate: successRate,
    },
    representative: {
      issue_id: rep.id,
      title: rep.title || rep.text.slice(0, 80),
    },
    issue_ids: memberIssues.map((i) => i.id),
    common_files: commonFiles,
    common_error_signature: errorPatterns,
    centroid_terms: centroidTerms(memberVectors, 20),
    recommended_approach: {
      basis: `Derived from ${members.length} similar past issues`,
      success_rate: successRate,
      representative_issue: rep.id,
      common_files: commonFiles,
    },
  };
}

/**
 * Match a new issue to its nearest stored cluster.
 *
 * @param {object} issue           {title?, text?/description?, error?, files?}
 * @param {object} clustersDoc     output of clusterIssues()
 * @param {number} [threshold=0.5] minimum similarity to count as a match
 * @param {object} [tiers]         confidence tier thresholds
 * @returns {(object|null)} match record, or null if nothing exceeds threshold
 */
function matchIssueToCluster(issue, clustersDoc, threshold, tiers) {
  const thr = typeof threshold === "number" ? threshold : 0.5;
  if (!clustersDoc || !Array.isArray(clustersDoc.clusters)) return null;
  if (clustersDoc.clusters.length === 0) return null;

  const text = [
    issue && issue.title,
    issue && (issue.text || issue.description),
    issue && (issue.error || issue.errorSignature),
  ]
    .filter(Boolean)
    .join(" ");
  const queryVec = new Map();
  for (const term of tokenize(text)) {
    queryVec.set(term, (queryVec.get(term) || 0) + 1);
  }
  if (queryVec.size === 0) return null;

  let best = null;
  for (const cluster of clustersDoc.clusters) {
    const centroid = new Map(
      (cluster.centroid_terms || []).map((p) => [p[0], p[1]]),
    );
    const score = cosineSim(queryVec, centroid);
    if (!best || score > best.similarity_score) {
      best = { cluster, similarity_score: score };
    }
  }

  if (!best || best.similarity_score < thr) return null;

  return {
    cluster_id: best.cluster.id,
    similarity_score: Number(best.similarity_score.toFixed(4)),
    confidence_tier: confidenceTier(best.similarity_score, tiers),
    success_rate: best.cluster.success_metrics
      ? best.cluster.success_metrics.success_rate
      : null,
    recommended_approach: best.cluster.recommended_approach,
    representative: best.cluster.representative,
  };
}

// ─── CLI ────────────────────────────────────────────────────────────────────

// Parse `--key value` flags into a plain object.
function parseFlags(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val =
        i + 1 < argv.length && !argv[i + 1].startsWith("--")
          ? argv[++i]
          : "true";
      flags[key] = val;
    }
  }
  return flags;
}

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
  });
}

async function main() {
  const [, , command, ...rest] = process.argv;
  const flags = parseFlags(rest);
  const raw = await readStdin();

  let input;
  try {
    input = raw.trim() ? JSON.parse(raw) : null;
  } catch (err) {
    process.stderr.write(
      `issue-clustering: invalid JSON input: ${err.message}\n`,
    );
    process.exit(1);
    return;
  }

  if (command === "cluster") {
    const events = Array.isArray(input) ? input : input && input.events;
    const issues = extractIssues(events || []);
    const doc = clusterIssues(issues, {
      threshold: flags.threshold ? parseFloat(flags.threshold) : undefined,
      minClusterSize: flags["min-size"]
        ? parseInt(flags["min-size"], 10)
        : undefined,
      maxClusters: flags["max-clusters"]
        ? parseInt(flags["max-clusters"], 10)
        : undefined,
      generatedAt: flags["generated-at"],
    });
    process.stdout.write(JSON.stringify(doc, null, 2) + "\n");
  } else if (command === "match") {
    const issue = input && input.issue ? input.issue : input;
    const clusters = input && input.clusters ? input.clusters : null;
    const match = matchIssueToCluster(
      issue,
      clusters,
      flags.threshold ? parseFloat(flags.threshold) : undefined,
    );
    process.stdout.write(JSON.stringify(match) + "\n");
  } else {
    process.stderr.write(
      "Usage: issue-clustering.js {cluster|match} [--threshold N] [--min-size N] [--max-clusters N]\n",
    );
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  ALGORITHM_VERSION,
  DEFAULT_TIERS,
  tokenize,
  extractIssues,
  buildTfIdf,
  cosineSim,
  confidenceTier,
  clusterIssues,
  matchIssueToCluster,
};
