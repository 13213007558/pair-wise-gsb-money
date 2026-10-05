# frozen_string_literal: true

require "date"

class Money
  # Cash-flow valuation for Money.
  #
  # Solves the XIRR equation
  #
  #   NPV(r) = sum(amount_i / (1 + r) ** t_i) = 0
  #
  # where t_i is the year fraction between the first cash-flow date and the
  # date of cash-flow i, computed with a caller-selected day-count basis.
  #
  # Unlike a Newton-style calculator that converges to whichever root is
  # closest to its initial guess, the solver scans the whole caller-specified
  # rate interval and isolates *every* sign change, so cash-flow series with
  # multiple internal rates of return report all of them. Each reported root
  # comes with the isolating interval and the NPV residual at the reported
  # rate.
  #
  # All amounts must be expressed in a single currency up front. The solver
  # never touches Money.default_bank and never fetches exchange rates to make
  # mixed currencies comparable; mixed-currency input raises
  # Money::CashFlow::CurrencyMismatch.
  #
  # Example:
  #
  #   result = Money.xirr(
  #     [[Money.from_amount(-1000, "USD"), Date.new(2024, 1, 1)],
  #      [Money.from_amount( 2300, "USD"), Date.new(2025, 1, 1)],
  #      [Money.from_amount(-1320, "USD"), Date.new(2026, 1, 1)]],
  #     day_count: :thirty_360,
  #     rate_range: -0.5..1.0
  #   )
  #   result.status # => :solved
  #   result.rates  # => [0.1, 0.2] (approximately)
  module CashFlow
    # Base error for cash-flow valuation failures.
    class Error < StandardError; end

    # Raised when cash flows are denominated in more than one currency.
    # Amounts must be converted to a common currency by the caller before
    # valuation; this library will not fetch exchange rates implicitly.
    class CurrencyMismatch < Error; end

    # Raised when the search interval is not contained in r > -1.
    class InvalidRateRange < Error; end

    # Raised when a cash-flow entry is malformed.
    class InvalidEntry < Error; end

    # A single dated cash flow.
    Entry = Struct.new(:amount, :date) do
      def initialize(amount, date)
        super
        unless amount.is_a?(Money)
          raise InvalidEntry, "cash-flow amount must be a Money, got #{amount.class}"
        end
        unless date.is_a?(Date)
          raise InvalidEntry, "cash-flow date must be a Date, got #{date.class}"
        end
      end
    end

    # An isolated root of the NPV equation.
    #
    # +interval+ is a Range of rates guaranteed to bracket the root, no wider
    # than the requested tolerance. +rate+ is the midpoint estimate.
    # +residual+ is the NPV evaluated at +rate+, in the common currency's
    # main unit (e.g. dollars), as a Float.
    Root = Struct.new(:interval, :rate, :residual) do
      def to_h
        { interval: interval, rate: rate, residual: residual }
      end
    end

    # The outcome of an XIRR search.
    #
    # +status+ is one of:
    # - +:solved+   - one or more roots were isolated (see +roots+)
    # - +:no_root+  - the searched interval contains no detectable root
    # - +:all_zero+ - every cash flow is zero, so NPV is identically zero and
    #                 any rate trivially "solves" the equation
    #
    # +unresolved_intervals+ lists the rate ranges that could not be excluded
    # because the evaluation budget ran out; it is empty when the search
    # completed. +budget_exhausted?+ is true in that case.
    class Result
      attr_reader :status, :roots, :unresolved_intervals, :evaluations, :currency

      def initialize(status:, roots:, unresolved_intervals:, evaluations:, currency:)
        @status = status
        @roots = roots
        @unresolved_intervals = unresolved_intervals
        @evaluations = evaluations
        @currency = currency
      end

      def solved?
        status == :solved
      end

      def no_root?
        status == :no_root
      end

      def all_zero?
        status == :all_zero
      end

      def budget_exhausted?
        !unresolved_intervals.empty?
      end

      # The rate estimates of all isolated roots, ascending.
      def rates
        roots.map(&:rate)
      end
    end

    # Day-count bases computing the year fraction between two Dates.
    # A custom basis may be supplied to Money.xirr as any callable
    # accepting (from_date, to_date) and returning a Numeric.
    module DayCount
      module_function

      def fetch(basis)
        return basis if basis.respond_to?(:call)

        case basis
        when :act_365 then method(:act_365)
        when :act_360 then method(:act_360)
        when :act_act then method(:act_act)
        when :thirty_360 then method(:thirty_360)
        else
          raise ArgumentError, "unknown day-count basis: #{basis.inspect}"
        end
      end

      def act_365(from, to)
        (to - from).to_i / 365.0
      end

      def act_360(from, to)
        (to - from).to_i / 360.0
      end

      # Actual/actual (ISDA-style): splits the period at January 1st and
      # divides each part by the number of days in its calendar year.
      def act_act(from, to)
        return 0.0 if from == to
        return -act_act(to, from) if to < from

        total = 0.0
        cursor = from
        while cursor < to
          boundary = Date.new(cursor.year + 1, 1, 1)
          stop = [boundary, to].min
          days_in_year = (Date.new(cursor.year, 12, 31) - Date.new(cursor.year, 1, 1)).to_i + 1
          total += (stop - cursor).to_i / days_in_year.to_f
          cursor = stop
        end
        total
      end

      # US 30/360.
      def thirty_360(from, to)
        d1 = [from.day, 30].min
        d2 = to.day
        d2 = 30 if d1 == 30 && d2 == 31
        ((to.year - from.year) * 360 + (to.month - from.month) * 30 + (d2 - d1)) / 360.0
      end
    end

    DEFAULT_TOLERANCE = 1e-10
    DEFAULT_MAX_EVALUATIONS = 10_000
    DEFAULT_GRID_SIZE = 512

    module_function

    # Finds every XIRR of a dated cash-flow series inside +rate_range+.
    #
    # @param cashflows [Array] entries as Money::CashFlow::Entry,
    #   [Money, Date] pairs, or { amount:, date: } hashes
    # @param day_count [Symbol, #call] :act_365, :act_360, :act_act,
    #   :thirty_360, or a callable (from_date, to_date) -> year fraction
    # @param rate_range [Range] search interval for the rate; its lower bound
    #   must be strictly greater than -1 (rates at or below -100% are
    #   meaningless for discounting)
    # @param tolerance [Float] maximum width of each root's isolating interval
    # @param max_evaluations [Integer] NPV evaluation budget; when it runs
    #   out, the not-yet-excluded intervals are reported on the result
    # @param grid_size [Integer] number of scan cells used to isolate roots
    # @return [Money::CashFlow::Result]
    def xirr(cashflows, day_count:, rate_range:, tolerance: DEFAULT_TOLERANCE,
             max_evaluations: DEFAULT_MAX_EVALUATIONS, grid_size: DEFAULT_GRID_SIZE)
      entries = normalize(cashflows)
      currency = single_currency!(entries)
      year_fraction = DayCount.fetch(day_count)
      validate_rate_range!(rate_range)

      if entries.all? { |entry| entry.amount.fractional.zero? }
        return Result.new(status: :all_zero, roots: [], unresolved_intervals: [],
                          evaluations: 0, currency: currency)
      end

      solver = Solver.new(entries: entries, year_fraction: year_fraction,
                          rate_range: rate_range, tolerance: tolerance,
                          max_evaluations: max_evaluations, grid_size: grid_size)
      roots, unresolved = solver.solve

      Result.new(status: roots.empty? ? :no_root : :solved,
                 roots: roots,
                 unresolved_intervals: unresolved,
                 evaluations: solver.evaluations,
                 currency: currency)
    end

    def normalize(cashflows)
      entries = cashflows.map do |raw|
        case raw
        when Entry then raw
        when Array then Entry.new(raw[0], raw[1])
        when Hash then Entry.new(raw.fetch(:amount), raw.fetch(:date))
        else
          raise InvalidEntry, "unsupported cash-flow entry: #{raw.inspect}"
        end
      end
      raise InvalidEntry, "at least one cash flow is required" if entries.empty?

      entries.sort_by(&:date)
    end

    def single_currency!(entries)
      currencies = entries.map { |entry| entry.amount.currency }.uniq
      if currencies.size > 1
        names = currencies.map(&:iso_code).join(", ")
        raise CurrencyMismatch,
              "cash flows must share a single currency (got #{names}); convert " \
              "them explicitly first - no exchange rate is fetched implicitly"
      end
      currencies.first
    end

    def validate_rate_range!(rate_range)
      unless rate_range.is_a?(Range) && rate_range.begin && rate_range.end
        raise InvalidRateRange, "rate_range must be a bounded Range"
      end
      if rate_range.begin <= -1
        raise InvalidRateRange,
              "rate_range must lie within r > -1, got #{rate_range.begin}..#{rate_range.end}"
      end
      unless rate_range.end > rate_range.begin
        raise InvalidRateRange, "rate_range end must be greater than its begin"
      end
    end

    # Isolates roots by scanning a grid uniform in log(1 + rate) - which keeps
    # resolution near the r -> -1 singularity - then refines each sign-change
    # bracket by bisection. Every NPV evaluation is counted against a budget;
    # when the budget is exhausted the intervals that could not be excluded
    # are returned instead of silently dropping them.
    class Solver
      attr_reader :evaluations

      def initialize(entries:, year_fraction:, rate_range:, tolerance:,
                     max_evaluations:, grid_size:)
        reference = entries.first.date
        @amounts = []
        @times = []
        entries.each do |entry|
          amount = entry.amount.to_d.to_f
          next if amount.zero?

          @amounts << amount
          @times << (entry.date == reference ? 0.0 : year_fraction.call(reference, entry.date).to_f)
        end
        @rate_range = rate_range
        @tolerance = tolerance.to_f
        @max_evaluations = max_evaluations
        @grid_size = grid_size
        @evaluations = 0
      end

      # @return [Array(Array<Root>, Array<Range>)] roots and unresolved ranges
      def solve
        rates, values, scan_unresolved, exhausted = scan_grid
        brackets, exact = detect_brackets(rates, values)

        roots = exact.map { |rate| Root.new((rate..rate), rate, 0.0) }
        unresolved = scan_unresolved

        brackets.each do |lo, hi, vlo, vhi|
          if exhausted
            unresolved << (lo..hi)
            next
          end
          root, leftover = bisect(lo, hi, vlo, vhi)
          if root
            roots << root
          else
            exhausted = true
            unresolved << leftover
          end
        end

        [roots.sort_by(&:rate), unresolved]
      end

      private

      def npv(rate)
        @evaluations += 1
        base = 1.0 + rate
        sum = 0.0
        @amounts.each_with_index do |amount, index|
          sum += amount / base**@times[index]
        end
        sum
      end

      def budget_left?
        @evaluations < @max_evaluations
      end

      def scan_grid
        x_lo = Math.log(1.0 + @rate_range.begin.to_f)
        x_hi = Math.log(1.0 + @rate_range.end.to_f)
        step = (x_hi - x_lo) / @grid_size

        rates = []
        values = []
        unresolved = []
        exhausted = false

        (0..@grid_size).each do |i|
          rate = Math.exp(x_lo + i * step) - 1.0
          unless budget_left?
            exhausted = true
            unresolved << (rates.empty? ? @rate_range : (rates.last..@rate_range.end))
            break
          end
          rates << rate
          values << npv(rate)
        end

        [rates, values, unresolved, exhausted]
      end

      def detect_brackets(rates, values)
        brackets = []
        exact = []
        (0...rates.size - 1).each do |i|
          vlo = values[i]
          vhi = values[i + 1]
          exact << rates[i] if vlo.zero?
          brackets << [rates[i], rates[i + 1], vlo, vhi] if (vlo.negative? && vhi.positive?) ||
                                                            (vlo.positive? && vhi.negative?)
        end
        exact << rates.last if rates.any? && values.last.zero?
        [brackets, exact]
      end

      def bisect(lo, hi, vlo, vhi)
        while hi - lo > @tolerance
          return [nil, lo..hi] unless budget_left?

          mid = (lo + hi) / 2.0
          vmid = npv(mid)
          if vmid.zero?
            return [Root.new((mid..mid), mid, 0.0), nil]
          elsif (vmid.negative? && vlo.negative?) || (vmid.positive? && vlo.positive?)
            lo = mid
            vlo = vmid
          else
            hi = mid
            vhi = vmid
          end
        end

        rate = (lo + hi) / 2.0
        [Root.new((lo..hi), rate, npv(rate)), nil]
      end
    end
  end
end
