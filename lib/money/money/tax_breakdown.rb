# frozen_string_literal: true

require "bigdecimal"

class Money
  # Reconstructs a tax-inclusive total from integer net and tax amounts.
  #
  # This calculator contains no regional tax policy. Callers describe each tax
  # name, exact non-negative rate, tax-base dependencies, and rounding mode.
  # All monetary values are expressed in the currency's smallest unit.
  class TaxBreakdown
    NET = :net
    private_constant :NET

    ROUNDING_MODES = {
      BigDecimal::ROUND_DOWN => :down,
      BigDecimal::ROUND_UP => :up,
      BigDecimal::ROUND_FLOOR => :down,
      BigDecimal::ROUND_CEILING => :up,
      BigDecimal::ROUND_HALF_UP => :half_up,
      BigDecimal::ROUND_HALF_DOWN => :half_down,
      BigDecimal::ROUND_HALF_EVEN => :half_even,
      :down => :down,
      :floor => :down,
      :truncate => :down,
      :up => :up,
      :ceiling => :up,
      :ceil => :up,
      :half_up => :half_up,
      :half_down => :half_down,
      :half_even => :half_even,
      :banker => :half_even,
    }.freeze

    # The exact amounts reconstructed for a net amount.
    class Result
      attr_reader :net_amount, :tax_amounts, :total

      def initialize(net_amount, tax_amounts)
        @net_amount = net_amount
        @tax_amounts = tax_amounts.dup.freeze
        @total = net_amount + tax_amounts.values.sum
        freeze
      end

      def to_h
        {
          net_amount: net_amount,
          tax_amounts: tax_amounts.dup,
          total: total,
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          net_amount == other.net_amount &&
          tax_amounts == other.tax_amounts
      end

      alias eql? ==

      def hash
        [self.class, net_amount, tax_amounts].hash
      end
    end

    # Finds the non-negative integer net amount whose forward calculation
    # exactly equals +total+. The forward total is strictly increasing because
    # the net amount increases by one while every non-negative tax amount is
    # non-decreasing, so a matching net amount is unique.
    #
    # @param total [Integer] Tax-inclusive total in smallest currency units.
    # @param taxes [Array<Hash>] Tax definitions in declaration order.
    # @option taxes [Symbol, String] :name Unique tax name.
    # @option taxes [Integer, Rational, BigDecimal] :rate Exact non-negative rate.
    # @option taxes [Symbol, String, Array] :base Tax-base components. Defaults to :net.
    # @option taxes [Symbol, Integer] :rounding Per-tax rounding mode.
    # @param rounding [Symbol, Integer] Default rounding mode. Defaults to :half_up.
    # @return [Result, nil] The unique result, or nil when no integer result exists.
    def self.find(total, taxes, rounding: :half_up)
      require_non_negative_integer(total, "total")
      new(taxes, default_rounding: rounding).find(total)
    end

    # Calculates the tax-inclusive total for an explicit integer net amount.
    #
    # @param net_amount [Integer] Net amount in smallest currency units.
    # @param taxes [Array<Hash>] Tax definitions in declaration order.
    # @param rounding [Symbol, Integer] Default rounding mode. Defaults to :half_up.
    # @return [Result] The calculated net, tax, and total amounts.
    def self.calculate(net_amount, taxes, rounding: :half_up)
      require_non_negative_integer(net_amount, "net amount")
      new(taxes, default_rounding: rounding).calculate(net_amount)
    end

    def self.require_non_negative_integer(value, label)
      unless value.is_a?(Integer) && !value.negative?
        raise ArgumentError, "#{label} must be a non-negative Integer"
      end
    end
    private_class_method :require_non_negative_integer

    def initialize(taxes, default_rounding: :half_up)
      tax_definitions = normalize_taxes(taxes)
      names = tax_definitions.map { |tax| tax[:name] }
      @taxes = tax_definitions.map do |tax|
        tax.merge(base: validate_base_components(tax[:base], names))
      end
      @default_rounding = validate_rounding(default_rounding)
      @order = topological_order
    end

    def find(target_total)
      low = 0
      high = target_total

      while low <= high
        net_amount = (low + high) / 2
        result = build_result(net_amount)

        if result.total == target_total
          return result
        elsif result.total < target_total
          low = net_amount + 1
        else
          high = net_amount - 1
        end
      end

      nil
    end

    def calculate(net_amount)
      build_result(net_amount)
    end

    private

    def normalize_taxes(taxes)
      unless taxes.is_a?(Array)
        raise ArgumentError, "taxes must be an array"
      end

      names = []
      normalized = taxes.map do |tax|
        unless tax.is_a?(Hash)
          raise ArgumentError, "each tax must be a hash"
        end

        name = normalize_name(tax.fetch(:name), "tax name")
        if name == NET || names.include?(name)
          raise ArgumentError, "duplicate tax name: #{name.inspect}"
        end

        tax_definition = {
          name: name,
          rate: validate_rate(tax.fetch(:rate)),
          base: normalize_base_components(tax.fetch(:base, NET)),
          rounding: tax.key?(:rounding) ? validate_rounding(tax.fetch(:rounding)) : nil,
        }
        names << name
        tax_definition
      end
      normalized
    end

    def normalize_name(value, label)
      unless value.is_a?(Symbol) || value.is_a?(String)
        raise ArgumentError, "#{label} must be a symbol or string"
      end

      value.to_sym.tap do |name|
        if name.empty?
          raise ArgumentError, "#{label} cannot be empty"
        end
      end
    end

    def validate_rate(rate)
      if rate.is_a?(Float)
        raise ArgumentError, "Float rates are not exact; use Rational or BigDecimal"
      end

      unless rate.is_a?(Integer) || rate.is_a?(Rational) || rate.is_a?(BigDecimal)
        raise ArgumentError, "rate must be an Integer, Rational, or BigDecimal"
      end

      if rate.negative? || !rate.finite?
        raise ArgumentError, "rate must be finite and non-negative"
      end

      rate.to_r
    end

    def normalize_base_components(base)
      components = Array(base).map do |component|
        component == NET ? NET : normalize_name(component, "tax-base component")
      end

      if components.empty?
        raise ArgumentError, "tax base must include at least one component"
      end

      unless components.uniq.length == components.length
        raise ArgumentError, "tax-base dependencies cannot be duplicated"
      end

      components
    end

    def validate_base_components(components, names)
      components.each do |component|
        unless component == NET || names.include?(component)
          raise ArgumentError, "unknown tax-base dependency: #{component.inspect}"
        end
      end
      components
    end

    def validate_rounding(rounding)
      ROUNDING_MODES.fetch(rounding) do
        raise ArgumentError, "unsupported rounding mode: #{rounding.inspect}"
      end
    end

    def topological_order
      tax_names = @taxes.map { |tax| tax[:name] }
      dependencies = tax_names.to_h do |name|
        [name, tax_config(name)[:base] - [NET]]
      end

      indegrees = tax_names.to_h { |name| [name, dependencies[name].length] }
      dependents = tax_names.to_h { |name| [name, []] }

      dependencies.each do |name, deps|
        deps.each do |dep|
          dependents.fetch(dep) << name
        end
      end

      ordered = []
      ready = tax_names.select { |name| indegrees[name].zero? }

      until ready.empty?
        name = ready.shift
        ordered << name

        dependents.fetch(name).sort_by { |dependent| tax_names.index(dependent) }.each do |dependent|
          indegrees[dependent] -= 1
          ready << dependent if indegrees[dependent].zero?
        end
      end

      if ordered.length != tax_names.length
        raise ArgumentError, "tax dependencies must be acyclic"
      end

      ordered
    end

    def build_result(net_amount)
      tax_amounts = {}

      @order.each do |name|
        config = tax_config(name)
        tax_base = config[:base].sum do |component|
          component == NET ? net_amount : tax_amounts.fetch(component)
        end
        mode = config[:rounding] || @default_rounding
        tax_amounts[name] = rounded_tax(tax_base * config[:rate], mode)
      end

      ordered_tax_amounts = @taxes.each_with_object({}) do |tax, amounts|
        amounts[tax[:name]] = tax_amounts.fetch(tax[:name])
      end

      Result.new(net_amount, ordered_tax_amounts)
    end

    def rounded_tax(value, mode)
      case mode
      when :down
        value.floor
      when :up
        value.ceil
      when :half_up
        value.round(half: :up)
      when :half_down
        value.round(half: :down)
      when :half_even
        value.round(half: :even)
      end
    end

    def tax_config(name)
      @taxes.find { |tax| tax[:name] == name }
    end
  end
end
