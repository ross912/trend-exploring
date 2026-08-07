# frozen_string_literal: true

module M1
  module BitemporalQuery
    class Error < StandardError; end

    IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/

    module_function

    def event_as_known
      <<~SQL
        SELECT e.*
          FROM event_base AS e
         WHERE e.event_system_available_at <= :query_system_as_of
           AND (
             :valid_time_as_of IS NULL
             OR e.valid_time_status <> 'known'
             OR e.valid_effective_at <= :valid_time_as_of
           )
      SQL
    end

    def operational_record_as_known(table:)
      table = safe_identifier(table)
      <<~SQL
        SELECT r.*
          FROM #{table} AS r
         WHERE r.system_available_at <= :query_system_as_of
      SQL
    end

    def bitemporal_version_as_known(table:)
      table = safe_identifier(table)
      <<~SQL
        SELECT v.*
          FROM #{table} AS v
         WHERE v.system_from <= :query_system_as_of
           AND (v.projected_system_to IS NULL OR :query_system_as_of < v.projected_system_to)
           AND v.valid_from <= :valid_time_as_of
           AND (v.projected_valid_to IS NULL OR :valid_time_as_of < v.projected_valid_to)
      SQL
    end

    def derived_record_as_known(table:)
      table = safe_identifier(table)
      <<~SQL
        SELECT d.*
          FROM #{table} AS d
         WHERE d.system_available_at <= :query_system_as_of
           AND d.as_of <= :query_system_as_of
      SQL
    end

    def templates
      {
        "event_as_known" => event_as_known,
        "operational_record_as_known" => operational_record_as_known(table: "record_table"),
        "bitemporal_version_as_known" => bitemporal_version_as_known(table: "version_table"),
        "derived_record_as_known" => derived_record_as_known(table: "derived_table")
      }
    end

    def validate!(template_set = templates)
      template_set.each do |name, query|
        raise Error, "#{name} lacks system as-of filter" unless query.include?(":query_system_as_of")
        raise Error, "#{name} lacks system availability predicate" unless query.match?(/system_(?:available_at|from)/)
        raise Error, "#{name} uses mutable current-state shortcut" if query.match?(/\b(?:current_|MAX\s*\(|NOW\s*\()/i)
      end
      true
    end

    def safe_identifier(identifier)
      raise Error, "unsafe table identifier: #{identifier}" unless IDENTIFIER.match?(identifier.to_s)

      identifier
    end
  end
end
