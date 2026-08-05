# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/provider_response_set"

class ProviderResponseSetTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("../schema/fixtures", __dir__)

  def valid_document
    JSON.parse(File.read(File.join(FIXTURE_ROOT, "provider-response-set.valid.json")))
  end

  def test_valid_response_set_closes
    assert M1::ProviderResponseSet.new(valid_document).validate!
  end

  def test_omitted_member_blocks_closure
    document = JSON.parse(
      File.read(File.join(FIXTURE_ROOT, "provider-response-set.omitted-member.invalid.json"))
    )

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/members without decisions/, error.message)
  end

  def test_non_success_member_cannot_have_output
    document = valid_document
    failed_decision = document.fetch("decisions").first
    successful_output = document.fetch("outputs").first.dup
    successful_output["artifactId"] = "00000000-0000-4000-8000-000000000099"
    successful_output["decisionId"] = failed_decision.fetch("decisionId")
    document.fetch("outputs") << successful_output

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/non-success decision has output/, error.message)
  end

  def test_open_continuation_blocks_closure
    document = valid_document
    document.fetch("decisions").first["continuationClosed"] = false

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/continuation remains open/, error.message)
  end

  def test_member_set_hash_is_recomputed
    document = valid_document
    document.fetch("expectedMembers").first["memberKey"] = "member-tampered"

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/memberSetHash mismatch/, error.message)
  end

  def test_member_set_hash_covers_unit_and_page_projection
    replacements = {
      "unitId" => "00000000-0000-4000-8000-000000000098",
      "pageKey" => "tampered-page"
    }
    replacements.each do |field, replacement|
      document = valid_document
      document.fetch("expectedMembers").first[field] = replacement

      error = assert_raises(M1::ClosureError) do
        M1::ProviderResponseSet.new(document).validate!
      end
      assert_match(/memberSetHash mismatch/, error.message)
    end
  end

  def test_malformed_member_fails_closed
    document = valid_document
    document.fetch("expectedMembers")[0] = "not-an-object"

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/expectedMembers\[0\] must be an object/, error.message)
  end

  def test_every_member_omission_is_blocked
    valid_document.fetch("expectedMembers").each do |member|
      document = valid_document
      unit_id = member.fetch("unitId")
      removed_ids = document.fetch("decisions")
                            .select { |decision| decision["unitId"] == unit_id }
                            .map { |decision| decision["decisionId"] }
      document.fetch("decisions").reject! { |decision| removed_ids.include?(decision["decisionId"]) }
      document.fetch("receipts").reject! { |receipt| removed_ids.include?(receipt["decisionId"]) }
      document.fetch("outputs").reject! { |output| removed_ids.include?(output["decisionId"]) }

      error = assert_raises(M1::ClosureError) do
        M1::ProviderResponseSet.new(document).validate!
      end
      assert_match(/members without decisions/, error.message)
    end
  end

  def test_success_requires_authenticated_receipt
    document = valid_document
    document["receipts"] = []

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/success decision lacks receipt/, error.message)
  end

  def test_receipt_must_bind_the_same_member
    document = valid_document
    document.fetch("receipts").first["unitId"] = document.fetch("expectedMembers").first.fetch("unitId")

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/receipt unit does not match decision/, error.message)
  end

  def test_unknown_nested_field_is_rejected
    document = valid_document
    document.fetch("responseSet")["hiddenControl"] = "unexpected"

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/responseSet has unknown keys/, error.message)
  end

  def test_invalid_uuid_is_rejected
    document = valid_document
    document.fetch("decisions").first["decisionId"] = "not-a-uuid"

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/decisionId must be a UUID/, error.message)
  end

  def test_invalid_close_time_is_rejected
    document = valid_document
    document.fetch("responseSet")["closedAt"] = "yesterday"

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/closedAt must be an ISO-8601 date-time/, error.message)
  end

  def test_array_order_does_not_change_closed_set_semantics
    document = valid_document
    %w[expectedMembers decisions receipts outputs].each do |key|
      document.fetch(key).reverse!
    end

    assert M1::ProviderResponseSet.new(document).validate!
  end

  def test_duplicate_json_keys_are_rejected_before_validation
    json = '{"schemaVersion":"m1.0","schemaVersion":"shadow"}'

    assert_raises(M1::DuplicateKeyError) do
      M1::ProviderResponseSet.parse(json)
    end
  end

  def test_cross_type_identity_collision_is_rejected
    document = valid_document
    document.fetch("decisions").first["decisionId"] =
      document.fetch("expectedMembers").first.fetch("unitId")

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(document).validate!
    end
    assert_match(/global identity collision/, error.message)
  end

  def test_large_member_universe_closes_and_any_omission_blocks
    document = build_large_document(128)
    assert M1::ProviderResponseSet.new(document).validate!

    omitted = Marshal.load(Marshal.dump(document))
    removed = omitted.fetch("decisions").delete_at(63)
    omitted.fetch("receipts").reject! { |row| row["decisionId"] == removed["decisionId"] }
    omitted.fetch("outputs").reject! { |row| row["decisionId"] == removed["decisionId"] }

    error = assert_raises(M1::ClosureError) do
      M1::ProviderResponseSet.new(omitted).validate!
    end
    assert_match(/members without decisions/, error.message)
  end

  private

  def build_large_document(size)
    members = []
    decisions = []
    receipts = []
    outputs = []

    size.times do |index|
      number = index + 1
      unit_id = format("10000000-0000-4000-8000-%012d", number)
      decision_id = format("20000000-0000-4000-8000-%012d", number)
      member = {
        "unitId" => unit_id,
        "memberKey" => "member-#{number}",
        "ordinal" => number,
        "pageKey" => "page-#{(index / 16) + 1}",
        "continuationExpected" => index < size - 1
      }
      members << member

      if number.odd?
        decisions << {
          "decisionId" => decision_id,
          "unitId" => unit_id,
          "outcome" => "failed",
          "reasonCode" => "PROVIDER_MEMBER_FAILED",
          "continuationClosed" => true
        }
      else
        receipt_id = format("30000000-0000-4000-8000-%012d", number)
        decisions << {
          "decisionId" => decision_id,
          "unitId" => unit_id,
          "outcome" => "success",
          "continuationClosed" => true
        }
        receipts << {
          "receiptId" => receipt_id,
          "decisionId" => decision_id,
          "unitId" => unit_id,
          "capturedExchangeId" => "exchange-#{number}",
          "authenticatedPeer" => "provider.example",
          "rawResponseHash" => Digest::SHA256.hexdigest("response-#{number}")
        }
        outputs << {
          "artifactId" => format("40000000-0000-4000-8000-%012d", number),
          "decisionId" => decision_id,
          "receiptId" => receipt_id,
          "rawContentHash" => Digest::SHA256.hexdigest("content-#{number}"),
          "storageUri" => "blob://provider-output/member-#{number}"
        }
      end
    end

    {
      "schemaVersion" => "m1.0",
      "responseSet" => {
        "responseSetId" => "50000000-0000-4000-8000-000000000001",
        "invocationId" => "50000000-0000-4000-8000-000000000002",
        "profileId" => "50000000-0000-4000-8000-000000000003",
        "expectedMemberCount" => size,
        "memberSetHash" => M1::ProviderResponseSet.member_set_hash(members),
        "closedAt" => "2026-08-05T00:00:00Z"
      },
      "expectedMembers" => members,
      "decisions" => decisions,
      "receipts" => receipts,
      "outputs" => outputs
    }
  end
end
