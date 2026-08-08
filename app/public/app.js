const $ = (selector) => document.querySelector(selector);
const signalLabels = { diffusion: "扩散", emergence: "新出现", exploration: "认知探索" };
const metricLabels = { "independent actors": "独立行动者", "mention delta": "讨论增量", "detector result": "检测结果" };
const actionLabels = { "early adoption": "早期采纳", discussion: "讨论阶段", "not applicable": "不适用" };
const evidenceLabels = { "action evidence missing": "尚缺行动证据", "exploration only": "仅作探索材料" };

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;","\"":"&quot;"}[character]));
}

function renderRadar(payload) {
  const snapshot = payload.snapshot;
  const cards = payload.cards || [];
  $("#card-count").textContent = `${cards.length} 条信号`;
  if (!snapshot) {
    $("#cards").innerHTML = '<div class="empty-state">当前没有已发布快照。先运行本地 bootstrap，再刷新页面。</div>';
    return;
  }
  $("#revision").textContent = `REV ${snapshot.revision}`;
  $("#watermark").textContent = snapshot.comparison_watermark;
  $("#method-epoch").textContent = snapshot.method_epoch;
  $("#rights-epoch").textContent = snapshot.rights_epoch;
  $("#surface-id").textContent = snapshot.surface_id;
  $("#data-note").textContent = `快照 ${snapshot.snapshot_id} · ${snapshot.created_at}`;
  $("#cards").innerHTML = cards.map((card) => `
    <article class="signal-card" data-type="${escapeHtml(card.signal_type)}">
      <div class="card-type">${escapeHtml(signalLabels[card.signal_type] || card.signal_type)}</div>
      <div><h3 class="card-title">${escapeHtml(card.title)}</h3><p class="card-summary">${escapeHtml(card.summary)}</p></div>
      <div class="card-metric"><span>${escapeHtml(metricLabels[card.metric_label] || card.metric_label)}</span><strong>${escapeHtml(card.metric_value)}</strong><small>${escapeHtml(card.source_count)} 个来源 · ${escapeHtml(evidenceLabels[card.evidence_label] || card.evidence_label)}</small></div>
    </article>`).join("");
}

async function loadRadar() {
  const button = $("#refresh-button");
  button.disabled = true;
  $("#data-note").textContent = "读取 snapshot…";
  try {
    const [healthResponse, radarResponse] = await Promise.all([fetch("/api/health"), fetch("/api/radar")]);
    const health = await healthResponse.json();
    const radar = await radarResponse.json();
    $("#health-label").textContent = health.status === "ok" ? "本地连接" : "数据库降级";
    $(".live-dot").classList.toggle("error", health.status !== "ok");
    renderRadar(radar);
  } catch (error) {
    $("#health-label").textContent = "离线";
    $(".live-dot").classList.add("error");
    $("#cards").innerHTML = `<div class="error-state">无法连接本地 API：${escapeHtml(error.message)}<br><small>运行 <code>ruby scripts/local/bootstrap_radar.rb</code> 后再启动 server。</small></div>`;
  } finally {
    button.disabled = false;
  }
}

function tick() { $("#clock").textContent = new Date().toLocaleTimeString("zh-CN", { hour12: false }); }
$("#refresh-button").addEventListener("click", loadRadar);
tick();
setInterval(tick, 1000);
loadRadar();
