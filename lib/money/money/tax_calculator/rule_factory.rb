# frozen_string_literal: true

class Money
  class TaxCalculator
    # Builds validated immutable tax rules from caller-provided hashes.
    class RuleFactory
      def self.build(taxes)
        taxes.each_with_index.map { |tax, index| new(tax, index).rule }
      end

      def initialize(tax, index)
        unless tax.is_a?(Hash)
          raise ArgumentError, "tax at index #{index} must be a Hash"
        end

        @tax = tax
        @index = index
        @name = normalize_name
      end

      def rule
        TaxRule.new(
          name: name,
          rate: rate,
          dependencies: dependencies,
          rounding_step: Rounding.validate_step(rounding_step, "tax #{name.inspect} rounding_step"),
          rounding_mode: Rounding.validate_mode(@tax[:rounding_mode]),
        )
      end

      private

      attr_reader :name

      def normalize_name
        name = @tax[:name]
        unless name.is_a?(Symbol) || name.is_a?(String)
          raise ArgumentError, "tax at index #{@index} must have a Symbol or String :name"
        end

        name = name.to_sym
        if name == :net
          raise ArgumentError, ":net is reserved and cannot be a tax name"
        end

        name
      end

      def rate
        rate = @tax[:rate]
        comparable = rate.respond_to?(:>=)
        unless rate.is_a?(Numeric) && rate.finite? && comparable && rate >= 0
          raise ArgumentError, "tax #{name.inspect} must have a finite non-negative Numeric :rate"
        end

        case rate
        when Rational
          rate
        when BigDecimal
          rate.to_r
        else
          BigDecimal(rate.to_s).to_r
        end
      end

      def dependencies
        dependencies = Array(@tax.key?(:base) ? @tax[:base] : :net).map do |dependency|
          normalize_dependency(dependency)
        end

        dependencies
      end

      def normalize_dependency(dependency)
        unless dependency.is_a?(Symbol) || dependency.is_a?(String)
          raise ArgumentError, "tax #{name.inspect} has an invalid base dependency"
        end

        dependency.to_sym
      end

      def rounding_step
        @tax.fetch(:rounding_step, 1)
      end
    end
  end
end
