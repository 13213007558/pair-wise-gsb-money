# frozen_string_literal: true

class Money
  class TaxCalculator
    # Exact rational rounding to BigDecimal-compatible monetary steps.
    class Rounding
      MODES = {
        BigDecimal::ROUND_UP => true,
        BigDecimal::ROUND_DOWN => true,
        BigDecimal::ROUND_CEILING => true,
        BigDecimal::ROUND_FLOOR => true,
        BigDecimal::ROUND_HALF_UP => true,
        BigDecimal::ROUND_HALF_DOWN => true,
        BigDecimal::ROUND_HALF_EVEN => true,
      }.freeze

      def self.round(value, step, mode)
        new(value, step, mode).round
      end

      def self.validate_step(value, label)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{label} must be a positive Integer"
        end

        value
      end

      def self.validate_mode(value)
        unless MODES.key?(value)
          raise ArgumentError, "rounding mode #{value.inspect} is not supported"
        end

        value
      end

      def initialize(value, step, mode)
        @value = value
        @step = step
        @mode = mode
      end

      def round
        floor, remainder = scaled.divmod(1)
        rounded = remainder.zero? ? floor : round_non_integer(floor, remainder)
        Integer(rounded) * @step
      end

      private

      def scaled
        @value / @step
      end

      def round_non_integer(floor, remainder)
        half_comparison = remainder <=> 1 / 2r

        case @mode
        when BigDecimal::ROUND_UP
          floor.negative? ? floor : floor + 1
        when BigDecimal::ROUND_DOWN
          floor.negative? ? floor + 1 : floor
        when BigDecimal::ROUND_CEILING
          floor + 1
        when BigDecimal::ROUND_FLOOR
          floor
        when BigDecimal::ROUND_HALF_UP
          round_half(floor, half_comparison) { floor.negative? ? floor : floor + 1 }
        when BigDecimal::ROUND_HALF_DOWN
          round_half(floor, half_comparison) { floor.negative? ? floor + 1 : floor }
        when BigDecimal::ROUND_HALF_EVEN
          round_half(floor, half_comparison) { floor.even? ? floor : floor + 1 }
        end
      end

      def round_half(floor, half_comparison)
        return floor if half_comparison.negative?
        return floor + 1 if half_comparison.positive?

        yield
      end
    end
  end
end
