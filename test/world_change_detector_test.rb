# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/world_change_detector"

class WorldChangeDetectorTest < Minitest::Test
  NOW = Time.parse("2026-08-13T00:00:00Z").freeze
  PROPOSITION = "ai chip deployment"

  def setup
    @detector = WorldChangeDetector.new
  end

  def item(id, publisher, channel: nil, proposition: PROPOSITION, title: "AI chip deployment", summary: "Independent report", published_at: "2026-08-12T01:00:00Z", query: false, exploration: false, contradicting: false, item_key: id, language: "en", concept_mapping: nil, label: nil)
    {
      "version_id" => id,
      "item_key" => item_key,
      "publisher_id" => publisher,
      "publisher_name" => "Publisher #{publisher}",
      "publisher_identity_status" => "configured",
      "source_id" => "source-#{id}",
      "source_kind" => "editorial",
      "source_url" => "https://example.test/#{id}",
      "language" => language,
      "title" => title,
      "summary" => summary,
      "published_at" => published_at,
      "query_conditioned" => query,
      "analysis_policy" => exploration ? "exploration_only" : "signal_eligible",
      "contradicting" => contradicting
    }.tap do |row|
      row["proposition_key"] = proposition unless proposition.nil?
      row["channel"] = channel unless channel.nil?
      row["concept_mapping"] = concept_mapping unless concept_mapping.nil?
      row["label"] = label unless label.nil?
    end
  end

  def candidates(rows)
    @detector.analyze(items: rows, now: NOW)
  end

  def candidate(rows)
    candidates(rows).fetch(0)
  end

  def test_single_publisher_never_qualifies
    rows = [
      item("p1-a", "p1", channel: "technical_capability"),
      item("p1-b", "p1", channel: "technical_capability", title: "AI chip deployment update")
    ]
    assert_empty candidates(rows)
  end

  def test_same_publisher_rewrites_are_deduplicated_and_do_not_inflate_independence
    rows = [
      item("p1-old", "p1", channel: "technical_capability", title: "AI chip deployment first report", published_at: "2026-08-12T01:00:00Z"),
      item("p1-new", "p1", channel: "technical_capability", title: "AI chip deployment rewrite", published_at: "2026-08-12T02:00:00Z"),
      item("p2", "p2", channel: "technical_capability", published_at: "2026-08-12T03:00:00Z")
    ]
    result = candidate(rows)
    assert_equal 2, result.fetch("qualifying_publisher_count")
    assert_equal %w[p1 p2], result.fetch("qualifying_publisher_ids")
    assert_equal %w[p1-new p2], result.fetch("channels").fetch("technical_capability").fetch("version_ids")
    assert_equal %w[p1-new p2], result.fetch("qualifying_version_ids")
    assert_includes result.fetch("alternative_explanations").join(" "), "多标题"
  end

  def test_query_conditioned_rows_cannot_qualify_alone_but_remain_traceable_support
    query_only = [
      item("q1", "q1", channel: "public_discussion", query: true),
      item("q2", "q2", channel: "public_discussion", query: true)
    ]
    assert_empty candidates(query_only)

    result = candidate([
      item("p1", "p1", channel: "technical_capability"),
      item("p2", "p2", channel: "technical_capability"),
      item("q3", "q3", channel: "public_discussion", query: true)
    ])
    baseline = candidate([
      item("p1", "p1", channel: "technical_capability"),
      item("p2", "p2", channel: "technical_capability")
    ])
    assert_equal baseline.fetch("candidate_key"), result.fetch("candidate_key")
    assert_equal 2, result.fetch("qualifying_publisher_count")
    assert_equal 1, result.fetch("query_conditioned_evidence_count")
    support = result.fetch("channels").fetch("public_discussion").fetch("supporting_evidence")
    assert_equal ["q3"], support.map { |row| row.fetch("version_id") }
    assert_equal "query_conditioned_support", support.fetch(0).fetch("lineage_role")
  end

  def test_exploration_rows_cannot_qualify_alone
    rows = [
      item("e1", "e1", channel: "technical_capability", exploration: true),
      item("e2", "e2", channel: "technical_capability", exploration: true)
    ]
    assert_empty candidates(rows)
  end

  def test_discussion_only_candidate_is_not_convergence
    result = candidate([
      item("d1", "p1", channel: "public_discussion"),
      item("d2", "p2", channel: "public_discussion")
    ])
    assert_equal "candidate", result.fetch("candidate_status")
    assert_equal 1, result.fetch("channel_count")
    assert_equal ["public_discussion"], result.fetch("channels").select { |_key, value| !value.fetch("version_ids").empty? }.keys
    assert_equal (WorldChangeDetector::CHANNELS - ["public_discussion"]), result.fetch("missing_channels")
  end

  def test_two_channels_upgrade_and_every_channel_has_version_lineage
    result = candidate([
      item("t1", "p1", channel: "technical_capability"),
      item("t2", "p2", channel: "technical_capability"),
      item("c1", "p3", channel: "capital_commitment")
    ])
    assert_equal "convergence_candidate", result.fetch("candidate_status")
    assert_equal 2, result.fetch("channel_count")
    %w[technical_capability capital_commitment].each do |channel|
      evidence = result.fetch("channels").fetch(channel).fetch("evidence")
      refute_empty evidence
      assert evidence.all? { |row| row.fetch("version_id") && !row.fetch("version_id").empty? }
    end
  end

  def test_contradicting_evidence_and_next_verification_are_preserved
    result = candidate([
      item("p1", "p1", channel: "technical_capability"),
      item("p2", "p2", channel: "technical_capability"),
      item("x1", "p3", channel: "policy_action", title: "AI chip deployment denied", contradicting: true)
    ])
    contradiction_ids = result.fetch("contradicting_evidence").map { |row| row.fetch("version_id") }
    assert_equal ["x1"], contradiction_ids
    assert_includes result.fetch("channels").fetch("policy_action").fetch("contradicting_evidence").map { |row| row.fetch("version_id") }, "x1"
    assert result.fetch("alternative_explanations").any? { |text| text.include?("矛盾") }
    assert result.fetch("next_verification").any? { |text| text.include?("contradicting") }
  end

  def test_discussion_without_action_does_not_claim_world_change
    result = candidate([
      item("d1", "p1", channel: "public_discussion", title: "AI chip deployment debate"),
      item("d2", "p2", channel: "public_discussion", title: "AI chip deployment attention")
    ])
    refute_equal "convergence_candidate", result.fetch("candidate_status")
    assert_empty result.fetch("channels").fetch("policy_action").fetch("version_ids")
    assert_empty result.fetch("channels").fetch("real_world_adoption").fetch("version_ids")
  end

  def test_input_order_is_deterministic_and_no_prediction_score_or_confidence_fields_exist
    rows = [
      item("t1", "p1", channel: "technical_capability"),
      item("t2", "p2", channel: "technical_capability"),
      item("c1", "p3", channel: "capital_commitment")
    ]
    forward = candidates(rows)
    assert_equal forward, candidates(rows.reverse)
    refute forward.fetch(0).keys.any? { |key| %w[score confidence prediction forecast].include?(key) }
  end

  def test_unrelated_zambia_election_chip_and_shipwreck_materials_do_not_aggregate
    rows = [
      item("z1", "zambia-a", channel: "policy_action", title: "Zambia election commission sets voting timetable", proposition: "zambia election"),
      item("z2", "zambia-b", channel: "policy_action", title: "Zambia election candidates prepare for polls", proposition: "zambia election"),
      item("a1", "chip-a", channel: "technical_capability", title: "AI chip benchmark sets new record", proposition: "ai chip benchmark"),
      item("a2", "chip-b", channel: "technical_capability", title: "AI chip prototype passes validation", proposition: "ai chip benchmark"),
      item("s1", "ship-a", channel: "public_discussion", title: "Drought exposes Nazi-era shipwrecks beneath Danube", proposition: "danube shipwreck"),
      item("s2", "ship-b", channel: "public_discussion", title: "Danube water levels reveal wartime wrecks", proposition: "danube shipwreck")
    ]
    results = candidates(rows)
    assert_equal 3, results.length
    labels = results.map { |result| result.fetch("label") }
    assert labels.all? { |label| label.length <= WorldChangeDetector::MAX_LABEL_CHARS }
    refute labels.any? { |label| label.match?(/zambia.*chip|chip.*shipwreck|election.*danube/i) }
  end

  def test_complete_link_rejects_transitive_bridge
    rows = [
      item("a1", "a-1", proposition: nil, title: "Alpha Nova 7 benchmark result"),
      item("a2", "a-2", proposition: nil, title: "Alpha Nova 7 benchmark confirmed"),
      item("b1", "b-1", proposition: nil, title: "Alpha Nova Beta 8 benchmark result"),
      item("b2", "b-2", proposition: nil, title: "Alpha Nova Beta 8 benchmark confirmed"),
      item("c1", "c-1", proposition: nil, title: "Beta Gamma 8 contract result"),
      item("c2", "c-2", proposition: nil, title: "Beta Gamma 8 contract confirmed")
    ]
    results = candidates(rows)
    assert_equal 2, results.length
    memberships = results.map { |result| result.fetch("qualifying_version_ids") }
    assert memberships.any? { |ids| (ids & %w[a1 a2 b1 b2]).length == 4 }
    assert memberships.any? { |ids| (ids & %w[c1 c2]).length == 2 }
    refute memberships.any? { |ids| ids.sort == %w[a1 a2 b1 b2 c1 c2] }
  end

  def test_cross_language_requires_provider_backed_mapping
    english = item("en-1", "publisher-en", language: "en", proposition: "shared proposition", title: "Shared proposition in English")
    chinese = item("zh-1", "publisher-zh", language: "zh-CN", proposition: "shared proposition", title: "同一命题的中文材料")
    assert_empty candidates([english, chinese])

    mapping = {
      "canonical_concept_key" => "concept:shared-proposition",
      "provider" => "fixture",
      "model" => "concept-v1",
      "prompt_version" => "prompt-v1",
      "input_hash" => "input-hash",
      "output_hash" => "output-hash",
      "relation" => "translation_equivalent"
    }
    result = candidate([
      english.merge("concept_mapping" => mapping),
      chinese.merge("concept_mapping" => mapping)
    ])
    assert_equal %w[publisher-en publisher-zh], result.fetch("qualifying_publisher_ids")
  end

  def test_same_item_versions_keep_only_latest_observation
    rows = [
      item("old-version", "p1", title: "AI chip benchmark old", item_key: "same-item", published_at: "2026-08-12T01:00:00Z"),
      item("new-version", "p1", title: "AI chip benchmark new", item_key: "same-item", published_at: "2026-08-12T02:00:00Z"),
      item("other", "p2", title: "AI chip benchmark independently tested")
    ]
    result = candidate(rows)
    assert_includes result.fetch("qualifying_version_ids"), "new-version"
    refute_includes result.fetch("qualifying_version_ids"), "old-version"
  end

  def test_generic_launch_plan_and_announces_do_not_infer_action_channels
    rows = [
      item("g1", "p1", channel: nil, proposition: "zambia election", title: "Zambia election launch plan announced"),
      item("g2", "p2", channel: nil, proposition: "zambia election", title: "Zambia election plan announced")
    ]
    result = candidate(rows)
    assert_equal ["public_discussion"], result.fetch("channels").select { |_channel, value| !value.fetch("version_ids").empty? }.keys
  end

  def test_numeric_and_generic_headlines_never_form_candidates
    rows = [
      item("n1", "p1", proposition: nil, title: "2026"),
      item("n2", "p2", proposition: nil, title: "2026"),
      item("g1", "p3", proposition: nil, title: "Fight used"),
      item("g2", "p4", proposition: nil, title: "Fight used")
    ]
    assert_empty candidates(rows)
  end

  def test_capital_requires_amount_and_commitment_term
    weak = [
      item("c1", "p1", channel: nil, proposition: nil, title: "Company discusses capital plans"),
      item("c2", "p2", channel: nil, proposition: nil, title: "Company reports investment news")
    ]
    assert_empty candidates(weak)
    strong = [
      item("c3", "p1", channel: nil, proposition: "nova chip", title: "Nova chip raises $25 million investment"),
      item("c4", "p2", channel: nil, proposition: "nova chip", title: "Nova chip secures $25 million funding")
    ]
    refute_empty candidates(strong)
    assert_equal ["capital_commitment"], candidates(strong).first.fetch("channels").select { |_k, v| !v.fetch("version_ids").empty? }.keys
  end

  def test_cross_language_mapping_requires_shared_provider_metadata
    base = {
      "canonical_concept_key" => "concept:shared-proposition", "provider" => "fixture", "model" => "concept-v1",
      "prompt_version" => "prompt-v1", "input_hash" => "input-hash", "output_hash" => "output-hash", "relation" => "translation_equivalent"
    }
    english = item("map-en", "publisher-en", language: "en", proposition: nil, title: "Nova chip benchmark validated").merge("concept_mapping" => base)
    chinese = item("map-zh", "publisher-zh", language: "zh-CN", proposition: nil, title: "Nova chip benchmark validated").merge("concept_mapping" => base.merge("provider" => "other"))
    assert_empty candidates([english, chinese])
  end
end
