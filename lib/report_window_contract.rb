# frozen_string_literal: true

require "time"

module M2
  module ReportWindowContract
    class Error < StandardError; end

    module_function

    # Windows are hashes with :id, :start, and :end (Time values); intervals are [start, end).
    def assign(timestamp, windows)
      time = parse_time(timestamp)
      matches = windows.select do |window|
        time >= parse_time(window_value(window, :start)) && time < parse_time(window_value(window, :end))
      end
      raise Error, "timestamp belongs to zero or multiple nominal windows" unless matches.length == 1

      window_value(matches.first, :id)
    end

    def validate_windows!(windows)
      ordered = windows.sort_by { |window| parse_time(window_value(window, :start)) }
      ordered.each_cons(2) do |left, right|
        raise Error, "nominal windows must be non-overlapping and contiguous" unless
          parse_time(window_value(left, :end)) <= parse_time(window_value(right, :start))
      end
      ordered.each do |window|
        raise Error, "nominal window must have positive duration" unless
          parse_time(window_value(window, :start)) < parse_time(window_value(window, :end))
      end
      true
    end

    def classify_processing(nominal_window:, version_available_at:, actual_window_id:)
      available = parse_time(version_available_at)
      nominal_end = parse_time(window_value(nominal_window, :end))
      if available >= nominal_end
        { "reasonCode" => "PROCESSING_BACKFILL", "actualWindowId" => actual_window_id }
      else
        { "reasonCode" => nil, "actualWindowId" => window_value(nominal_window, :id) }
      end
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Error, "invalid timestamp: #{value.inspect}"
    end

    def window_value(window, key)
      return window.fetch(key) if window.key?(key)
      return window.fetch(key.to_s) if window.key?(key.to_s)

      raise Error, "nominal window field is missing: #{key}"
    end
    private_class_method :parse_time, :window_value
  end
end
