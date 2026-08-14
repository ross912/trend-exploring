const $ = (selector) => document.querySelector(selector);
const signalLabels = { "新闻": "新闻", emergence: "出现" };
const trendStateLabels = { rising: "上升", new: "新出现", watching: "观察中" };
const languageLabels = { "zh-CN": "中文", en: "英文", "es-419": "西班牙语（拉美）", "pt-BR": "葡萄牙语（巴西）", ja: "日语", ar: "阿拉伯语", de: "德语" };
const topicKindLabels = { phrase: "短语", term: "主题词" };
const semanticStatusLabels = { deterministic_episode: "重复短语候选", contextual_term: "上下文共现词", statistical_candidate: "词频候选" };
const translationStatusLabels = { translated: "机器译文（未人工核验）", untranslated: "待机器翻译", failed: "机器翻译失败", not_needed: "中文原文" };
const weakReasonLabels = {
  NEWLY_REPEATED: "最近重复出现",
  SOURCE_EXPANSION: "来源扩张",
  NEW_LANGUAGE_OR_LOCALE_PARTICIPATION: "语言或 locale 参与变化",
  DISCUSSION_DECLINE: "讨论下降"
};

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
}

function safeUrl(value) {
  return /^https:\/\//i.test(String(value || "")) ? escapeHtml(value) : "";
}

function formatGrowth(value) {
  if (value === null || value === undefined || value === "") return "未提供";
  const number = Number(value);
  return Number.isFinite(number) ? `${number > 0 ? "+" : ""}${number}%` : "未提供";
}

function statusBadge(value, label = value) {
  return `<span class="status-badge status-${escapeHtml(value)}">${escapeHtml(label)}</span>`;
}

function renderSources(sources) {
  const roster = $("#source-roster");
  if (!sources.length) {
    roster.innerHTML = '<div class="empty-state">还没有来源采集记录。</div>';
    return;
  }
  roster.innerHTML = sources.map((source) => {
    const status = source.last_error ? "采集异常" : `${escapeHtml(source.last_item_count)} 条新条目`;
    const entryType = source.discovery_basis === "locale_headlines" ? "locale 头条·仅探索" : (source.query_conditioned ? "主题查询 feed" : "编辑 RSS");
    const regionBasis = source.discovery_basis === "locale_headlines" ? "聚合器 locale 标签" : (source.region_basis === "query_target_label" ? "查询目标标签·预设查询" : "编辑范围标签");
    const sourceLink = safeUrl(source.source_url);
    return `<article class="source-pill ${source.enabled ? "" : "is-disabled"}">
      <div class="source-pill-head"><strong>${escapeHtml(source.source_name)}</strong><span>${escapeHtml(entryType)}</span></div>
      <div class="source-pill-meta"><span>${escapeHtml(languageLabels[source.language] || source.language)} · ${escapeHtml(regionBasis)}：${escapeHtml(source.region || "未标注")} · ${status}</span>${sourceLink ? `<a href="${sourceLink}" target="_blank" rel="noopener noreferrer">源地址</a>` : ""}</div>
    </article>`;
  }).join("");
}

function renderCoverage(coverage) {
  const summary = $("#coverage-summary");
  const debts = $("#coverage-debts");
  const languages = coverage.observed_languages || [];
  const debtLabels = {
    event_geography_unverified: "事件地域未验证", no_observed_content_language: "尚无观察到的内容语言",
    single_content_language: "当前仅一种内容语言", only_two_content_languages: "当前仅两种内容语言",
    discovery_is_topic_conditioned: "发现入口受预设主题查询条件约束", discovery_publisher_origin_unknown: "发现入口出版方来源仍未知",
    locale_discovery_is_aggregator_mediated: "locale 发现由聚合器中介", configured_frontier_is_not_open_world: "配置前沿不是开放世界",
    unsupported_analysis_languages: "语言暂不进入趋势/事件分析"
  };
  summary.innerHTML = [
    [coverage.editorial_feed_count, "编辑 RSS"], [coverage.query_feed_count, "主题查询 feed"],
    [coverage.configured_publisher_count, "配置出版方"], [coverage.observed_publisher_domain_count, "观察出版方域名"],
    [languages.length, `内容语言（${languages.map((language) => languageLabels[language] || language).join(" / ") || "无"}）`],
    [coverage.unresolved_publisher_item_count, "未解析出版方条目"], [coverage.configured_locale_headline_feed_count, "配置 locale 头条入口"],
    [coverage.last_batch_succeeded_source_count, "本批成功（有条目）"], [coverage.last_batch_empty_source_count, "本批成功（空）"],
    [coverage.last_batch_failed_source_count, "本批失败"], [coverage.exploration_only_item_count, "探索归档条目"]
  ].map(([count, label]) => `<span><strong>${escapeHtml(count)}</strong>${escapeHtml(label)}</span>`).join("");
  debts.innerHTML = (coverage.debts || []).map((debt) => `<span>${escapeHtml(debtLabels[debt] || "未映射覆盖债务")}</span>`).join("") || "<span>当前未记录额外覆盖债务</span>";
  $("#coverage-note").textContent = `事件地域：${coverage.event_geography_status === "unverified" ? "当前未验证" : escapeHtml(coverage.event_geography_status)} · locale 观察标签：${escapeHtml((coverage.observed_locale_tags || []).join(" / ") || "无")} · 原始语言：${escapeHtml((coverage.observed_original_languages || []).map((language) => languageLabels[language] || language).join(" / ") || "无")}`;
}

