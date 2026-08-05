# frozen_string_literal: true

require "json"
require "optparse"

module Reference
  class Catalog
    CATALOG_PATH = File.expand_path("catalog.json", __dir__)

    attr_reader :document

    def self.load(path = CATALOG_PATH)
      new(JSON.parse(File.read(path)))
    end

    def initialize(document)
      @document = document
    end

    def projects
      document.fetch("projects")
    end

    def query(filters = {})
      projects.select do |project|
        matches_project_filters?(project, filters) &&
          matches_component_filters?(project, filters)
      end
    end

    def matching_components(project, filters = {})
      component_filters = filters.select do |key, _value|
        %i[target priority mode component].include?(key)
      end
      return project.fetch("components") if component_filters.empty?

      project.fetch("components").select do |component|
        component_filters.all? do |key, value|
          case key
          when :target
            component.fetch("targets").any? { |target| contains?(target, value) }
          when :priority
            contains?(component.fetch("priority"), value)
          when :mode
            contains?(component.fetch("adoptionMode"), value)
          when :component
            contains?(component.fetch("id"), value)
          end
        end
      end
    end

    private

    def matches_project_filters?(project, filters)
      filters.all? do |key, value|
        case key
        when :project
          contains?(project.fetch("id"), value) || contains?(project.fetch("repository"), value)
        when :category
          project.fetch("categories").any? { |category| contains?(category, value) }
        when :license
          contains?(project.fetch("license").fetch("expression"), value)
        when :disposition
          contains?(project.fetch("disposition"), value)
        when :search
          contains?(JSON.generate(project), value)
        when :target, :priority, :mode, :component
          true
        else
          false
        end
      end
    end

    def matches_component_filters?(project, filters)
      matching_components(project, filters).any?
    end

    def contains?(actual, expected)
      actual.to_s.downcase.include?(expected.to_s.downcase)
    end
  end

  class CLI
    def initialize(argv, output: $stdout)
      @argv = argv
      @output = output
      @filters = {}
      @json = false
    end

    def run
      parser.parse!(@argv)
      catalog = Catalog.load
      projects = catalog.query(@filters)

      if @json
        @output.puts JSON.pretty_generate(
          projects.map do |project|
            project.merge("components" => catalog.matching_components(project, @filters))
          end
        )
      else
        print_human(catalog, projects)
      end
      projects.empty? ? 1 : 0
    end

    private

    def parser
      OptionParser.new do |options|
        options.banner = "Usage: ruby reference/query.rb [filters]"
        options.on("--project VALUE", "Project ID or owner/repository") { |value| @filters[:project] = value }
        options.on("--component VALUE", "Component ID") { |value| @filters[:component] = value }
        options.on("--category VALUE", "Project category") { |value| @filters[:category] = value }
        options.on("--target VALUE", "Local target such as M1.source_connectors") { |value| @filters[:target] = value }
        options.on("--priority VALUE", "Adoption priority: now, next, later") { |value| @filters[:priority] = value }
        options.on("--mode VALUE", "Adoption mode") { |value| @filters[:mode] = value }
        options.on("--license VALUE", "License expression") { |value| @filters[:license] = value }
        options.on("--disposition VALUE", "shortlist, reference_only, or defer") { |value| @filters[:disposition] = value }
        options.on("--search VALUE", "Full-text search over the catalog") { |value| @filters[:search] = value }
        options.on("--json", "Emit machine-readable JSON") { @json = true }
        options.on("-h", "--help", "Show help") do
          @output.puts options
          exit 0
        end
      end
    end

    def print_human(catalog, projects)
      projects.each do |project|
        license = project.fetch("license")
        @output.puts [
          project.fetch("id"),
          project.fetch("disposition"),
          license.fetch("expression"),
          project.fetch("url")
        ].join(" | ")

        catalog.matching_components(project, @filters).each do |component|
          @output.puts "  - #{component.fetch('id')} [#{component.fetch('priority')}] " \
                       "#{component.fetch('adoptionMode')} -> #{component.fetch('targets').join(', ')}"
        end
      end
    end
  end
end

exit Reference::CLI.new(ARGV).run if $PROGRAM_NAME == __FILE__
