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
      <h2>Raw state</h2>
      <pre>${escapeHtml(JSON.stringify(item.summary, null, 2))}</pre>
    </article>
  `;
}

loadDetail().catch((error) => {
  console.error(error);
  document.getElementById("detail").innerHTML = `<p class="error">${escapeHtml(error.message || error)}</p>`;
});
setInterval(() => {
  loadDetail().catch((error) => console.error(error));
}, 5000);