function renderArchive(archive) {
  const policies = archive.source_policies || [];
  const permitted = Number(archive.full_archive_source_count || 0);
  const attempts = archive.archive_attempts || {};
  const queue = archive.translation_queue || {};
  $("#archive-summary").innerHTML = [
    [archive.versioned_item_count || 0, "原语言版本"], [policies.length, "已登记来源"],
    [permitted, "已核验全文许可"], [archive.fulltext_archive_count || 0, "正文已归档"],
    [archive.fulltext_translation_count || 0, "中文全文"], [queue.pending || 0, "全文待翻译"]
  ].map(([count, label]) => `<span><strong>${escapeHtml(count)}</strong>${escapeHtml(label)}</span>`).join("");
  $("#archive-note").textContent = permitted === 0
    ? `当前没有来源登记为已核验 full_archive，因此正文归档为 0 是权限门禁的正确结果；已记录 ${attempts.not_permitted || 0} 次未获许可决策。`
    : `已许可来源会自动进入正文归档和中文翻译；失败状态：抓取 ${attempts.fetch_failed || 0}，解析 ${attempts.parse_failed || 0}，空正文 ${attempts.empty_body || 0}。`;
  $("#archive-policies").innerHTML = policies.length ? policies.map((policy) => `<article class="source-pill"><div class="source-pill-head"><strong>${escapeHtml(policy.source_name || policy.source_id)}</strong><span>${policy.rights_scope === "full_archive" ? "全文归档" : policy.rights_scope === "excerpt_only" ? "元数据/短摘要" : "仅链接"}</span></div><div class="source-pill-meta"><span>${policy.rights_scope === "full_archive" ? `许可：${escapeHtml(policy.permission_basis)} · 核验 ${escapeHtml(policy.permission_verified_at)}` : "未登记全文许可，不请求文章页"}</span></div></article>`).join("") : '<div class="empty-state">尚无来源保存政策记录。</div>';
}

function renderExploration(exploration) {
  const latest = exploration && exploration.latest_batch;
  const items = (exploration && exploration.items) || [];
  const boundary = (exploration && exploration.boundary) || {};
  const stateLabels = { not_run: "worker 未运行", success_empty: "成功但为空", partial_failure: "部分失败", failed: "本批失败", snapshot_no_selection: "快照无 selection", published: "已发布探索快照" };
  $("#exploration-boundary").textContent = `聚合器中介：${boundary.aggregator_mediated === true ? "是" : "未知"} · topic-conditioned：${boundary.topic_conditioned === false ? "否" : "未知"} · signal-eligible：${boundary.signal_eligible === false ? "否" : "未知"} · 事件地域：${boundary.event_geography_status === "unverified" ? "未验证" : "未知"}。此区仅归档/浏览，不声称重要、新颖、趋势或早期信号。`;
  if (!latest) {
    $("#exploration-count-label").textContent = "worker 未运行";
    $("#exploration-meta").textContent = "尚无本批采集记录；这不是空结果。";
    $("#exploration-items").innerHTML = '<div class="empty-state">worker 未运行，暂没有探索 selection。</div>';
    return;
  }
  $("#exploration-count-label").textContent = `${items.length} 条归档 · ${stateLabels[latest.worker_state] || "状态待确认"}`;
  $("#exploration-meta").textContent = `计划 ${latest.planned_source_count} 个入口 · 成功有条目 ${latest.succeeded_source_count} · 成功空 ${latest.empty_source_count} · 失败 ${latest.failed_source_count} · selection ${latest.selection_count}。失败计入分母；market 标签不是事件地域。`;
  if (!items.length) {
    const emptyCopy = latest.worker_state === "success_empty" ? "本批入口成功响应但没有条目。" : latest.worker_state === "partial_failure" ? "本批部分入口失败；剩余入口没有形成 selection。" : latest.worker_state === "snapshot_no_selection" ? "本批有成功条目，但快照没有 selection。" : "本批没有可展示的探索归档条目。";
    $("#exploration-items").innerHTML = `<div class="empty-state">${escapeHtml(emptyCopy)} 这不是趋势或重要性判断。</div>`;
    return;
  }
  $("#exploration-items").innerHTML = items.map((item) => {
    const link = safeUrl(item.source_url);
    const unsupported = !["zh-CN", "en"].includes(item.language);
    const publisher = item.resolution === "resolved" ? `publisher_id/domain=${escapeHtml(item.publisher_id || "")}` : "出版方域名未解析";
    const title = item.display_title || item.title;
    const summary = item.display_summary || item.summary;
    const original = item.translation_status === "translated" ? `<details class="original-copy"><summary>查看原语言元数据</summary><strong>${escapeHtml(item.title)}</strong><p>${escapeHtml(item.summary || "")}</p></details>` : "";
    return `<article class="exploration-card"><div class="exploration-card-top"><span>${escapeHtml(item.locale_tag || "locale 未标注")} · ${escapeHtml(item.market_label || "market 未标注")} · 聚合器 locale 标签</span><span>${escapeHtml(translationStatusLabels[item.translation_status] || (item.resolution === "resolved" ? "出版方域名已观察" : "出版方域名未解析"))}</span></div><h3>${escapeHtml(title)}</h3><p>${escapeHtml(summary || "该条目没有短摘要。")}</p>${original}<div class="exploration-card-meta"><span>${escapeHtml(languageLabels[item.language] || item.language)}${unsupported ? " · 仅归档/浏览" : ""} · ${publisher}</span><span>basis=${escapeHtml(item.market_label_basis || "aggregator_locale_label")} · ${link ? `<a href="${link}" target="_blank" rel="noopener noreferrer">条目/原文入口</a>` : "无原文链接"}</span></div><div class="exploration-card-boundary">raw_listing · claim_status=${escapeHtml(item.claim_status || "raw_listing")} · lane=${escapeHtml(item.lane || "locale_frontier")}</div></article>`;
  }).join("");
}

