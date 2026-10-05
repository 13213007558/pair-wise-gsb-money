# frozen_string_literal: true

class Money
  # Offline, deterministic calculator for layered taxes.
  #
  # Tax rates and dependencies are supplied by the caller. A tax base may contain
  # :net and the rounded amounts of previously declared taxes. Every tax may use
  # its own BigDecimal rounding mode, and a separate mode may be used for the
  # final cash rounding step.
  #
  # Inputs and outputs use whole minor units. Zero amounts are calculated and
  # retained explicitly, and negative net amounts represent reversals.
  class TaxCalculator
    class CircularDependencyError < ArgumentError; end
    class InvalidTaxError < ArgumentError; end

    CalculationLine = Struct.new(
      :name,
      :rate,
      :base,
      :base_components,
      :amount_before_rounding,
      :amount,
      :rounding_mode,
      keyword_init: true,
    )

    Result = Struct.new(
      :net,
      :tax_lines,
      :subtotal,
      :tax,
      :gross_before_cash_rounding,
      :cash_rounding_adjustment,
      :gross,
      keyword_init: true,
    )

    ROUNDING_MODES = {
      up: BigDecimal::ROUND_UP,
      down: BigDecimal::ROUND_DOWN,
      ceiling: BigDecimal::ROUND_CEILING,
      floor: BigDecimal::ROUND_FLOOR,
      half_up: BigDecimal::ROUND_HALF_UP,
      half_down: BigDecimal::ROUND_HALF_DOWN,
      half_even: BigDecimal::ROUND_HALF_EVEN,
    }.freeze

    attr_reader :currency, :taxes, :rounding_mode,
                :cash_rounding_step, :cash_rounding_mode

    def initialize(currency:, taxes:, rounding_mode: BigDecimal::ROUND_HALF_UP,
                   cash_rounding_step: nil, cash_rounding_mode: nil)
      @currency = Currency.wrap(currency)
      raise ArgumentError, "must provide a currency" if @currency.nil?

      @rounding_mode = resolve_rounding_mode(rounding_mode)
      @cash_rounding_mode = resolve_rounding_mode(cash_rounding_mode || @rounding_mode)
      @taxes = normalize_taxes(taxes)
      @tax_order = topologically_sort(@taxes)
      @cash_rounding_step = normalize_cash_rounding_step(cash_rounding_step)
    end

    # Calculates all tax lines, the pre-cash total, and the cash-rounded gross.
    #
    # @param net [Money, Integer] net price in whole minor units
    # @return [Result]
    def calculate(net)
      net_money = to_money(net, "net")
      calculate_for_integer(net_money.fractional)
    end

    # @return [Money] gross price in whole minor units
    def gross_from_net(net)
      calculate(net).gross
    end

    # Finds every whole-minor-unit net price whose rounded gross equals gross.
    #
    # @return [Array<Result>] all matches, sorted by ascending net price; an
    #   empty array means no exact solution exists
    def nets_for_gross(gross)
      gross_money = to_money(gross, "gross")
      target = gross_money.fractional

      return [] unless target % cash_rounding_step == 0

      lower = find_boundary(target, :greater_or_equal)
      upper = find_boundary(target, :greater_than) - 1
      return [] if upper < lower

      (lower..upper).filter_map do |net_fractional|
        result = calculate_for_integer(net_fractional)
        result if result.gross.fractional == target
      end
    end
    alias reverse nets_for_gross

    private

    def normalize_taxes(taxes)
      unless taxes.is_a?(Array) && !taxes.empty?
        raise InvalidTaxError, "taxes must be a non-empty array"
      end

      taxes.each_with_index.map do |tax, index|
        unless tax.is_a?(Hash)
          raise InvalidTaxError, "tax at index #{index} must be a hash"
        end

        name = tax.fetch(:name) { "tax_#{index}".to_sym }
        unless name.is_a?(Symbol) || name.is_a?(String)
          raise InvalidTaxError, "tax name at index #{index} must be a symbol or string"
        end

        name = name.to_sym
        if name == :net
          raise InvalidTaxError, "tax name :net is reserved"
        end

        rate = tax[:rate]
        if rate.is_a?(Float)
          raise InvalidTaxError,
                "rate for #{name} must be BigDecimal, Rational, or Integer (not Float)"
        end

        unless rate.is_a?(Numeric) && rate.real? && rate >= 0
          raise InvalidTaxError, "rate for #{name} must be a non-negative number"
        end

        base_dependencies = tax[:base_dependencies] || tax[:base] || [:net]
        base_dependencies = normalize_base_dependencies(base_dependencies, name)
        tax_rounding_mode = resolve_rounding_mode(tax.fetch(:rounding_mode, rounding_mode))

        {
          name: name,
          rate: rate.to_r,
          base_dependencies: base_dependencies,
          rounding_mode: tax_rounding_mode,
        }
      end.tap do |normalized|
        names = normalized.map { |tax| tax[:name] }
        duplicates = names.filter_map { |name| name if names.count(name) > 1 }.uniq
        unless duplicates.empty?
          raise InvalidTaxError, "duplicate tax names: #{duplicates.join(", ")}"
        end
      end
    end

    def normalize_base_dependencies(base_dependencies, tax_name)
      base_dependencies = [base_dependencies] unless base_dependencies.is_a?(Array)
      if base_dependencies.empty?
        raise InvalidTaxError, "tax base for #{tax_name} must not be empty"
      end

      base_dependencies.map do |dependency|
        dependency = dependency.to_sym if dependency.is_a?(String)
        unless dependency.is_a?(Symbol)
          raise InvalidTaxError, "tax base dependency for #{tax_name} must be a symbol"
        end
        if dependency == tax_name
          raise CircularDependencyError, "tax #{tax_name} depends on itself"
        end

        dependency
      end.then do |dependencies|
        if dependencies.uniq.length != dependencies.length
          raise InvalidTaxError, "tax base for #{tax_name} contains duplicate dependencies"
        end

        dependencies
      end
    end

    def topologically_sort(taxes)
      by_name = taxes.to_h { |tax| [tax[:name], tax] }
      ordered = []
      visited = {}

      taxes.each do |tax|
        visit_tax(tax[:name], by_name, visited, [], ordered)
      end

      ordered
    end

    def visit_tax(name, taxes_by_name, visited, stack, ordered)
      return if visited[name] == :visited

      if stack.include?(name)
        cycle = stack[stack.index(name)..] + [name]
        raise CircularDependencyError, "circular tax dependencies: #{cycle.join(" -> ")}"
      end

      visited[name] = :in_progress
      stack << name

      taxes_by_name.fetch(name)[:base_dependencies].each do |dependency|
        next if dependency == :net

        unless taxes_by_name.key?(dependency)
          raise InvalidTaxError, "tax #{name} depends on unknown tax #{dependency}"
        end

        visit_tax(dependency, taxes_by_name, visited, stack, ordered)
      end

      stack.pop
      visited[name] = :visited
      ordered << name
    end

    def calculate_for_integer(net_fractional)
      components = { net: net_fractional.to_r }
      lines = []

      @tax_order.each do |name|
        tax = tax_by_name.fetch(name)
        base = tax[:base_dependencies].sum { |dependency| components.fetch(dependency) }
        raw_amount = base * tax[:rate]
        amount = round_integer(raw_amount, tax[:rounding_mode])

        components[name] = amount
        lines << build_line(tax, components, base, raw_amount, amount)
      end

      tax_total = lines.sum { |line| line.amount.fractional }
      subtotal = net_fractional + tax_total
      gross_before_cash = subtotal
      gross = round_cash(subtotal)
      cash_adjustment = gross - subtotal

      build_result(net_fractional, lines, tax_total, subtotal,
                   gross_before_cash, cash_adjustment, gross)
    end

    def build_line(tax, components, base, raw_amount, amount)
      base_components = tax[:base_dependencies].to_h do |dependency|
        [dependency, money_from_fractional(components.fetch(dependency))]
      end

      CalculationLine.new(
        name: tax[:name],
        rate: tax[:rate],
        base: money_from_fractional(base),
        base_components: base_components,
        amount_before_rounding: raw_amount / currency.subunit_to_unit,
        amount: money_from_fractional(amount),
        rounding_mode: tax[:rounding_mode],
      )
    end

    def build_result(net_fractional, lines, tax_total, subtotal,
                     gross_before_cash, cash_adjustment, gross)
      Result.new(
        net: money_from_fractional(net_fractional),
        tax_lines: lines,
        subtotal: money_from_fractional(subtotal),
        tax: money_from_fractional(tax_total),
        gross_before_cash_rounding: money_from_fractional(gross_before_cash),
        cash_rounding_adjustment: money_from_fractional(cash_adjustment),
        gross: money_from_fractional(gross),
      )
    end

    def find_boundary(target, kind)
      if boundary_hit?(0, target, kind)
        low = -1
        high = 0

        until !boundary_hit?(low, target, kind)
          high = low
          low *= 2
        end
      else
        low = 0
        high = 1

        until boundary_hit?(high, target, kind)
          low = high
          high *= 2
        end
      end

      while low < high
        middle = (low + high) / 2
        if boundary_hit?(middle, target, kind)
          high = middle
        else
          low = middle + 1
        end
      end

      high
    end

    def boundary_hit?(net_fractional, target, kind)
      gross = calculate_for_integer(net_fractional).gross.fractional
      kind == :greater_or_equal ? gross >= target : gross > target
    end

    def round_cash(value)
      return value if cash_rounding_step == 1

      quotient, remainder = value.divmod(cash_rounding_step)
      return value if remainder == 0

      rounded_quotient = round_integer(quotient + remainder.to_r / cash_rounding_step,
                                       cash_rounding_mode)
      rounded_quotient * cash_rounding_step
    end

    def round_integer(value, mode)
      quotient, remainder = value.divmod(1)
      return quotient if remainder == 0

      case mode
      when BigDecimal::ROUND_UP
        quotient + (value.negative? ? -1 : 1)
      when BigDecimal::ROUND_DOWN
        quotient + (value.negative? ? 1 : 0)
      when BigDecimal::ROUND_CEILING
        quotient + 1
      when BigDecimal::ROUND_FLOOR
        quotient
      when BigDecimal::ROUND_HALF_UP
        quotient + half_up_increment(quotient, remainder)
      when BigDecimal::ROUND_HALF_DOWN
        quotient + half_down_increment(quotient, remainder)
      else
        quotient + half_even_increment(quotient, remainder)
      end
    end

    def half_up_increment(quotient, remainder)
      return 1 if quotient >= 0 && remainder >= Rational(1, 2)
      return 0 if quotient >= 0
      return 1 if remainder < Rational(1, 2)

      0
    end

    def half_even_increment(quotient, remainder)
      return half_even_negative_increment(quotient, remainder) if quotient.negative?

      return 1 if remainder > Rational(1, 2)
      return 1 if remainder == Rational(1, 2) && quotient.odd?

      0
    end

    def half_even_negative_increment(quotient, remainder)
      return 1 if remainder < Rational(1, 2)
      return 1 if remainder == Rational(1, 2) && quotient.odd?

      0
    end

    def half_down_increment(quotient, remainder)
      return 0 if quotient.negative? && remainder > Rational(1, 2)
      return 1 if remainder > Rational(1, 2)
      return 1 if quotient.negative? && remainder == Rational(1, 2)

      0
    end

    def resolve_rounding_mode(mode)
      return mode if ROUNDING_MODES.values.include?(mode)

      ROUNDING_MODES.fetch(mode) do
        raise ArgumentError, "unsupported rounding mode: #{mode.inspect}"
      end
    end

    def normalize_cash_rounding_step(step)
      return 1 if step.nil?

      if step.is_a?(Money)
        ensure_currency!(step, "cash rounding step")
        step = step.fractional
      end

      unless step.is_a?(Integer) && step.positive?
        raise ArgumentError, "cash rounding step must be a positive integer or Money"
      end

      step
    end

    def to_money(value, label)
      if value.is_a?(Money)
        money = value
      elsif value.is_a?(Integer)
        money = Money.new(value, currency)
      else
        raise ArgumentError, "#{label} must be Money or an Integer number of minor units"
      end

      ensure_currency!(money, label)
      unless money.fractional.is_a?(Integer)
        raise ArgumentError, "#{label} must be a whole #{currency} minor unit"
      end

      money
    end

    def ensure_currency!(money, label)
      return if money.currency == currency

      raise ArgumentError, "#{label} currency #{money.currency} does not match #{currency}"
    end

    def money_from_fractional(value)
      Money.new(value.to_i, currency)
    end

    def tax_by_name
      @tax_by_name ||= @taxes.to_h { |tax| [tax[:name], tax] }
    end
  end
end
