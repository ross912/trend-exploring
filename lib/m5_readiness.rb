# frozen_string_literal: true

require_relative "m1_readiness"

module M5
  module M5Readiness
    module_function

    def evaluate(acceptance_plan:, coverage:, root: Dir.pwd)
      M1::M1Readiness.evaluate(acceptance_plan: acceptance_plan, coverage: coverage, root: root, phases: ["M5"], blocking_modes: ["release"])
    end
  end
end