function renderEventCandidates(candidates) {
  const container = $("#event-candidates");
  $("#event-count-label").textContent = `${candidates.length} 个候选`;
  if (!candidates.length) {
    container.innerHTML = '<div class="empty-state">当前没有满足门槛的确定性文本相似候选。空结果不表示没有事件、影响或弱信号；此区不会把 query evidence 计入资格。</div>';
    return;
  }
  container.innerHTML = candidates.map((candidate) => {
    const evidence = (candidate.evidence_items || []).map((item) => `<li><strong>${escapeHtml(item.publisher_name || item.publisher_id)}</strong> · ${escapeHtml(item.title)} <span>${escapeHtml(item.lineage_role === "query_conditioned_support" ? "query evidence·不计资格" : "qualifying·计入资格")}</span> ${safeUrl(item.source_url) ? `<a href="${safeUrl(item.source_url)}" target="_blank" rel="noopener noreferrer">原文</a>` : ""}</li>`).join("");
    const anchors = (candidate.shared_anchors || []).map((anchor) => `${escapeHtml(anchor.kind)}:${escapeHtml(anchor.value)} (${escapeHtml(anchor.supporting_qualifying_source_count || candidate.qualifying_source_count)}/${escapeHtml(candidate.qualifying_source_count)})`).join(" · ");
    return `<article class="event-card"><div class="event-card-top"><span>确定性文本相似候选</span><span>${escapeHtml(languageLabels[candidate.language] || candidate.language)} · ${escapeHtml(candidate.matching_method || "")}</span></div><h3>${escapeHtml(candidate.label || "未命名候选")}</h3><p class="event-explanation">${escapeHtml(candidate.explanation || "同语言条目共享受控文本锚；仅供复核。")}</p><div class="event-metrics"><span><strong>${escapeHtml(candidate.qualifying_source_count)}</strong>个资格来源</span><span><strong>${escapeHtml(candidate.query_conditioned_evidence_count)}</strong>条 query evidence</span><span><strong>${escapeHtml(candidate.time_span_hours)}h</strong>时间跨度</span></div><div class="event-anchors"><span>全体共同锚点：${escapeHtml(anchors || "未提供")}</span><span>全体共同短语：${escapeHtml((candidate.shared_phrases || []).join(" · ") || "未提供")}</span></div><details class="event-evidence"><summary>查看 ${escapeHtml((candidate.evidence_items || []).length)} 条原文条目</summary><ul>${evidence}</ul></details></article>`;
  }).join("");
}

