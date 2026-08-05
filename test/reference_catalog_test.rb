# frozen_string_literal: true

require "minitest/autorun"
require_relative "../reference/query"

class ReferenceCatalogTest < Minitest::Test
  ALLOWED_DISPOSITIONS = %w[shortlist reference_only defer].freeze
  ALLOWED_PRIORITIES = %w[now next later].freeze
  ALLOWED_MODES = %w[
    evaluate_code_reuse evaluate_dependency file_level_review
    study_then_reimplement reference_only
  ].freeze

  def catalog
    @catalog ||= Reference::Catalog.load
  end

  def projects
    catalog.projects
  end

  def test_project_and_component_ids_are_globally_unique
    project_ids = projects.map { |project| project.fetch("id") }
    component_ids = projects.flat_map do |project|
      project.fetch("components").map { |component| component.fetch("id") }
    end

    assert_equal project_ids.uniq, project_ids
    assert_equal component_ids.uniq, component_ids
    assert_empty project_ids & component_ids
  end

  def test_repository_urls_and_required_project_fields
    projects.each do |project|
      assert_equal "https://github.com/#{project.fetch('repository')}", project.fetch("url")
      assert_includes ALLOWED_DISPOSITIONS, project.fetch("disposition")
      refute_empty project.fetch("categories")
      refute_empty project.fetch("license").fetch("expression")
      assert project.fetch("reviewSnapshot").fetch("stars").is_a?(Integer)
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, project.fetch("reviewSnapshot").fetch("lastPushedAt"))
    end
  end

  def test_components_have_actionable_routing_and_controls
    projects.each do |project|
      project.fetch("components").each do |component|
        assert_includes ALLOWED_PRIORITIES, component.fetch("priority")
        assert_includes ALLOWED_MODES, component.fetch("adoptionMode")
        refute_empty component.fetch("targets")
        refute_empty component.fetch("triggers")
        refute_empty component.fetch("borrow")
        refute_empty component.fetch("mustPreserve")
      end
    end
  end

  def test_copyleft_projects_are_not_marked_for_direct_code_reuse
    projects.each do |project|
      next unless project.fetch("license").fetch("expression").match?(/(?:A?GPL)-3\.0/)

      assert_equal "reference_only", project.fetch("disposition")
      project.fetch("components").each do |component|
        refute_includes %w[evaluate_code_reuse evaluate_dependency], component.fetch("adoptionMode")
      end
    end
  end

  def test_target_and_priority_queries_return_routed_components
    connector_projects = catalog.query(target: "M1.source_connectors")
    assert_includes connector_projects.map { |project| project.fetch("id") }, "newsnow"
    assert_includes connector_projects.map { |project| project.fetch("id") }, "freshrss"

    now_components = catalog.query(priority: "now").flat_map do |project|
      catalog.matching_components(project, priority: "now")
    end
    assert now_components.all? { |component| component.fetch("priority") == "now" }
    assert_operator now_components.length, :>=, 3
  end

  def test_personalized_projects_retain_neutral_radar_warning
    auto_news = projects.find { |project| project.fetch("id") == "auto_news" }
    controls = auto_news.fetch("components").flat_map { |component| component.fetch("mustPreserve") }
    assert controls.any? { |control| control.include?("Personal") }

    trendradar = projects.find { |project| project.fetch("id") == "trendradar" }
    controls = trendradar.fetch("components").flat_map { |component| component.fetch("mustPreserve") }
    assert controls.any? { |control| control.include?("Personal") }
  end
end
