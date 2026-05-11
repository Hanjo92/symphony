import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const WEB_DIR = path.join(ROOT, "web");
const CONFIG_DIR = path.join(ROOT, "config");
const ELIXIR_DIR = path.resolve(ROOT, "..", "elixir");
const CONFIG_PATH = process.env.SYMPHONY_SUPERVISOR_CONFIG || path.join(CONFIG_DIR, "instances.json");
const CONFIG_EXAMPLE_PATH = path.join(CONFIG_DIR, "instances.example.json");

const PORT = Number(process.env.SYMPHONY_SUPERVISOR_PORT || 4090);
const POLL_MS = Number(process.env.SYMPHONY_SUPERVISOR_POLL_MS || 5000);
const FETCH_TIMEOUT_MS = Number(process.env.SYMPHONY_SUPERVISOR_FETCH_TIMEOUT_MS || 3000);
const SUPPORTED_TRACKER_KINDS = new Set(["github", "linear"]);

const execFile = promisify(execFileCallback);

let cache = {
  updatedAt: null,
  instances: []
};

async function readInstancesConfig() {
  try {
    const raw = await fs.readFile(CONFIG_PATH, "utf8");
    return JSON.parse(raw);
  } catch (error) {
    if (error && error.code !== "ENOENT") {
      throw error;
    }

    const fallback = await fs.readFile(CONFIG_EXAMPLE_PATH, "utf8");
    return JSON.parse(fallback);
  }
}

async function writeInstancesConfig(instances) {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  await fs.writeFile(CONFIG_PATH, `${JSON.stringify(instances, null, 2)}\n`, "utf8");
}

function normalizeTrackerKind(value) {
  return SUPPORTED_TRACKER_KINDS.has(value) ? value : "github";
}

function deriveInstanceEnvPath(config) {
  return config.instanceEnvPath || path.join(ELIXIR_DIR, "instances", config.id, ".env");
}

function deriveInstanceEnvExamplePath(config) {
  return path.join(ELIXIR_DIR, "instances", config.id, "env.example");
}

function deriveInstanceWorkflowPath(config) {
  if (config.workflowFile) {
    return path.isAbsolute(config.workflowFile) ? config.workflowFile : path.join(ELIXIR_DIR, config.workflowFile);
  }

  const trackerKind = normalizeTrackerKind(config.trackerKind);
  return path.join(ELIXIR_DIR, "instances", config.id, `WORKFLOW.${trackerKind}.md`);
}

function workflowTemplatePathForTracker(trackerKind) {
  if (trackerKind === "linear") {
    return path.join(ELIXIR_DIR, "WORKFLOW.local.md");
  }

  return path.join(ELIXIR_DIR, "WORKFLOW.github.local.md");
}

function hasActiveTicket(instance) {
  return normalizeArray(instance.running).length > 0 || normalizeArray(instance.backoff).length > 0;
}

function inferSourceRepoUrl(repository) {
  return `https://github.com/${repository}.git`;
}

function trackerDisplayName(trackerKind) {
  return trackerKind === "linear" ? "Linear" : "GitHub";
}

function shellQuote(value) {
  return JSON.stringify(String(value));
}

function upsertExport(content, key, value) {
  const line = `export ${key}=${shellQuote(value)}`;
  const pattern = new RegExp(`^export ${key}=.*$`, "m");
  if (pattern.test(content)) {
    return content.replace(pattern, line);
  }

  const trimmed = content.trimEnd();
  return trimmed ? `${trimmed}\n${line}\n` : `${line}\n`;
}