function renderTrends(trends) {
  const container = $("#trends");
  $("#trend-count-label").textContent = `${trends.length} 个词频线索`;
  if (!trends.length) {
    container.innerHTML = '<div class="empty-state">当前时间窗内没有达到去重来源标识门槛的词频线索。词频线索不是事件聚类，也不代表世界变化结论。</div>';
    return;
  }
  container.innerHTML = trends.map((trend) => {
    const evidence = (trend.evidence_urls || []).slice(0, 3).map((url, index) => safeUrl(url) ? `<a href="${safeUrl(url)}" target="_blank" rel="noopener noreferrer">证据 ${index + 1}</a>` : "").join(" · ");
    return `<article class="trend-card" data-state="${escapeHtml(trend.signal_state)}"><div class="trend-card-top"><span class="trend-state">${escapeHtml(trendStateLabels[trend.signal_state] || trend.signal_state)}</span><span class="trend-language">${escapeHtml(semanticStatusLabels[trend.semantic_status] || "统计候选")} · ${escapeHtml(languageLabels[trend.topic_language] || trend.topic_language)}${escapeHtml(topicKindLabels[trend.topic_kind] || "主题")}</span></div><h3>${escapeHtml(trend.topic_label || trend.topic)}</h3><p class="trend-summary">${escapeHtml(trend.summary)}</p><div class="trend-metrics"><div><span>总提及</span><strong>${escapeHtml(trend.mention_count)}</strong></div><div><span>最近窗口</span><strong>${escapeHtml(trend.recent_mention_count)}</strong></div><div><span>增速</span><strong>${escapeHtml(formatGrowth(trend.growth_rate))}</strong></div><div><span>去重来源标识</span><strong>${escapeHtml(trend.source_count)}</strong></div></div><div class="trend-foot"><span>入口标签：${escapeHtml((trend.regions || []).join(" / "))} · ${(trend.languages || []).map((language) => languageLabels[language] || language).join(" / ")}</span><span>${evidence}</span></div></article>`;
  }).join("");
}

function renderNews(cards) {
  const container = $("#cards");
  $("#card-count").textContent = `${cards.length} 条新闻`;
  if (!cards.length) {
    container.innerHTML = '<div class="empty-state">当前没有已采集新闻。</div>';
    return;
  }
  container.innerHTML = cards.map((card) => `<article class="signal-card" data-type="${escapeHtml(card.signal_type)}"><div class="card-type">${escapeHtml(signalLabels[card.signal_type] || card.signal_type)}</div><div class="card-main"><div class="card-title-row"><h3 class="card-title">${escapeHtml(card.title)}</h3><span class="translation-badge status-${escapeHtml(card.translation_status || "not_needed")}">${escapeHtml(translationStatusLabels[card.translation_status] || "原文")}</span></div><p class="card-summary">${escapeHtml(card.summary)}</p>${card.original_title && card.original_title !== card.title ? `<details class="original-copy"><summary>查看英文原文</summary><strong>${escapeHtml(card.original_title)}</strong><p>${escapeHtml(card.original_summary || "")}</p></details>` : ""}</div><div class="card-meta"><span class="card-source">${escapeHtml(card.source_name)}</span><span class="card-language">${escapeHtml(languageLabels[card.source_language] || card.source_language || "原文")} · ${escapeHtml(card.source_region || "未标注")}</span><span class="card-time"><span>${escapeHtml(card.metric_label)}</span>${escapeHtml(card.metric_value)}</span>${safeUrl(card.source_url) ? `<a class="source-link" href="${safeUrl(card.source_url)}" target="_blank" rel="noopener noreferrer">查看原文</a>` : ""}</div></article>`).join("");
}

function reportUnit(unit, evidence) {
  if (!unit || typeof unit !== "object") return "";
  const scopes = Array.isArray(unit.evidence_scopes) ? unit.evidence_scopes : [];
  const ids = scopes.length ? scopes.map((scope) => scope.version_id) : (Array.isArray(unit.cited_version_ids) ? unit.cited_version_ids : []);
  const linked = ids.map((id) => {
    const row = (evidence || []).find((entry) => entry.version_id === id);
    return row ? `<a href="${safeUrl(row.source_url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(row.title || id)}</a>` : `<span>${escapeHtml(id)}</span>`;
  }).join(" · ");
  const typed = unit.kind ? `${unit.kind} · ${unit.epistemic_status || "未标注"}` : "legacy 未验证";
  const relation = scopes.map((scope) => scope.relation).filter(Boolean).join(" / ");
  return `<li><p>${escapeHtml(unit.text)}</p><small>类型：${escapeHtml(typed)}${relation ? ` · 关系：${escapeHtml(relation)}` : ""} · ${unit.kind ? "证据" : "旧版引用（未验证）"}：${linked || "无"}</small></li>`;
}

