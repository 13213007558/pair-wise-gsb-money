# frozen_string_literal: true

require "date"
require "money/cash_flow/day_count"
require "money/cash_flow/xirr"

class Money
  # A dated series of cash flows denominated in a single currency.
  #
  # CashFlow never performs currency conversion and never fetches exchange
  # rates. Every amount must already share one currency; callers that need to
  # mix currencies must convert them explicitly before constructing the cash
  # flow (for example with +Money#exchange_to+).
  #
  # Multiple amounts falling on the same date are summed.
  #
  # @example A cash flow with two internal rates of return
  #   flows = {
  #     Date.new(2024, 1, 1)  => -Money.new(10_000, "USD"),
  #     Date.new(2025, 1, 1)  =>  Money.new(25_000, "USD"),
  #     Date.new(2026, 1, 1)  => -Money.new(15_000, "USD")
  #   }
  #   cash_flow = Money::CashFlow.new(flows)
  #   cash_flow.xirr(-0.5...5.0).rates # => [-0.0, 0.5]
  class CashFlow
    class << self
      # Builds a cash flow from an ordered list of date/amount pairs.
      #
      # @param flows [(Date, Money), Array<Array(Date, Money)>]
      # @return [CashFlow]
      #
      # @see #initialize
      def [](*flows)
        new(flows)
      end
    end

    # @return [Array<Array(Date, Money)>] Sorted date/amount pairs, one per date.
    attr_reader :flows

    # @return [Money::Currency] Currency shared by every amount.
    attr_reader :currency

    # @return [Symbol, #call] Day-count convention used to compute year fractions.
    attr_reader :day_count_convention

    # Raised when the cash flows are empty or not provided as a supported type.
    class InvalidCashFlow < ArgumentError; end

    # Money value that never rounds its fractional part, so NPV residuals
    # smaller than one subunit stay visible.
    #
    # @api private
    class PreciseMoney < Money
      private

      def return_value(value)
        value
      end
    end

    # @param flows [Hash(Date => Money), Array<Array(Date, Money)>] Dated
    #   amounts. Values must be {Money} instances and must all share one
    #   currency; no automatic exchange is performed.
    # @param convention [Symbol, #call] Day-count convention (see
    #   {Money::CashFlow::DayCount}). Defaults to +:act_365_fixed+, the
    #   spreadsheet XIRR convention. May be any callable taking two dates and
    #   returning a year fraction.
    # @param valuation_date [Date, nil] Reference date from which year
    #   fractions are measured. Defaults to the earliest cash flow date.
    def initialize(flows, convention = :act_365_fixed, valuation_date: nil)
      @day_count_convention = convention
      @year_fraction = DayCount.fetch(convention)

      pairs = normalize_pairs(flows)
      raise InvalidCashFlow, "cash flow must contain at least one amount" if pairs.empty?

      @currency = pairs.first.last.currency
      unless pairs.all? { |_date, amount| amount.currency == @currency }
        raise InvalidCashFlow,
              "all cash flows must share one currency; convert amounts explicitly " \
              "(no automatic exchange rate lookup is performed)"
      end

      earliest_date = pairs.map(&:first).min
      @valuation_date = normalize_date(valuation_date || earliest_date)
      if @valuation_date > earliest_date
        raise InvalidCashFlow,
              "valuation date #{@valuation_date} must not be later than the first cash flow date"
      end

      @flows = aggregate(pairs).sort_by(&:first)
    end

    # @return [Date] Date from which year fractions are measured.
    def valuation_date
      @valuation_date
    end

    # @return [Array<Date>] Sorted cash flow dates.
    def dates
      flows.map(&:first)
    end

    # @return [Array<Money>] Cash flow amounts in date order.
    def amounts
      flows.map(&:last)
    end

    # @return [Boolean] +true+ when every amount is zero.
    def all_zero?
      amounts.all?(&:zero?)
    end

    # Year fraction of a date from the valuation date under the selected
    # day-count convention.
    #
    # @param date [Date]
    # @return [Float]
    def year_fraction(date)
      @year_fraction.call(@valuation_date, normalize_date(date)).to_f
    end

    # Net present value of the cash flows at a constant annual rate.
    #
    # Discounting uses +(1 + rate) ** -year_fraction+ with year fractions
    # computed under the day-count convention chosen at construction.
    #
    # @param rate [Numeric] Annual rate (0.05 means 5%).
    # @return [Money] NPV in the cash flow's currency.
    def npv(rate)
      rate = validate_rate(rate)
      base = 1.0 + rate

      value = flows.sum(0.0) do |date, amount|
        t = year_fraction(date)
        amount.fractional.to_f * discount_factor(base, t)
      end

      build_money(value)
    end

    # Finds every internal rate of return in a rate range instead of a single
    # rate that an iterative solver happens to converge to.
    #
    # Roots are isolated by adaptive subdivision that proves exclusion using
    # term-wise monotonic bounds of NPV and its derivative, so even multiple
    # (tangent) roots are reported separately from sign-changing roots.
    #
    # @param range [Range, nil] Search range. Bounds must satisfy +r > -1+.
    #   Use a three-dot range (+-0.5...10.0+) to exclude the upper bound.
    #   Defaults to +-0.9999..10.0+ when neither a range nor bounds are given.
    # @param low [Numeric, nil] Lower bound when +range+ is omitted.
    # @param high [Numeric, nil] Upper bound when +range+ is omitted.
    # @param tol [Numeric] Isolation/root tolerance on the rate.
    # @param budget [Integer] Maximum number of NPV evaluations. When the
    #   budget is exhausted, intervals that still cannot be excluded or
    #   classified are returned as unresolved.
    # @param residual_tol [Numeric, nil] NPV magnitude at which a stationary
    #   point counts as a multiple root. Defaults to a scaled floating-point
    #   tolerance.
    # @return [Money::CashFlow::Xirr::Result]
    def xirr(range = nil, low: nil, high: nil, tol: 1e-9, budget: Xirr::DEFAULT_BUDGET,
             residual_tol: nil)
      lower, upper, exclude_upper = bounds_from(range, low, high)

      return trivial_result(:all_zero, lower, upper, validate_budget(budget)) if all_zero?
      return trivial_result(:no_roots, lower, upper, validate_budget(budget)) unless
        amounts.any? { |amount| amount.fractional > 0 } &&
        amounts.any? { |amount| amount.fractional < 0 }

      Xirr.new(self).solve(
        lower, upper,
        exclude_upper: exclude_upper,
        tol: validate_positive(tol, "tol"),
        budget: validate_budget(budget),
        residual_tol: residual_tol && validate_positive(residual_tol, "residual_tol")
      )
    end

    # Net present value of a dated set of cash flows without constructing a
    # {CashFlow} explicitly. See #npv for discounting semantics.
    #
    # @param rate [Numeric]
    # @param flows [Hash(Date => Money), Array<Array(Date, Money)>]
    # @param convention [Symbol, #call] Day-count convention.
    # @param valuation_date [Date, nil]
    # @return [Money]
    def self.npv(rate, flows, convention = :act_365_fixed, valuation_date: nil)
      new(flows, convention, valuation_date: valuation_date).npv(rate)
    end

    # Finds every internal rate of return of a dated set of cash flows without
    # constructing a {CashFlow} explicitly. See #xirr for search semantics.
    #
    # @param flows [Hash(Date => Money), Array<Array(Date, Money)>]
    # @param args [Object] Positional arguments forwarded to #xirr.
    # @param options [Hash] Keyword arguments forwarded to #xirr and #initialize.
    # @return [Money::CashFlow::Xirr::Result]
    def self.xirr(flows, *args, convention: :act_365_fixed, valuation_date: nil, **options)
      new(flows, convention, valuation_date: valuation_date).xirr(*args, **options)
    end

    # Builds a Money of the same currency from a numeric amount in fractional
    # units, without consulting any bank.
    #
    # @param fractional [Float]
    # @return [Money]
    # @api private
    def build_money(fractional)
      return Money.empty(currency) if fractional.zero?
      return Money.new(fractional == Float::INFINITY ? 10**100 : -10**100, currency) unless
        fractional.finite?

      PreciseMoney.new(fractional, currency)
    end

    private

    def trivial_result(status, lower, upper, budget)
      Xirr::Result.new(
        status: status,
        roots: [],
        multiple_roots: [],
        unresolved_intervals: [],
        evaluations: 0,
        budget: budget,
        low: lower,
        high: upper,
        currency: currency,
        cash_flow: self
      )
    end

    def normalize_pairs(flows)
      case flows
      when Hash
        flows.map { |date, amount| [normalize_date(date), validate_amount(amount)] }
      when Array
        if flows.length == 2 && !flows.first.is_a?(Array) && flows.last.is_a?(Money)
          [[normalize_date(flows.first), validate_amount(flows.last)]]
        else
          flows.map do |pair|
            unless pair.is_a?(Array) && pair.length == 2
              raise InvalidCashFlow, "each cash flow must be a [date, Money] pair"
            end

            [normalize_date(pair.first), validate_amount(pair.last)]
          end
        end
      else
        raise InvalidCashFlow, "cash flows must be a Hash or an array of [date, Money] pairs"
      end
    end

    def validate_amount(amount)
      unless amount.is_a?(Money)
        raise InvalidCashFlow, "cash flow amounts must be Money instances, got #{amount.class}"
      end

      amount
    end

    def normalize_date(date)
      if date.is_a?(Date) && !date.is_a?(DateTime)
        date
      elsif date.respond_to?(:to_date)
        date = date.to_date
      else
        raise InvalidCashFlow, "cash flow dates must be Dates, got #{date.class}"
      end
      date
    end

    def aggregate(pairs)
      pairs.group_by(&:first).transform_values do |grouped|
        grouped.map(&:last).reduce { |sum, amount| sum + amount }
      end.to_a
    end

    def discount_factor(base, t)
      return 1.0 if t.zero?

      exponent = -t * Math.log(base)
      return 0.0 if exponent < -745.0

      Math.exp(exponent)
    end

    def validate_rate(rate)
      raise ArgumentError, "rate must be numeric" unless rate.is_a?(Numeric)
      raise ArgumentError, "rate must be greater than -1" unless rate > -1

      rate.to_f
    end

    def validate_positive(value, name)
      raise ArgumentError, "#{name} must be numeric" unless value.is_a?(Numeric)
      raise ArgumentError, "#{name} must be greater than zero" unless value > 0

      value.to_f
    end

    def validate_budget(budget)
      unless budget.is_a?(Integer) && budget >= 4
        raise ArgumentError, "budget must be an Integer greater than or equal to 4"
      end

      budget
    end

    def bounds_from(range, low, high)
      if range
        unless range.is_a?(Range)
          raise ArgumentError, "search range must be a Range"
        end

        low = range.begin
        high = range.end
        exclude_upper = range.exclude_end?
      else
        if low.nil? && high.nil?
          low = Xirr::DEFAULT_LOW
          high = Xirr::DEFAULT_HIGH
        else
          raise ArgumentError, "provide both low: and high:" if low.nil? || high.nil?
        end
        exclude_upper = false
      end

      bounds = [validate_bound(low, "low"), validate_bound(high, "high")]
      raise ArgumentError, "search bounds must satisfy low < high" unless bounds.first < bounds.last

      bounds + [exclude_upper]
    end

    def validate_bound(value, name)
      unless value.is_a?(Numeric) && value > -1
        raise ArgumentError, "#{name} bound must be greater than -1"
      end

      value.to_f
    end
  end
end
