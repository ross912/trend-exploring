# frozen_string_literal: true

require "digest"
require "json"
require "time"

module M1
  class DuplicateKeyError < JSON::ParserError; end

  class StrictHash < Hash
    def []=(key, value)
      raise DuplicateKeyError, "duplicate JSON key: #{key}" if key?(key)
      super
    end
  end

  class ClosureError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors.freeze
      super(errors.join("; "))
    end
  end

  class ProviderResponseSet
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    TOP_LEVEL_KEYS = %w[
      schemaVersion responseSet expectedMembers decisions receipts outputs
    ].freeze
    RESPONSE_SET_KEYS = %w[
      responseSetId invocationId profileId expectedMemberCount memberSetHash closedAt
    ].freeze
    MEMBER_KEYS = %w[
      unitId memberKey ordinal pageKey shardKey continuationExpected
    ].freeze
    DECISION_KEYS = %w[
      decisionId unitId outcome reasonCode continuationClosed
    ].freeze
    RECEIPT_KEYS = %w[
      receiptId decisionId unitId capturedExchangeId authenticatedPeer rawResponseHash
    ].freeze
    OUTPUT_KEYS = %w[
      artifactId decisionId receiptId rawContentHash storageUri
    ].freeze

    attr_reader :document

    def self.load(path)
      parse(File.read(path))
    end

    def self.parse(json)
      new(JSON.parse(json, object_class: StrictHash))
    end

    def self.member_set_hash(members)
      canonical_rows = members.sort_by { |member| member.fetch("ordinal") }
                              .map { |member| canonical_member_row(member) }
      Digest::SHA256.hexdigest(canonical_rows.join("\n"))
    end

    def self.canonical_member_row(member)
      [
        member.fetch("unitId"),
        utf8_hex(member.fetch("memberKey")),
        member.fetch("ordinal").to_s,
        utf8_hex(member["pageKey"]),
        utf8_hex(member["shardKey"]),
        member.fetch("continuationExpected") ? "1" : "0"
      ].join("|")
    end

    def self.utf8_hex(value)
      value.nil? ? "-" : value.encode("UTF-8").unpack("H*").first
    end

    def initialize(document)
      @document = document
    end

    def validate!
      errors = []
      validate_top_level(errors)
      return raise ClosureError, errors unless errors.empty?

      members = document.fetch("expectedMembers")
      decisions = document.fetch("decisions")
      receipts = document.fetch("receipts")
      outputs = document.fetch("outputs")

      validate_shapes(members, decisions, receipts, outputs, errors)
      raise ClosureError, errors unless errors.empty?

      validate_global_identity_uniqueness(members, decisions, receipts, outputs, errors)
      validate_member_universe(members, errors)
      validate_member_count(members, errors)
      validate_member_hash(members, errors)
      validate_decision_totality(members, decisions, errors)
      validate_terminal_artifacts(members, decisions, receipts, outputs, errors)

      raise ClosureError, errors unless errors.empty?

      true
    end

    private

    def validate_top_level(errors)
      unless document.is_a?(Hash)
        errors << "document must be an object"
        return
      end

      missing = TOP_LEVEL_KEYS - document.keys
      extra = document.keys - TOP_LEVEL_KEYS
      errors << "missing top-level keys: #{missing.join(',')}" unless missing.empty?
      errors << "unknown top-level keys: #{extra.join(',')}" unless extra.empty?
      errors << "schemaVersion must equal m1.0" unless document["schemaVersion"] == "m1.0"

      %w[expectedMembers decisions receipts outputs].each do |key|
        errors << "#{key} must be an array" unless document[key].is_a?(Array)
      end
      errors << "responseSet must be an object" unless document["responseSet"].is_a?(Hash)
    end

    def validate_member_universe(members, errors)
      errors << "expectedMembers must not be empty" if members.empty?
      assert_unique(members, "unitId", errors)
      assert_unique(members, "memberKey", errors)
      assert_unique(members, "ordinal", errors)

      ordinals = members.map { |member| member["ordinal"] }.sort
      expected = (1..members.length).to_a
      errors << "member ordinals must be contiguous from 1" unless ordinals == expected
    end

    def validate_global_identity_uniqueness(members, decisions, receipts, outputs, errors)
      response_set = document.fetch("responseSet")
      identities = [
        ["responseSet.responseSetId", response_set["responseSetId"]],
        ["responseSet.invocationId", response_set["invocationId"]],
        ["responseSet.profileId", response_set["profileId"]]
      ]
      members.each_with_index do |member, index|
        identities << ["expectedMembers[#{index}].unitId", member["unitId"]]
      end
      decisions.each_with_index do |decision, index|
        identities << ["decisions[#{index}].decisionId", decision["decisionId"]]
      end
      receipts.each_with_index do |receipt, index|
        identities << ["receipts[#{index}].receiptId", receipt["receiptId"]]
      end
      outputs.each_with_index do |output, index|
        identities << ["outputs[#{index}].artifactId", output["artifactId"]]
      end

      collisions = identities.group_by { |_path, identity| identity }
                             .select { |_identity, occurrences| occurrences.length > 1 }
      collisions.each do |identity, occurrences|
        errors << "global identity collision #{identity}: #{occurrences.map(&:first).join(',')}"
      end
    end

    def validate_shapes(members, decisions, receipts, outputs, errors)
      response_set = document.fetch("responseSet")
      assert_allowed_keys(response_set, RESPONSE_SET_KEYS, "responseSet", errors)
      %w[responseSetId invocationId profileId].each do |key|
        require_uuid(response_set, key, "responseSet", errors)
      end
      require_iso8601(response_set, "closedAt", "responseSet", errors)
      unless response_set["expectedMemberCount"].is_a?(Integer) && response_set["expectedMemberCount"] > 0
        errors << "responseSet.expectedMemberCount must be a positive integer"
      end
      unless sha256?(response_set["memberSetHash"])
        errors << "responseSet.memberSetHash must be a lowercase SHA-256 hex digest"
      end

      members.each_with_index do |member, index|
        unless member.is_a?(Hash)
          errors << "expectedMembers[#{index}] must be an object"
          next
        end
        assert_allowed_keys(member, MEMBER_KEYS, "expectedMembers[#{index}]", errors)
        require_uuid(member, "unitId", "expectedMembers[#{index}]", errors)
        require_string(member, "memberKey", "expectedMembers[#{index}]", errors)
        unless member["ordinal"].is_a?(Integer) && member["ordinal"] > 0
          errors << "expectedMembers[#{index}].ordinal must be a positive integer"
        end
        unless boolean?(member["continuationExpected"])
          errors << "expectedMembers[#{index}].continuationExpected must be boolean"
        end
        %w[pageKey shardKey].each do |optional_key|
          next unless member.key?(optional_key)
          require_string(member, optional_key, "expectedMembers[#{index}]", errors)
        end
      end

      decisions.each_with_index do |decision, index|
        unless decision.is_a?(Hash)
          errors << "decisions[#{index}] must be an object"
          next
        end
        assert_allowed_keys(decision, DECISION_KEYS, "decisions[#{index}]", errors)
        require_uuid(decision, "decisionId", "decisions[#{index}]", errors)
        require_uuid(decision, "unitId", "decisions[#{index}]", errors)
        require_string(decision, "outcome", "decisions[#{index}]", errors)
        unless boolean?(decision["continuationClosed"])
          errors << "decisions[#{index}].continuationClosed must be boolean"
        end
      end

      receipts.each_with_index do |receipt, index|
        unless receipt.is_a?(Hash)
          errors << "receipts[#{index}] must be an object"
          next
        end
        assert_allowed_keys(receipt, RECEIPT_KEYS, "receipts[#{index}]", errors)
        %w[receiptId decisionId unitId].each do |key|
          require_uuid(receipt, key, "receipts[#{index}]", errors)
        end
        %w[capturedExchangeId authenticatedPeer].each do |key|
          require_string(receipt, key, "receipts[#{index}]", errors)
        end
        errors << "receipts[#{index}].rawResponseHash must be SHA-256" unless sha256?(receipt["rawResponseHash"])
      end

      outputs.each_with_index do |output, index|
        unless output.is_a?(Hash)
          errors << "outputs[#{index}] must be an object"
          next
        end
        assert_allowed_keys(output, OUTPUT_KEYS, "outputs[#{index}]", errors)
        %w[artifactId decisionId receiptId].each do |key|
          require_uuid(output, key, "outputs[#{index}]", errors)
        end
        require_string(output, "storageUri", "outputs[#{index}]", errors)
        errors << "outputs[#{index}].rawContentHash must be SHA-256" unless sha256?(output["rawContentHash"])
        unless output["storageUri"].is_a?(String) && output["storageUri"].start_with?("blob://")
          errors << "outputs[#{index}].storageUri must use blob://"
        end
      end
    end

    def validate_member_count(members, errors)
      declared = document.fetch("responseSet")["expectedMemberCount"]
      errors << "expectedMemberCount must equal expectedMembers length" unless declared == members.length
    end

    def validate_member_hash(members, errors)
      declared = document.fetch("responseSet")["memberSetHash"]
      calculated = self.class.member_set_hash(members)
      errors << "memberSetHash mismatch: expected #{calculated}" unless declared == calculated
    end

    def validate_decision_totality(members, decisions, errors)
      assert_unique(decisions, "decisionId", errors)
      assert_unique(decisions, "unitId", errors)

      unit_ids = members.map { |member| member["unitId"] }
      decision_unit_ids = decisions.map { |decision| decision["unitId"] }
      missing = unit_ids - decision_unit_ids
      extra = decision_unit_ids - unit_ids
      errors << "members without decisions: #{missing.join(',')}" unless missing.empty?
      errors << "decisions for unknown members: #{extra.join(',')}" unless extra.empty?

      decisions.each do |decision|
        outcome = decision["outcome"]
        unless %w[success failed missing].include?(outcome)
          errors << "unknown decision outcome for #{decision['unitId']}"
          next
        end
        if outcome == "success" && decision.key?("reasonCode")
          errors << "success decision must not have reasonCode for #{decision['unitId']}"
        elsif outcome != "success" && blank?(decision["reasonCode"])
          errors << "#{outcome} decision requires reasonCode for #{decision['unitId']}"
        end
      end
    end

    def validate_terminal_artifacts(members, decisions, receipts, outputs, errors)
      assert_unique(receipts, "receiptId", errors)
      assert_unique(receipts, "decisionId", errors)
      assert_unique(outputs, "artifactId", errors)
      assert_unique(outputs, "decisionId", errors)
      assert_unique(outputs, "receiptId", errors)

      decisions_by_id = index_by(decisions, "decisionId")
      receipts_by_decision = index_by(receipts, "decisionId")
      outputs_by_decision = index_by(outputs, "decisionId")
      receipts_by_id = index_by(receipts, "receiptId")
      members_by_id = index_by(members, "unitId")

      decisions.each do |decision|
        decision_id = decision["decisionId"]
        unit_id = decision["unitId"]
        receipt = receipts_by_decision[decision_id]
        output = outputs_by_decision[decision_id]

        if decision["outcome"] == "success"
          errors << "success decision lacks receipt: #{decision_id}" unless receipt
          errors << "success decision lacks output: #{decision_id}" unless output
        else
          errors << "non-success decision has receipt: #{decision_id}" if receipt
          errors << "non-success decision has output: #{decision_id}" if output
        end

        if receipt && receipt["unitId"] != unit_id
          errors << "receipt unit does not match decision: #{decision_id}"
        end
        if output && receipt && output["receiptId"] != receipt["receiptId"]
          errors << "output receipt does not match decision receipt: #{decision_id}"
        end

        member = members_by_id[unit_id]
        if member && member["continuationExpected"] && decision["continuationClosed"] != true
          errors << "continuation remains open for member: #{unit_id}"
        end
      end

      receipts.each do |receipt|
        errors << "receipt references unknown decision: #{receipt['decisionId']}" unless decisions_by_id[receipt["decisionId"]]
      end
      outputs.each do |output|
        errors << "output references unknown decision: #{output['decisionId']}" unless decisions_by_id[output["decisionId"]]
        errors << "output references unknown receipt: #{output['receiptId']}" unless receipts_by_id[output["receiptId"]]
      end
    end

    def assert_unique(rows, key, errors)
      values = rows.map { |row| row[key] }
      duplicates = values.group_by { |value| value }
                         .select { |_value, occurrences| occurrences.length > 1 }
                         .keys
      errors << "duplicate #{key}: #{duplicates.join(',')}" unless duplicates.empty?
      errors << "missing #{key}" if values.any? { |value| blank?(value) }
    end

    def index_by(rows, key)
      rows.each_with_object({}) { |row, index| index[row[key]] = row }
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def boolean?(value)
      value == true || value == false
    end

    def require_string(row, key, prefix, errors)
      value = row[key]
      errors << "#{prefix}.#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?
    end

    def require_uuid(row, key, prefix, errors)
      value = row[key]
      errors << "#{prefix}.#{key} must be a UUID" unless value.is_a?(String) && value.match?(UUID_PATTERN)
    end

    def require_iso8601(row, key, prefix, errors)
      value = row[key]
      begin
        Time.iso8601(value)
      rescue ArgumentError, TypeError
        errors << "#{prefix}.#{key} must be an ISO-8601 date-time"
      end
    end

    def assert_allowed_keys(row, allowed, prefix, errors)
      unknown = row.keys - allowed
      errors << "#{prefix} has unknown keys: #{unknown.join(',')}" unless unknown.empty?
    end

    def sha256?(value)
      value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  path = ARGV.fetch(0)
  begin
    M1::ProviderResponseSet.load(path).validate!
    puts "CLOSED #{path}"
  rescue M1::ClosureError, JSON::ParserError, KeyError => e
    warn "BLOCKED #{path}: #{e.message}"
    exit 1
  end
end