function renderReport(kind, payload) {
  const card = $(`#${kind}-report`);
  const statusNode = card.querySelector("[data-report-status]");
  const content = card.querySelector("[data-report-content]");
  const status = payload && payload.status ? payload.status : "error";
  statusNode.textContent = ({ published: "已发布", scheduled: "待发布", failed: "发布失败", not_run: "未运行", error: "读取失败" }[status] || status);
  statusNode.className = `report-status state-${escapeHtml(status)}`;
  if (status === "error") {
    content.innerHTML = `<div class="error-state">${escapeHtml(payload.error || "无法读取日报")}</div>`;
    return;
  }
  const items = Array.isArray(payload.items) ? payload.items : [];
  if (status !== "published") {
    content.innerHTML = `<div class="empty-state">${status === "scheduled" ? "该时段已排程，尚未发布 raw edition。" : status === "failed" ? escapeHtml(payload.slot?.failure_reason || "该时段发布失败。") : "尚无该时段的日报记录。"}</div>`;
    return;
  }
  const summary = payload.summary || { status: "not_generated" };
  const artifact = summary.artifact || {};
  const evidence = summary.evidence || [];
  const overview = artifact.overview ? reportUnit(artifact.overview, evidence) : "";
  const changes = (artifact.key_changes || []).map((unit) => reportUnit(unit, evidence)).join("");
  const uncertainties = (artifact.uncertainties || []).map((unit) => reportUnit(unit, evidence)).join("");
  const gateStatus = summary.claim_gate_status || artifact.claim_gate_status || "legacy_unverified";
  const summaryHtml = summary.status === "succeeded"
    ? `<div class="report-summary"><div class="summary-label">AI 摘要 · claim gate：${escapeHtml(gateStatus === "verified" ? "verified" : "legacy_unverified（未验证）")} · 仅作 additive projection</div>${overview ? `<ul class="report-units">${overview}</ul>` : ""}${changes ? `<h4>关键变化候选</h4><ul class="report-units">${changes}</ul>` : ""}${uncertainties ? `<h4>不确定性</h4><ul class="report-units">${uncertainties}</ul>` : ""}</div>`
    : `<div class="report-summary report-summary-muted">AI 摘要：${escapeHtml(summary.status === "blocked" ? "当前没有可用 provider 或不适用，仍保留 raw。" : summary.status === "failed" ? "生成失败，仍保留 raw。" : "尚未生成，仍保留 raw。")}</div>`;
  const raw = items.length ? `<details class="raw-list"><summary>查看 ${items.length} 条 raw listings</summary><ol>${items.map((item) => `<li><strong>${escapeHtml(item.title)}</strong><span>${escapeHtml(translationStatusLabels[item.translation_status] || "原文")} · ${escapeHtml(item.publisher_name || item.source_name || "未知来源")} · ${escapeHtml(item.created_at || item.published_at || "")}</span>${item.translation_status === "translated" ? `<details class="original-copy"><summary>查看原语言元数据</summary><strong>${escapeHtml(item.original_title || "")}</strong><p>${escapeHtml(item.original_summary || "")}</p></details>` : ""}${safeUrl(item.source_url) ? `<a href="${safeUrl(item.source_url)}" target="_blank" rel="noopener noreferrer">原文</a>` : ""}</li>`).join("")}</ol></details>` : '<div class="empty-state">该时段没有可报告的原始条目。</div>';
  content.innerHTML = summaryHtml + raw;
}

function renderWeak(payload) {
  const run = payload && (payload.run || payload);
  const status = payload?.status || run?.status || "not_run";
  const candidates = Array.isArray(run?.candidates) ? run.candidates : [];
  $("#weak-status-label").textContent = status === "evaluated" ? `${candidates.length} 个候选 · 已评估` : status === "warming_up" ? "warming_up · 基线不足" : "检测器未运行";
  $("#weak-run-meta").textContent = run ? `检测器 ${run.detector_version || "v1"} · as_of ${run.as_of || "未提供"} · baseline ${run.baseline_coverage_hours || "未提供"}h。弱信号候选只是词组变化候选。` : "尚无弱信号运行记录；这不是空结果。";
  $("#weak-count").textContent = candidates.length;
  if (!run || status === "not_run") {
    $("#weak-items").innerHTML = '<div class="empty-state">检测器尚未运行。可以在积累至少 72 小时可用基线后重新检查。</div>';
    return;
  }
  if (!candidates.length) {
    $("#weak-items").innerHTML = `<div class="empty-state">${status === "warming_up" ? "基线仍在积累（至少需要 72 小时）；当前不产生候选。" : "当前规则没有产生词组变化候选。空结果不代表世界没有变化。"}</div>`;
    return;
  }
  $("#weak-items").innerHTML = candidates.map((candidate) => {
    const counts = candidate.counts || {};
    const evidenceIds = [...(candidate.recent_evidence_version_ids || []), ...(candidate.prior_evidence_version_ids || [])].filter(Boolean).slice(0, 6);
    return `<article class="weak-card"><div class="weak-card-top"><span>${escapeHtml(candidate.language || "未知语言")}</span><span>规则 v1 · 不预测</span></div><h3>${escapeHtml(candidate.phrase)}</h3><div class="weak-reasons">${(candidate.reason_codes || []).map((reason) => `<span>${escapeHtml(weakReasonLabels[reason] || reason)}</span>`).join("")}</div><p>${escapeHtml(candidate.explanation || "这是可复核的词组变化候选。")}</p><div class="weak-metrics"><span>最近出版方 <strong>${escapeHtml(counts.recent_publisher_count ?? candidate.recent_publisher_count ?? "未提供")}</strong></span><span>此前日最高 <strong>${escapeHtml(counts.prior_publisher_count ?? candidate.prior_publisher_count ?? "未提供")}</strong></span><span>证据版本 <strong>${escapeHtml(evidenceIds.length)}</strong></span></div><details><summary>查看证据版本 ID</summary><code>${escapeHtml(evidenceIds.join(" · ") || "无")}</code></details></article>`;
  }).join("");
}

