# frozen_string_literal: true

require_relative "m1_readiness"

module M3
  module M3Readiness
    module_function

    def evaluate(acceptance_plan:, coverage:, root: Dir.pwd)
      M1::M1Readiness.evaluate(
        acceptance_plan: acceptance_plan,
        coverage: coverage,
        root: root,
        phases: ["M3"]
      )
    end
  end
end
