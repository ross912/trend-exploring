const $ = (selector) => document.querySelector(selector);
const signalLabels = { "新闻": "新闻" };
const trendStateLabels = { rising: "上升", new: "新出现", watching: "观察中" };
const languageLabels = { "zh-CN": "中文", en: "英文" };
const topicKindLabels = { phrase: "短语", term: "主题词" };

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;","\"":"&quot;"}[character]));
}

function formatGrowth(value) {
  if (value === null || value === undefined || value === "") return "—";
  const number = Number(value);
  return Number.isFinite(number) ? `${number > 0 ? "+" : ""}${number}%` : "—";
}

function renderSources(sources) {
  const roster = $("#source-roster");
  const summary = $("#coverage-summary");
  if (!sources.length) {
    roster.innerHTML = '<div class="empty-state">还没有来源采集记录。</div>';
    summary.innerHTML = "";
    return;
  }
  const groups = sources.filter((source) => source.enabled).reduce((result, source) => {
    const region = source.region || "未标注";
    result[region] = (result[region] || 0) + 1;
    return result;
  }, {});
  summary.innerHTML = Object.entries(groups).map(([region, count]) => `<span><strong>${escapeHtml(count)}</strong>${escapeHtml(region)}</span>`).join("");
  roster.innerHTML = sources.map((source) => {
    const status = source.last_error ? "采集异常" : `${escapeHtml(source.last_item_count)} 条新条目`;
    const sourceLink = /^https:\/\//.test(source.source_url || "")
      ? `<a href="${escapeHtml(source.source_url)}" target="_blank" rel="noopener noreferrer">源地址</a>`
      : "";
    return `<article class="source-pill ${source.enabled ? "" : "is-disabled"}">
      <div class="source-pill-head"><strong>${escapeHtml(source.source_name)}</strong><span>${escapeHtml(source.region)}</span></div>
      <div class="source-pill-meta"><span>${escapeHtml(languageLabels[source.language] || source.language)} · ${status}</span>${sourceLink}</div>
    </article>`;
  }).join("");
}

function renderTrends(trends) {
  const container = $("#trends");
  $("#trend-count-label").textContent = `${trends.length} 条趋势`;
  if (!trends.length) {
    container.innerHTML = '<div class="empty-state">当前时间窗内没有达到独立来源门槛的趋势。单源话题会留在新闻区，不会被冒充成趋势。</div>';
    return;
  }
  container.innerHTML = trends.map((trend) => {
    const evidence = (trend.evidence_urls || []).slice(0, 3).map((url, index) => `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">证据 ${index + 1}</a>`).join(" · ");
    return `<article class="trend-card" data-state="${escapeHtml(trend.signal_state)}">
      <div class="trend-card-top"><span class="trend-state">${escapeHtml(trendStateLabels[trend.signal_state] || trend.signal_state)}</span><span class="trend-language">${escapeHtml(languageLabels[trend.topic_language] || trend.topic_language)}${escapeHtml(topicKindLabels[trend.topic_kind] || "主题")}</span></div>
      <h3>${escapeHtml(trend.topic)}</h3>
      <p class="trend-summary">${escapeHtml(trend.summary)}</p>
      <div class="trend-metrics">
        <div><span>总提及</span><strong>${escapeHtml(trend.mention_count)}</strong></div>
        <div><span>最近窗口</span><strong>${escapeHtml(trend.recent_mention_count)}</strong></div>
        <div><span>增速</span><strong>${escapeHtml(formatGrowth(trend.growth_rate))}</strong></div>
        <div><span>独立来源</span><strong>${escapeHtml(trend.source_count)}</strong></div>
      </div>
      <div class="trend-foot"><span>${escapeHtml((trend.regions || []).join(" / "))} · ${(trend.languages || []).map((language) => languageLabels[language] || language).join(" / ")}</span><span>${evidence}</span></div>
    </article>`;
  }).join("");
}

function renderNews(cards) {
  const container = $("#cards");
  $("#card-count").textContent = `${cards.length} 条新闻`;
  if (!cards.length) {
    container.innerHTML = '<div class="empty-state">当前没有已采集新闻。</div>';
    return;
  }
  container.innerHTML = cards.map((card) => `
    <article class="signal-card" data-type="${escapeHtml(card.signal_type)}">
      <div class="card-type">${escapeHtml(signalLabels[card.signal_type] || card.signal_type)}</div>
      <div class="card-main"><h3 class="card-title">${escapeHtml(card.title)}</h3><p class="card-summary">${escapeHtml(card.summary)}</p></div>
      <div class="card-meta"><span class="card-source">${escapeHtml(card.source_name)}</span><span class="card-language">${escapeHtml(languageLabels[card.source_language] || card.source_language || "原文")} · ${escapeHtml(card.source_region || "未标注")}</span><span class="card-time"><span>${escapeHtml(card.metric_label)}</span>${escapeHtml(card.metric_value)}</span>${/^https:\/\//.test(card.source_url || "") ? ` <a class="source-link" href="${escapeHtml(card.source_url)}" target="_blank" rel="noopener noreferrer">查看原文</a>` : ""}</div>
    </article>`).join("");
}

function renderRadar(payload) {
  const snapshot = payload.snapshot;
  const cards = payload.cards || [];
  const trends = payload.trends || [];
  const sources = payload.sources || [];
  const activeSources = sources.filter((source) => source.enabled);
  const regions = [...new Set(activeSources.map((source) => source.region).filter(Boolean))];
  $("#source-count").textContent = activeSources.length;
  $("#region-count").textContent = regions.length;
  $("#trend-count").textContent = trends.length;
  renderSources(sources);
  renderTrends(trends);
  renderNews(cards);
  if (!snapshot) {
    $("#cards").innerHTML = '<div class="empty-state">当前没有已发布快照。先运行本地采集，再刷新页面。</div>';
    return;
  }
  $("#revision").textContent = `REV ${snapshot.revision}`;
  $("#watermark").textContent = snapshot.comparison_watermark;
  $("#method-epoch").textContent = snapshot.method_epoch;
  $("#rights-epoch").textContent = snapshot.rights_epoch;
  $("#surface-id").textContent = snapshot.surface_id;
  $("#data-note").textContent = `快照 ${snapshot.snapshot_id} · ${snapshot.created_at}`;
}

async function loadRadar() {
  const button = $("#refresh-button");
  button.disabled = true;
  $("#data-note").textContent = "读取真实采集快照…";
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
    $("#trends").innerHTML = `<div class="error-state">无法连接本地 API：${escapeHtml(error.message)}</div>`;
    $("#cards").innerHTML = `<div class="error-state">运行 <code>bash scripts/local/run_product.sh</code> 后再刷新页面。</div>`;
  } finally {
    button.disabled = false;
  }
}

function tick() { $("#clock").textContent = new Date().toLocaleTimeString("zh-CN", { hour12: false }); }
$("#refresh-button").addEventListener("click", loadRadar);
tick();
setInterval(tick, 1000);
loadRadar();