const worldChannelLabels = {
  technical_capability: "技术能力", capital_commitment: "资本承诺", policy_action: "政策行动",
  real_world_adoption: "现实采用", public_discussion: "公共讨论"
};

function renderWorldChanges(payload, lifecyclePayload) {
  const run = payload && (payload.run || payload);
  const status = payload?.status || run?.status || "not_run";
  const candidates = Array.isArray(run?.candidates) ? run.candidates : [];
  const lifecycle = Object.fromEntries((lifecyclePayload?.lifecycle || []).map((entry) => [entry.signal_id, entry]));
  const caps = payload?.evidence_boundary?.per_channel_refs;
  const boundary = caps ? `公开 refs 上限：资格 ${caps.qualifying} / support ${caps.supporting} / 反证 ${caps.contradicting}；正文不出接口。` : "";
  $("#world-change-status-label").textContent = status === "evaluated" ? `${candidates.length} 个候选 · 非预测` : status === "not_run" ? "尚未运行" : status;
  $("#world-change-run-meta").textContent = run ? `检测器 ${run.detector_version || "v1"} · as_of ${run.as_of || "未提供"} · 固定 run_id ${run.run_id || "未提供"} · ${payload?.truncated ? "公开证据已截断；" : ""}${boundary}不输出总分/置信度/预测。` : "尚无世界变化检测运行记录；这不是空结果。";
  if (!run || !candidates.length) {
    $("#world-change-items").innerHTML = `<div class="empty-state">${status === "not_run" ? "检测器尚未运行。" : "当前没有达到独立 publisher 与通道门槛的候选。空结果不代表世界没有变化。"}</div>`;
    return;
  }
  $("#world-change-items").innerHTML = candidates.map((candidate) => {
    const familyId = (lifecyclePayload?.lifecycle || []).find((entry) => entry.candidate_key === candidate.candidate_key)?.signal_id;
    const state = familyId ? lifecycle[familyId]?.current_state : null;
    const channels = Object.entries(candidate.channels || {}).map(([channel, value]) => {
      const evidenceCount = (value.evidence || []).length;
      const supportCount = (value.supporting_evidence || []).length;
      const contradictionCount = (value.contradicting_evidence || []).length;
      return `<li><strong>${escapeHtml(worldChannelLabels[channel] || channel)}</strong><span>${escapeHtml(value.counts?.qualifying ?? evidenceCount)} 条资格证据 · ${escapeHtml(value.counts?.supporting ?? supportCount)} 条 support · ${escapeHtml(value.counts?.contradicting ?? contradictionCount)} 条反证 · refs ${(value.evidence || []).map((ref) => ref.version_id).join(" · ") || "无"}</span></li>`;
    }).join("");
    const contradiction = (candidate.contradicting_evidence || []).map((entry) => entry.version_id || entry.title || "反证").join(" · ") || "无";
    return `<article class="weak-card world-change-card"><div class="weak-card-top"><span>${escapeHtml(candidate.candidate_status || "candidate")}</span><span>lifecycle=${escapeHtml(state || "未记录")}</span></div><h3>${escapeHtml(candidate.label || "未命名候选")}</h3><p>${escapeHtml(candidate.qualifying_publisher_count || 0)} 个独立 publisher · ${escapeHtml(candidate.channel_count || 0)} 个资格通道；候选仅供回查，非预测。</p><ul class="world-channel-list">${channels}</ul><div class="world-change-boundary"><strong>缺失通道：</strong>${escapeHtml((candidate.missing_channels || []).map((channel) => worldChannelLabels[channel] || channel).join("、") || "无")}</div><div class="world-change-boundary"><strong>反证：</strong>${escapeHtml(contradiction)}</div><details><summary>替代解释与下一步核验</summary><p><strong>替代解释：</strong>${escapeHtml((candidate.alternative_explanations || []).join("；") || "未提供")}</p><p><strong>下一步：</strong>${escapeHtml((candidate.next_verification || []).join("；") || "未提供")}</p></details></article>`;
  }).join("");
}

