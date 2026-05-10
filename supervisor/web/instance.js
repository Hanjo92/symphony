function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function getQueryParam(name) {
  return new URLSearchParams(window.location.search).get(name);
}

async function loadDetail() {
  const id = getQueryParam("id");
  if (!id) {
    document.getElementById("detail").innerHTML = '<p class="error">Missing instance id.</p>';
    return;
  }

  const response = await fetch(`/api/instances/${encodeURIComponent(id)}`);
  const item = await response.json();

  if (!response.ok) {
    document.getElementById("detail").innerHTML = `<p class="error">${escapeHtml(item.error || "not found")}</p>`;
    return;
  }

  document.getElementById("title").textContent = item.name;

  const sourceRepoUrl = item.sourceRepoUrl || `https://github.com/${item.repo}.git`;
  const disabledAttr = item.canReassignRepository ? "" : "disabled";
  const lockedReason = item.canReassignRepository ? "" : '<p class="muted small">Repository changes are only allowed when there are no running or retrying tickets.</p>';

  document.getElementById("detail").innerHTML = `
    <article class="card detail-card">
      <p><strong>repo:</strong> ${escapeHtml(item.repo)}</p>
      <p><strong>status:</strong> <span class="badge badge-${escapeHtml(item.status)}">${escapeHtml(item.status)}</span></p>
      <p><strong>service:</strong> ${escapeHtml(item.serviceName)}</p>
      <p><strong>workspace:</strong> ${escapeHtml(item.workspaceRoot)}</p>
      <p><strong>local dashboard:</strong> ${escapeHtml(item.localBaseUrl)}</p>
      <p><strong>public dashboard:</strong> <a href="${escapeHtml(item.publicBaseUrl)}" target="_blank" rel="noreferrer">${escapeHtml(item.publicBaseUrl)}</a></p>
      <p><strong>active agents:</strong> ${item.activeAgents}</p>
      <p><strong>backoff count:</strong> ${item.backoffCount}</p>
      <p><strong>open issues:</strong> ${item.openIssues}</p>
      ${item.error ? `<p class="error"><strong>error:</strong> ${escapeHtml(item.error)}</p>` : ""}

      <form id="repo-form" class="repo-form" data-instance-id="${encodeURIComponent(item.id)}">
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

      <h2>Raw state</h2>
      <pre>${escapeHtml(JSON.stringify(item.summary, null, 2))}</pre>
    </article>
  `;

  const form = document.getElementById("repo-form");
  if (form) {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const status = form.querySelector(".form-status");
      status.textContent = "Saving...";
      const response = await fetch(`/api/instances/${encodeURIComponent(item.id)}/repository`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          repository: form.querySelector("input[name=repository]").value.trim(),
          sourceRepoUrl: form.querySelector("input[name=sourceRepoUrl]").value.trim()
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
      await loadDetail();
    });
  }
}

loadDetail().catch((error) => {
  console.error(error);
  document.getElementById("detail").innerHTML = `<p class="error">${escapeHtml(error.message || error)}</p>`;
});
setInterval(() => {
  loadDetail().catch((error) => console.error(error));
}, 5000);
