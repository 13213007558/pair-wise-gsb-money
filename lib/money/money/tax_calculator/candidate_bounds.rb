# frozen_string_literal: true

class Money
  class TaxCalculator
    # Finds the finite integer range that can contain a reverse-calculation match.
    class CandidateBounds
      def self.for(rules, order, target, cash_rounding_step)
        new(rules, order, target, cash_rounding_step).to_a
      end

      def initialize(rules, order, target, cash_rounding_step)
        @rules = rules
        @rules_by_name = rules.to_h { |rule| [rule.name, rule] }
        @order = order
        @target = target.to_r
        @cash_rounding_step = cash_rounding_step.to_r
      end

      def to_a
        [lower_net, upper_net]
      end

      private

      def lower_net
        ((minimum_gross - gross_high[1]) / gross_high[0]).ceil
      end

      def upper_net
        ((maximum_gross - gross_low[1]) / gross_low[0]).floor
      end

      def minimum_gross
        @target - @cash_rounding_step
      end

      def maximum_gross
        @target + @cash_rounding_step
      end

      def gross_low
        [tax_low[0] + 1, tax_low[1]]
      end

      def gross_high
        [tax_high[0] + 1, tax_high[1]]
      end

      def tax_low
        dependency_bounds(@rules.map(&:name), bounds)[0]
      end

      def tax_high
        dependency_bounds(@rules.map(&:name), bounds)[1]
      end

      def bounds
        @bounds ||= begin
          net_bound = [1r, 0r]
          accumulated = { net: [net_bound, net_bound] }

          @order.each do |name|
            rule = @rules_by_name.fetch(name)
            base_low, base_high = dependency_bounds(rule.dependencies, accumulated)
            unrounded_low = [rule.rate * base_low[0], rule.rate * base_low[1]]
            unrounded_high = [rule.rate * base_high[0], rule.rate * base_high[1]]

            accumulated[name] = [
              [unrounded_low[0], unrounded_low[1] - rule.rounding_step.to_r],
              [unrounded_high[0], unrounded_high[1] + rule.rounding_step.to_r],
            ]
          end

          accumulated
        end
      end

      def dependency_bounds(dependencies, source_bounds)
        low = [0r, 0r]
        high = [0r, 0r]

        dependencies.each do |dependency|
          dependency_low, dependency_high = source_bounds.fetch(dependency)
          low = [low[0] + dependency_low[0], low[1] + dependency_low[1]]
          high = [high[0] + dependency_high[0], high[1] + dependency_high[1]]
        end

        [low, high]
      end
    end
  end
end
