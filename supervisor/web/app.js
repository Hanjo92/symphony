function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatTimestamp(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

async function updateRepository(event, id) {
  event.preventDefault();
  const form = event.currentTarget;
  const repositoryInput = form.querySelector("input[name=repository]");
  const sourceRepoUrlInput = form.querySelector("input[name=sourceRepoUrl]");
  const status = form.querySelector(".form-status");

  status.textContent = "Saving...";

  const response = await fetch(`/api/instances/${encodeURIComponent(id)}/repository`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      repository: repositoryInput.value.trim(),
      sourceRepoUrl: sourceRepoUrlInput.value.trim()
    })
  });

  const payload = await response.json();
  if (!response.ok) {
    status.textContent = payload.error || "Failed to save";
    status.classList.add("error");
    return;
  }

  status.textContent = "Saved and restarted.";
  status.classList.remove("error");
  await loadOverview();
}

async function loadOverview() {
  const response = await fetch("/api/instances");
  const data = await response.json();

  document.getElementById("meta").textContent = `Last updated: ${formatTimestamp(data.updatedAt)}`;

  const total = data.instances.length;
  const running = data.instances.filter((item) => item.status === "running").length;
  const degraded = data.instances.filter((item) => item.status === "degraded").length;
  const down = data.instances.filter((item) => item.status === "down").length;
  const activeAgents = data.instances.reduce((sum, item) => sum + (item.activeAgents || 0), 0);

  document.getElementById("summary").innerHTML = `
    <div class="summary-card"><strong>${total}</strong><span>instances</span></div>
    <div class="summary-card"><strong>${running}</strong><span>running</span></div>
    <div class="summary-card"><strong>${degraded}</strong><span>degraded</span></div>
    <div class="summary-card"><strong>${down}</strong><span>down</span></div>
    <div class="summary-card"><strong>${activeAgents}</strong><span>active agents</span></div>
  `;

  document.getElementById("instances").innerHTML = data.instances.map((item) => {
    const errorHtml = item.error ? `<p class="error">${escapeHtml(item.error)}</p>` : "";
    const lockedReason = item.canReassignRepository ? "" : '<p class="muted small">Repository changes are only allowed when there are no running or retrying tickets.</p>';
    const disabledAttr = item.canReassignRepository ? "" : "disabled";
    const sourceRepoUrl = item.sourceRepoUrl || `https://github.com/${item.repo}.git`;
    return `
      <article class="card">
        <div class="card-top">
          <div>
            <h2>${escapeHtml(item.name)}</h2>
            <p class="repo">${escapeHtml(item.repo)}</p>
          </div>
          <span class="badge badge-${escapeHtml(item.status)}">${escapeHtml(item.status)}</span>
        </div>

        <ul class="metrics">
          <li>active: <strong>${item.activeAgents}</strong></li>
          <li>backoff: <strong>${item.backoffCount}</strong></li>
          <li>open issues: <strong>${item.openIssues}</strong></li>
        </ul>

        ${errorHtml}

        <form class="repo-form" data-instance-id="${encodeURIComponent(item.id)}">
          <label>
            <span>Repository</span>
            <input type="text" name="repository" value="${escapeHtml(item.repo)}" ${disabledAttr} />
          </label>
          <label>
            <span>Source repo URL</span>
            <input type="text" name="sourceRepoUrl" value="${escapeHtml(sourceRepoUrl)}" ${disabledAttr} />
          </label>
          ${lockedReason}
          <div class="repo-form-actions">
            <button type="submit" ${disabledAttr}>Apply</button>
            <span class="form-status muted small"></span>
          </div>
        </form>

        <div class="actions">
          <a href="/instance?id=${encodeURIComponent(item.id)}">detail</a>
          <a href="${escapeHtml(item.publicBaseUrl)}" target="_blank" rel="noreferrer">dashboard</a>
        </div>
      </article>
    `;
  }).join("");

  document.querySelectorAll(".repo-form").forEach((form) => {
    form.addEventListener("submit", (event) => {
      updateRepository(event, form.dataset.instanceId).catch((error) => {
        console.error(error);
        const status = form.querySelector(".form-status");
        status.textContent = error.message || String(error);
        status.classList.add("error");
      });
    });
  });
}

loadOverview().catch((error) => {
  console.error(error);
});
setInterval(() => {
  loadOverview().catch((error) => console.error(error));
}, 5000);