function renderMultilingualConcepts(payload) {
  const candidates = Array.isArray(payload?.candidates) ? payload.candidates : [];
  const status = payload?.status || (candidates.length ? "evaluated" : "not_run");
  const denominator = payload?.denominator || {};
  $("#multilingual-status-label").textContent = status === "evaluated" ? `${candidates.length} 个真实候选 · 输入 ${denominator.eligible_translation_inputs ?? 0}` : status === "not_run" ? `not_run · 输入 ${denominator.eligible_translation_inputs ?? 0}` : status;
  if (!candidates.length) {
    $("#multilingual-items").innerHTML = `<div class="empty-state">${status === "not_run" ? "映射任务尚未运行；" : "当前没有"} provider-backed 多语言概念候选；保持明确状态，不生成伪造映射。已检查输入：${escapeHtml(denominator.eligible_translation_inputs ?? 0)}。</div>`;
    return;
  }
  $("#multilingual-items").innerHTML = candidates.map((candidate) => `<article class="weak-card"><div class="weak-card-top"><span>${escapeHtml(candidate.candidate_status || "concept participation")}</span><span>${escapeHtml(candidate.target_language || "未提供")}</span></div><h3>${escapeHtml(candidate.target_canonical_label || candidate.canonical_concept_key || "未命名概念")}</h3><p>仅概念参与，不是事件或预测；provider 映射版本：${escapeHtml(candidate.member_version_ids || [])}</p><div class="world-change-boundary">语言 ${escapeHtml((candidate.languages || []).join(" / "))} · publisher ${escapeHtml((candidate.publishers || []).join(" / "))}</div></article>`).join("");
}

function renderRadar(payload) {
  const snapshot = payload.snapshot;
  const cards = payload.cards || [];
  const trends = payload.trends || [];
  const eventCandidates = payload.event_candidates || [];
  const sources = payload.sources || [];
  $("#source-count").textContent = sources.filter((source) => source.enabled).length;
  $("#trend-count").textContent = trends.length;
  renderCoverage(payload.coverage || {});
  renderArchive(payload.archive || {});
  renderExploration(payload.exploration || {});
  renderSources(sources);
  renderEventCandidates(eventCandidates);
  renderTrends(trends);
  renderNews(cards);
  if (!snapshot) {
    $("#data-note").textContent = "当前没有已发布快照";
    return;
  }
  $("#revision").textContent = `REV ${snapshot.revision}`;
  $("#watermark").textContent = snapshot.comparison_watermark || "未提供";
  $("#method-epoch").textContent = snapshot.method_epoch || "未提供";
  $("#rights-epoch").textContent = snapshot.rights_epoch || "未提供";
  $("#surface-id").textContent = snapshot.surface_id || "未提供";
  $("#signal-projection").textContent = snapshot.signal_projection_status === "reused_previous" ? `沿用 signal snapshot ${snapshot.signal_source_snapshot_id || "未标注"}（watermark 未推进）` : "本批 signal fresh";
  $("#data-note").textContent = `快照 ${snapshot.snapshot_id} · ${snapshot.created_at}`;
}

async function fetchJson(path, options = {}) {
  const response = await fetch(path, { headers: { "Accept": "application/json", ...(options.body ? { "Content-Type": "application/json" } : {}) }, ...options });
  let payload;
  try { payload = await response.json(); } catch (_error) { payload = { error: `HTTP ${response.status}` }; }
  if (!response.ok) throw Object.assign(new Error(payload.error || `HTTP ${response.status}`), { status: response.status, payload });
  return payload;
}

async function loadReports() {
  const results = await Promise.allSettled([fetchJson("/api/reports/morning"), fetchJson("/api/reports/evening")]);
  ["morning", "evening"].forEach((kind, index) => {
    const result = results[index];
    renderReport(kind, result.status === "fulfilled" ? result.value : { status: "error", error: result.reason.message });
  });
  $("#report-count-label").textContent = results.filter((result) => result.status === "fulfilled").length === 2 ? "双时段已读取" : "日报读取不完整";
}

async function loadWeakSignals() {
  try { renderWeak(await fetchJson("/api/weak-signals")); }
  catch (error) { $("#weak-status-label").textContent = "读取失败"; $("#weak-run-meta").textContent = error.message; $("#weak-items").innerHTML = `<div class="error-state">无法读取弱信号候选：${escapeHtml(error.message)}</div>`; }
}