function removeExport(content, key) {
  const pattern = new RegExp(`^export ${key}=.*\n?`, "mg");
  const next = content.replace(pattern, "");
  return next.replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

async function ensureInstanceEnv(config) {
  const envPath = deriveInstanceEnvPath(config);
  try {
    return { envPath, content: await fs.readFile(envPath, "utf8") };
  } catch (error) {
    if (!error || error.code !== "ENOENT") {
      throw error;
    }

    const examplePath = deriveInstanceEnvExamplePath(config);
    try {
      const exampleContent = await fs.readFile(examplePath, "utf8");
      return { envPath, content: exampleContent };
    } catch {
      return { envPath, content: "" };
    }
  }
}

async function saveInstanceEnv(config, repository, sourceRepoUrl) {
  const { envPath, content } = await ensureInstanceEnv(config);
  const trackerKind = normalizeTrackerKind(config.trackerKind);
  const workflowPath = deriveInstanceWorkflowPath(config);
  let next = content;
  next = upsertExport(next, "SYMPHONY_TRACKER_KIND", trackerKind);
  next = upsertExport(next, "SYMPHONY_WORKFLOW_FILE", workflowPath);
  next = upsertExport(next, "GITHUB_REPOSITORY", repository);
  next = upsertExport(next, "SOURCE_REPO_URL", sourceRepoUrl);
  next = upsertExport(next, "SYMPHONY_WORKSPACE_ROOT", config.workspaceRoot);

  if (trackerKind === "linear") {
    next = upsertExport(next, "SYMPHONY_PROJECT_SLUG", config.trackerProjectSlug || "");
    if (config.trackerAssignee) {
      next = upsertExport(next, "LINEAR_ASSIGNEE", config.trackerAssignee);
    } else {
      next = removeExport(next, "LINEAR_ASSIGNEE");
    }
  } else {
    next = removeExport(next, "SYMPHONY_PROJECT_SLUG");
    next = removeExport(next, "LINEAR_ASSIGNEE");
  }

  const port = String(new URL(config.localBaseUrl).port || "");
  if (port) {
    next = upsertExport(next, "SYMPHONY_PORT", port);
  }

  await fs.mkdir(path.dirname(envPath), { recursive: true });
  await fs.writeFile(envPath, next, "utf8");
  return envPath;
}

async function ensureInstanceWorkflow(config) {
  const workflowPath = deriveInstanceWorkflowPath(config);

  try {
    await fs.access(workflowPath);
    return workflowPath;
  } catch (error) {
    if (!error || error.code !== "ENOENT") {
      throw error;
    }
  }

  const trackerKind = normalizeTrackerKind(config.trackerKind);
  const templatePath = workflowTemplatePathForTracker(trackerKind);
  const template = await fs.readFile(templatePath, "utf8");
  await fs.mkdir(path.dirname(workflowPath), { recursive: true });
  await fs.writeFile(workflowPath, template, "utf8");
  return workflowPath;
}

async function restartInstanceService(serviceName) {
  if (!serviceName) {
    return { restarted: false, warning: "serviceName is not configured" };
  }

  try {
    await execFile("systemctl", ["--user", "restart", serviceName]);
    return { restarted: true, warning: null };
  } catch (error) {
    return {
      restarted: false,
      warning: error?.stderr?.trim() || error?.message || String(error)
    };
  }
}

async function readJsonBody(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }

  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) {
    return {};
  }

  return JSON.parse(raw);
}

async function fetchJson(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal, headers: { accept: "application/json" } });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function normalizeArray(value) {
  return Array.isArray(value) ? value : [];
}

function summarizeInstance(config, state, error = null) {
  const trackerKind = normalizeTrackerKind(config.trackerKind);
  const instanceEnvPath = deriveInstanceEnvPath(config);
  const workflowPath = deriveInstanceWorkflowPath(config);
  const trackerTarget = trackerKind === "linear" ? (config.trackerProjectSlug || "") : (config.repo || "");

  if (!state) {
    return {
      ...config,
      trackerKind,
      trackerLabel: trackerDisplayName(trackerKind),
      trackerTarget,
      workflowPath,
      instanceEnvPath,
      reachable: false,
      status: config.enabled ? "down" : "disabled",
      activeAgents: 0,
      backoffCount: 0,
      openIssues: 0,
      openPullRequests: 0,
      running: [],
      backoff: [],
      canReassignRepository: true,
      summary: null,
      error: error ? String(error.message || error) : "unreachable"
    };
  }

  const running = normalizeArray(state.running || state.agents?.running || state.running_agents);
  const backoff = normalizeArray(state.backoff_queue || state.queues?.backoff);
  const activeAgents = running.length;
  const backoffCount = backoff.length;
  const openIssues = state.tracker?.open_count ?? state.github?.counts?.open_issues ?? state.github?.issues?.open_count ?? 0;
  const openPullRequests = state.github?.counts?.open_pull_requests ?? 0;

  return {
    ...config,
    trackerKind,
    trackerLabel: trackerDisplayName(trackerKind),
    trackerTarget,
    workflowPath,
    instanceEnvPath,
    reachable: true,
    status: backoffCount > 0 ? "degraded" : "running",
    activeAgents,
    backoffCount,
    openIssues,
    openPullRequests,
    running,
    backoff,
    canReassignRepository: activeAgents === 0 && backoffCount === 0,
    summary: state,
    error: null
  };
}

async function refreshCache() {
  const configs = await readInstancesConfig();

  const instances = await Promise.all(
    configs.map(async (config) => {
      if (!config.enabled) {
        const trackerKind = normalizeTrackerKind(config.trackerKind);
        return {
          ...config,
          trackerKind,
          trackerLabel: trackerDisplayName(trackerKind),
          trackerTarget: trackerKind === "linear" ? (config.trackerProjectSlug || "") : (config.repo || ""),
          workflowPath: deriveInstanceWorkflowPath(config),
          instanceEnvPath: deriveInstanceEnvPath(config),
          reachable: false,
          status: "disabled",
          activeAgents: 0,
          backoffCount: 0,
          openIssues: 0,
          openPullRequests: 0,
          running: [],
          backoff: [],
          summary: null,
          error: null
        };
      }

      try {
        const normalizedConfig = { ...config, trackerKind: normalizeTrackerKind(config.trackerKind) };
        const state = await fetchJson(`${config.localBaseUrl}/api/v1/state`);
        return summarizeInstance(normalizedConfig, state);
      } catch (error) {
        return summarizeInstance({ ...config, trackerKind: normalizeTrackerKind(config.trackerKind) }, null, error);
      }
    })
  );

  cache = {
    updatedAt: new Date().toISOString(),
    instances
  };
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(payload, null, 2));
}

