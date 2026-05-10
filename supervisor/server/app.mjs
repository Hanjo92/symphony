import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const WEB_DIR = path.join(ROOT, "web");
const CONFIG_DIR = path.join(ROOT, "config");
const CONFIG_PATH = process.env.SYMPHONY_SUPERVISOR_CONFIG || path.join(CONFIG_DIR, "instances.json");
const CONFIG_EXAMPLE_PATH = path.join(CONFIG_DIR, "instances.example.json");

const PORT = Number(process.env.SYMPHONY_SUPERVISOR_PORT || 4090);
const POLL_MS = Number(process.env.SYMPHONY_SUPERVISOR_POLL_MS || 5000);
const FETCH_TIMEOUT_MS = Number(process.env.SYMPHONY_SUPERVISOR_FETCH_TIMEOUT_MS || 3000);

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
  if (!state) {
    return {
      ...config,
      reachable: false,
      status: config.enabled ? "down" : "disabled",
      activeAgents: 0,
      backoffCount: 0,
      openIssues: 0,
      running: [],
      backoff: [],
      summary: null,
      error: error ? String(error.message || error) : "unreachable"
    };
  }

  const running = normalizeArray(state.running || state.agents?.running || state.running_agents);
  const backoff = normalizeArray(state.backoff_queue || state.queues?.backoff);
  const activeAgents = running.length;
  const backoffCount = backoff.length;
  const openIssues = state.github?.issues?.open_count ?? state.tracker?.open_count ?? 0;

  return {
    ...config,
    reachable: true,
    status: backoffCount > 0 ? "degraded" : "running",
    activeAgents,
    backoffCount,
    openIssues,
    running,
    backoff,
    summary: state,
    error: null
  };
}

async function refreshCache() {
  const configs = await readInstancesConfig();

  const instances = await Promise.all(
    configs.map(async (config) => {
      if (!config.enabled) {
        return {
          ...config,
          reachable: false,
          status: "disabled",
          activeAgents: 0,
          backoffCount: 0,
          openIssues: 0,
          running: [],
          backoff: [],
          summary: null,
          error: null
        };
      }

      try {
        const state = await fetchJson(`${config.localBaseUrl}/api/v1/state`);
        return summarizeInstance(config, state);
      } catch (error) {
        return summarizeInstance(config, null, error);
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

  if (url.pathname.startsWith("/api/instances/")) {
    const id = decodeURIComponent(url.pathname.split("/").pop() || "");
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
