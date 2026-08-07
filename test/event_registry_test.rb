# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/event_registry"

class EventRegistryTest < Minitest::Test
  def registry
    @registry ||= M1::EventRegistry.build
  end

  def test_registry_is_deterministic_and_unsigned_until_governance_activation
    assert_equal registry, M1::EventRegistry.build
    assert_equal "m1.event-registry.v1", registry.fetch("schemaVersion")
    assert_equal "unsigned", registry.fetch("signatureStatus")
    assert_nil registry.fetch("manifestSignature")
    assert_equal 29, registry.fetch("eventTypes").length
  end

  def test_every_exclusive_event_has_closed_state_machine
    registry.fetch("eventTypes").select { |definition| definition.fetch("stateSemantics") == "exclusive_transition" }.each do |definition|
      states = definition.fetch("states").map { |state| state.fetch("stateKey") }
      assert_equal 1, states.count(definition.fetch("initialState"))
      definition.fetch("transitions").each do |transition|
        assert_includes states, transition.fetch("fromState")
        assert_includes states, transition.fetch("toState")
        assert_equal true, transition.fetch("typedGuardRequired")
      end
    end
  end

  def test_non_exclusive_events_cannot_smuggle_state_machine_fields
    malformed = registry.fetch("eventTypes").map(&:dup)
    malformed.reject! { |definition| definition.fetch("stateSemantics") == "exclusive_transition" }
    malformed.first["states"] = []
    assert_raises(M1::EventRegistry::Error) { M1::EventRegistry.validate_event_types!(malformed) }
  end
end