function contentTypeFor(filePath) {
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".json")) return "application/json; charset=utf-8";
  return "text/plain; charset=utf-8";
}

async function serveFile(response, filePath) {
  try {
    const body = await fs.readFile(filePath);
    response.writeHead(200, { "content-type": contentTypeFor(filePath) });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
  }
}

await refreshCache();
setInterval(() => {
  refreshCache().catch((error) => {
    console.error("Failed to refresh supervisor cache:", error);
  });
}, POLL_MS);

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (url.pathname === "/api/health") {
    return sendJson(response, 200, { ok: true, updatedAt: cache.updatedAt });
  }

  if (url.pathname === "/api/instances") {
    return sendJson(response, 200, cache);
  }

  const repositoryMatch = url.pathname.match(/^\/api\/instances\/([^/]+)\/(repository|settings)$/);
  if (repositoryMatch) {
    const id = decodeURIComponent(repositoryMatch[1] || "");
    const instance = cache.instances.find((entry) => entry.id === id);

    if (!instance) {
      return sendJson(response, 404, { error: "not found" });
    }

    if (request.method !== "POST") {
      return sendJson(response, 405, { error: "method not allowed" });
    }

    if (hasActiveTicket(instance)) {
      return sendJson(response, 409, { error: "settings can only be changed when no ticket is running or queued for retry" });
    }

    try {
      const body = await readJsonBody(request);
      const repository = String(body.repository || "").trim();
      const trackerKind = normalizeTrackerKind(String(body.trackerKind || instance.trackerKind || "github").trim());
      const sourceRepoUrl = String(body.sourceRepoUrl || inferSourceRepoUrl(repository)).trim();
      const trackerProjectSlug = String(body.trackerProjectSlug || "").trim();
      const trackerAssignee = String(body.trackerAssignee || "").trim();

      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
        return sendJson(response, 400, { error: "repository must be in owner/name format" });
      }

      if (!SUPPORTED_TRACKER_KINDS.has(trackerKind)) {
        return sendJson(response, 400, { error: "trackerKind must be github or linear" });
      }

      if (!/^https:\/\/github\.com\/.+/.test(sourceRepoUrl) && !/^git@github\.com:.+/.test(sourceRepoUrl)) {
        return sendJson(response, 400, { error: "sourceRepoUrl must be a GitHub HTTPS or SSH URL" });
      }

      if (trackerKind === "linear" && !trackerProjectSlug) {
        return sendJson(response, 400, { error: "trackerProjectSlug is required for Linear instances" });
      }

      const configs = await readInstancesConfig();
      const nextConfigs = configs.map((entry) => {
        if (entry.id !== id) return entry;
        return {
          ...entry,
          repo: repository,
          trackerKind,
          trackerProjectSlug: trackerKind === "linear" ? trackerProjectSlug : undefined,
          trackerAssignee: trackerKind === "linear" && trackerAssignee ? trackerAssignee : undefined,
          sourceRepoUrl,
          workflowFile: entry.workflowFile,
          instanceEnvPath: deriveInstanceEnvPath(entry)
        };
      });

      const updatedConfig = nextConfigs.find((entry) => entry.id === id);
      await ensureInstanceWorkflow(updatedConfig);
      const envPath = await saveInstanceEnv(updatedConfig, repository, sourceRepoUrl);
      await writeInstancesConfig(nextConfigs);
      const restartResult = await restartInstanceService(updatedConfig.serviceName);
      await refreshCache();

      const updatedInstance = cache.instances.find((entry) => entry.id === id);
      return sendJson(response, 200, {
        ok: true,
        instance: updatedInstance,
        envPath,
        workflowPath: deriveInstanceWorkflowPath(updatedConfig),
        ...restartResult
      });
    } catch (error) {
      console.error("Failed to update repository assignment:", error);
      return sendJson(response, 500, { error: error.message || String(error) });
    }
  }

  const instanceMatch = url.pathname.match(/^\/api\/instances\/([^/]+)$/);
  if (instanceMatch) {
    const id = decodeURIComponent(instanceMatch[1] || "");
    const instance = cache.instances.find((entry) => entry.id === id);
    if (!instance) {
      return sendJson(response, 404, { error: "not found" });
    }
    return sendJson(response, 200, instance);
  }

  if (url.pathname === "/") {
    return serveFile(response, path.join(WEB_DIR, "index.html"));
  }

  if (url.pathname === "/instance") {
    return serveFile(response, path.join(WEB_DIR, "instance.html"));
  }

  const requestedPath = url.pathname.replace(/^\/+/, "");
  const filePath = path.join(WEB_DIR, requestedPath);
  if (filePath.startsWith(WEB_DIR)) {
    return serveFile(response, filePath);
  }

  response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  response.end("Not found");
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Symphony supervisor listening on http://127.0.0.1:${PORT}`);
});
