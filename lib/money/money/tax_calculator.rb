# frozen_string_literal: true

require "bigdecimal"

require_relative "tax_calculator/candidate_bounds"
require_relative "tax_calculator/rounding"
require_relative "tax_calculator/result"
require_relative "tax_calculator/rule_factory"
require_relative "tax_calculator/tax_amount"
require_relative "tax_calculator/tax_rule"

class Money
  # Offline, deterministic tax calculator for a single currency.
  class TaxCalculator
    # Raised when tax dependencies contain a cycle.
    class CircularTaxDependency < ArgumentError; end

    # Creates a calculator.
    #
    # @param taxes [Array<Hash>] Tax rules in display order. Dependencies may
    #   refer to taxes declared later; they are topologically sorted before
    #   calculation. Each rule accepts:
    #   - +:name+ (Symbol or String, required)
    #   - +:rate+ (non-negative Numeric, required)
    #   - +:base+ (Symbol or Array, defaults to +[:net]+; repeated
    #     dependencies are included repeatedly)
    #   - +:rounding_step+ (positive Integer fractional units, defaults to 1)
    #   - +:rounding_mode+ (BigDecimal rounding mode, required)
    # @param cash_rounding_step [Integer] Positive final cash rounding step in
    #   fractional units. Use 1 for no cash rounding.
    # @param cash_rounding_mode [Integer] BigDecimal rounding mode used for the
    #   final cash total.
    #
    # @raise [ArgumentError] when configuration is invalid.
    # @raise [Money::TaxCalculator::CircularTaxDependency] when dependencies
    #   contain a cycle.
    def initialize(taxes, cash_rounding_step:, cash_rounding_mode:)
      @rules = RuleFactory.build(taxes)
      validate_references

      @rules_by_name = @rules.to_h { |rule| [rule.name, rule] }
      @order = topological_order
      @cash_rounding_step = Rounding.validate_step(cash_rounding_step, :cash_rounding_step)
      @cash_rounding_mode = Rounding.validate_mode(cash_rounding_mode)
    end

    # Calculates taxes and totals from a net amount.
    #
    # Zero and negative Money amounts are supported. Negative amounts use the
    # configured BigDecimal rounding modes without changing their sign.
    #
    # @param net [Money] Whole amount in the currency's minimum denomination.
    # @return [Money::TaxCalculator::Result]
    def calculate(net)
      net = coerce_money(net, :net)
      calculate_fractional(net[:fractional], net[:currency])
    end

    # Returns every net amount whose final cash total equals +total+.
    #
    # The result can contain zero, one, or several minimum-denomination
    # amounts. No candidate is selected implicitly.
    #
    # @param total [Money] Cash-rounded tax-inclusive total.
    # @return [Array<Money::TaxCalculator::Result>] Results sorted by net.
    def reverse(total)
      total = coerce_money(total, :total)
      target = total[:fractional]
      currency = total[:currency]

      return [] unless target % @cash_rounding_step == 0

      lower, upper = CandidateBounds.for(@rules, @order, target, @cash_rounding_step)
      lower.upto(upper).filter_map do |net_fractional|
        result = calculate_fractional(net_fractional, currency)
        result if result.cash_total.fractional == target
      end
    end

    private

    def validate_references
      names = @rules.map(&:name)
      if names.uniq.length != names.length
        raise ArgumentError, "tax names must be unique"
      end

      known = names.to_set << :net
      @rules.each do |rule|
        unknown = rule.dependencies.reject { |dependency| known.include?(dependency) }
        next if unknown.empty?

        raise ArgumentError, "tax #{rule.name.inspect} depends on unknown #{unknown.inspect}"
      end
    end

    def topological_order
      completed = Set.new
      stack = []
      ordered = []

      visit = lambda do |name|
        return if completed.include?(name)

        if stack.include?(name)
          start = stack.index(name)
          cycle = stack[start..] + [name]
          raise CircularTaxDependency, "circular tax dependency: #{cycle.join(" -> ")}"
        end

        stack << name
        @rules_by_name.fetch(name).dependencies.each do |dependency|
          visit.call(dependency) unless dependency == :net
        end
        stack.pop
        completed << name
        ordered << name
      end

      @rules.each { |rule| visit.call(rule.name) }
      ordered
    end

    def coerce_money(value, label)
      unless value.is_a?(Money)
        raise ArgumentError, "#{label} must be a Money object"
      end

      fractional = value.fractional
      unless fractional.to_r.denominator == 1
        raise ArgumentError, "#{label} must be a whole minimum-denomination amount"
      end

      { fractional: fractional.to_i, currency: value.currency }
    end

    def calculate_fractional(net_fractional, currency)
      values = { net: net_fractional }
      calculated = {}

      @order.each do |name|
        rule = @rules_by_name.fetch(name)
        base_fractional = rule.dependencies.sum { |dependency| values.fetch(dependency) }
        unrounded_fractional = base_fractional.to_r * rule.rate
        tax_fractional = Rounding.round(
          unrounded_fractional,
          rule.rounding_step,
          rule.rounding_mode,
        )

        values[name] = tax_fractional
        calculated[name] = TaxAmount.new(
          name: name,
          rate: rule.rate,
          base: Money.new(base_fractional, currency),
          unrounded_amount: unrounded_fractional / currency.subunit_to_unit,
          amount: Money.new(tax_fractional, currency),
        )
      end

      taxes = @rules.map { |rule| calculated.fetch(rule.name) }
      tax_total_fractional = taxes.sum(0) { |tax| tax.amount.fractional }
      gross_fractional = net_fractional + tax_total_fractional
      cash_fractional = Rounding.round(
        gross_fractional.to_r,
        @cash_rounding_step,
        @cash_rounding_mode,
      )

      Result.new(
        net: Money.new(net_fractional, currency),
        taxes: taxes,
        tax_total: Money.new(tax_total_fractional, currency),
        gross: Money.new(gross_fractional, currency),
        cash_total: Money.new(cash_fractional, currency),
      )
    end
  end
end