async function loadWorldChangeSurfaces() {
  try {
    const [world, lifecycle, concepts] = await Promise.all([fetchJson("/api/world-changes"), fetchJson("/api/signals/lifecycle"), fetchJson("/api/multilingual-concepts")]);
    renderWorldChanges(world, lifecycle);
    renderMultilingualConcepts(concepts);
  } catch (error) {
    $("#world-change-status-label").textContent = "读取失败";
    $("#world-change-items").innerHTML = `<div class="error-state">无法读取世界变化候选：${escapeHtml(error.message)}</div>`;
    $("#multilingual-status-label").textContent = "读取失败";
    $("#multilingual-items").innerHTML = `<div class="error-state">无法读取多语言概念候选：${escapeHtml(error.message)}</div>`;
  }
}

async function loadRadar() {
  const button = $("#refresh-button");
  button.disabled = true;
  $("#data-note").textContent = "读取已发布观察快照…";
  try {
    const [health, radar] = await Promise.all([fetchJson("/api/health"), fetchJson("/api/radar")]);
    $("#health-label").textContent = health.status === "ok" ? "本地连接" : "数据库降级";
    $("#health-dot").classList.toggle("error", health.status !== "ok");
    renderRadar(radar);
  } catch (error) {
    $("#health-label").textContent = "离线";
    $("#health-dot").classList.add("error");
  ["#trends", "#event-candidates", "#exploration-items", "#cards", "#source-roster", "#archive-policies"].forEach((selector) => { const node = $(selector); if (node) node.innerHTML = `<div class="error-state">无法读取本地 API：${escapeHtml(error.message)}</div>`; });
  } finally { button.disabled = false; }
}

function renderEvidenceList(title, rows, key) {
  if (!Array.isArray(rows) || !rows.length) return `<div class="evidence-group"><h4>${escapeHtml(title)}</h4><p class="muted">没有匹配记录。</p></div>`;
  return `<div class="evidence-group"><h4>${escapeHtml(title)}</h4><ul>${rows.map((row) => `<li><strong>${escapeHtml(row.title || row.text || row.memory_entry_id || row.version_id || "记录")}</strong><small>${escapeHtml(row.publisher || row.source || row.memory_kind || "")} · ${escapeHtml(row.created_at || row.recorded_at || "")}</small>${key === "global" && safeUrl(row.source_url) ? `<a href="${safeUrl(row.source_url)}" target="_blank" rel="noopener noreferrer">原文</a>` : ""}</li>`).join("")}</ul></div>`;
}

function renderConversation(result) {
  const node = $("#conversation-result");
  const status = result.answer_status || "failed";
  const badge = status === "generated" ? statusBadge(status, "AI 已生成") : status === "not_generated" ? statusBadge(status, "未调用 provider") : status === "privacy_blocked" ? statusBadge(status, "隐私阻断") : statusBadge(status, "回答失败");
  const sections = (result.answer && result.answer.answer_sections || []).map((section) => `<li><span class="conversation-kind">${escapeHtml(section.kind)}</span><p>${escapeHtml(section.text)}</p><small>引用版本：${escapeHtml((section.cited_version_ids || []).join(" · ") || "无")}${section.memory_entry_ids ? ` · 个人记忆：${escapeHtml(section.memory_entry_ids.join(" · "))}` : ""}</small></li>`).join("");
  node.innerHTML = `<div class="conversation-status">${badge}${result.reason ? `<span>${escapeHtml(result.reason)}</span>` : ""}${result.error ? `<span class="error-copy">${escapeHtml(result.error)}</span>` : ""}</div>${sections ? `<div class="answer-sections"><h3>结构化回答</h3><ul>${sections}</ul></div>` : ""}${renderEvidenceList("全球原始证据", result.global_evidence, "global")}${renderEvidenceList("个人记忆（只读）", result.personal_memory, "personal")}${result.analysis_context?.length ? `<details class="analysis-context"><summary>查看已归档分析上下文</summary><pre>${escapeHtml(JSON.stringify(result.analysis_context, null, 2))}</pre></details>` : ""}`;
}

async function submitConversation(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const question = $("#conversation-question").value.trim();
  const button = $("#conversation-submit");
  if (!question) return;
  button.disabled = true;
  $("#conversation-result").innerHTML = '<div class="loading-state">正在先检索全球原始证据，再读取个人记忆…</div>';
  try { renderConversation(await fetchJson("/api/conversation/query", { method: "POST", body: JSON.stringify({ question }) })); }
  catch (error) { $("#conversation-result").innerHTML = `<div class="error-state">对话请求失败：${escapeHtml(error.message)}</div>`; }
  finally { button.disabled = false; }
}

function tick() { $("#clock").textContent = new Date().toLocaleTimeString("zh-CN", { hour12: false }); }
$("#refresh-button").addEventListener("click", () => { loadRadar(); loadReports(); loadWeakSignals(); loadWorldChangeSurfaces(); });
$("#conversation-form").addEventListener("submit", submitConversation);
tick();
setInterval(tick, 1000);
loadRadar();
loadReports();
loadWeakSignals();
loadWorldChangeSurfaces();
