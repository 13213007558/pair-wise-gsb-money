# frozen_string_literal: true

class Money
  class CashFlow
    # Finds every internal rate of return (root of NPV) inside a search range.
    #
    # Rather than starting a Newton-style iteration from a guess, the search
    # adaptively subdivides the interval. Subdivision uses term-wise monotonic
    # bounds of NPV and its derivative, so intervals without a root can be
    # discarded without sampling them at arbitrary points. This separates:
    #
    # * sign-changing roots (+f(a) * f(b) <= 0+), reported as simple roots;
    # * tangent/multiple roots that never cross zero, reported separately;
    # * intervals that could not be excluded before the evaluation budget ran
    #   out (returned as unresolved).
    #
    # @api private
    class Xirr
      DEFAULT_BUDGET = 50_000
      DEFAULT_LOW = -0.9999
      DEFAULT_HIGH = 10.0

      # A located rate with the interval that isolates it and the NPV value at
      # the reported rate.
      Root = Struct.new(:rate, :low, :high, :residual, keyword_init: true) do
        def multiple?
          is_a?(MultipleRoot)
        end
      end

      # A root of even multiplicity where NPV touches zero without changing
      # sign.
      class MultipleRoot < Root; end

      # An interval that was not classified or excluded before the budget ran
      # out.
      Unresolved = Struct.new(:low, :high, :reason, keyword_init: true)

      # Complete outcome of a search.
      #
      # +status+ is one of +:ok+ (at least one root found, search complete),
      # +:no_roots+ (the whole range was excluded), +:all_zero+ (every cash flow
      # is zero, so NPV vanishes for every rate), +:budget_exhausted+ or
      # +:incomplete+ (a residual interval could not be classified, e.g. at the
      # limit of floating-point precision).
      Result = Struct.new(
        :status, :roots, :multiple_roots, :unresolved_intervals,
        :evaluations, :budget, :low, :high, :currency, :cash_flow,
        keyword_init: true
      ) do
        def complete?
          status == :ok || status == :no_roots || status == :all_zero
        end

        def all_roots
          roots + multiple_roots
        end

        def rates
          all_roots.map(&:rate)
        end
      end

      BudgetExhausted = Class.new(StandardError) do
        attr_reader :evaluations

        def initialize(evaluations)
          @evaluations = evaluations
          super("NPV evaluation budget exhausted after #{evaluations} evaluations")
        end
      end

      Interval = Struct.new(:low, :high, :open_right, keyword_init: true) do
        def initialize(low:, high:, open_right: false)
          super
        end

        def width
          high - low
        end
      end

      private_constant :Interval

      def initialize(cash_flow)
        @cash_flow = cash_flow
        @terms = cash_flow.flows.map do |date, amount|
          [cash_flow.year_fraction(date).to_f, amount.fractional.to_f]
        end
        @scale = @terms.sum { |_t, amount| amount.abs }.to_f
        @value_cache = {}
        @evaluations = 0
      end

      # @return [Result]
      def solve(lower, upper, exclude_upper:, tol:, budget:, residual_tol:)
        @budget = budget
        @tol = tol
        @residual_tol = residual_tol || [@scale * 1e-8, 1e-12].max.to_f

        roots = []
        multiple_roots = []
        unresolved = []
        queue = [Interval.new(low: lower, high: upper, open_right: exclude_upper)]

        begin
          until queue.empty?
            interval = queue.shift
            fa = evaluate(interval.low)
            fb = interval.open_right ? nil : evaluate(interval.high)

            next unless range_contains_zero?(value_enclosure(interval))

            if interval.width <= @tol
              kind, data = terminal(interval, fa, fb)
              roots << data if kind == :simple
              multiple_roots << data if kind == :multiple
              next
            end

            monotone = !range_contains_zero?(derivative_enclosure(interval))
            next if fa && fb && monotone && same_sign?(fa, fb)

            mid = midpoint(interval.low, interval.high)
            if mid == interval.high
              unresolved << Unresolved.new(low: interval.low, high: interval.high,
                                          reason: :float_precision)
              next
            end
            queue.unshift(Interval.new(low: mid, high: interval.high,
                                          open_right: interval.open_right))
            queue.unshift(Interval.new(low: interval.low, high: mid))
          end
        rescue BudgetExhausted => e
          if queue.empty?
            # The budget was spent on the final evaluation; nothing remains to
            # be searched.
            roots, multiple_roots = dedupe(roots, multiple_roots)
            status = roots.empty? && multiple_roots.empty? ? :no_roots : :ok
            return result(status, roots, multiple_roots, unresolved, e.evaluations, lower, upper)
          end

          queue.each do |remaining|
            unresolved << Unresolved.new(low: remaining.low, high: remaining.high,
                                        reason: :budget)
          end
          roots, multiple_roots = dedupe(roots, multiple_roots)
          return result(:budget_exhausted, roots, multiple_roots, unresolved,
                        e.evaluations, lower, upper)
        end

        roots, multiple_roots = dedupe(roots, multiple_roots)
        status = final_status(roots, multiple_roots, unresolved)
        result(status, roots, multiple_roots, unresolved, @evaluations, lower, upper)
      end

      private

      def final_status(roots, multiple_roots, unresolved)
        if unresolved.any?
          all_budget = unresolved.all? { |item| item.reason == :budget }
          all_budget ? :budget_exhausted : :incomplete
        elsif roots.empty? && multiple_roots.empty?
          :no_roots
        else
          :ok
        end
      end

      def terminal(interval, fa, fb)
        if fb && cross_zero?(fa, fb)
          # Floating-point noise can make an even-multiplicity root appear
          # to cross zero; a genuine sign-changing root at this width would
          # have at least one endpoint well outside the residual tolerance.
          if fa.abs <= @residual_tol && fb.abs <= @residual_tol
            if stationary_zero?(interval, fa, fb)
              rate, value = tangent_root(interval)
            else
              return [:simple, polish(interval)]
            end
            return [
              :multiple,
              MultipleRoot.new(
                rate: rate, low: interval.low, high: interval.high,
                residual: @cash_flow.build_money(value)
              )
            ]
          end

          return [:simple, polish(interval)]
        end

        stationary = stationary_point(interval)
        if stationary
          rate, value = stationary
          if value.abs <= @residual_tol
            return [
              :multiple,
              MultipleRoot.new(
                rate: rate, low: interval.low, high: interval.high,
                residual: @cash_flow.build_money(value)
              )
            ]
          end
        end

        [:skip, nil]
      end

      # Bisects a sign-changing bracket until narrower than the tolerance and
      # reports the evaluated point with the smallest |NPV|.
      def polish(interval)
        a = interval.low
        b = interval.high
        fa = evaluate(a)
        fb = evaluate(b)
        best_rate = fa.abs <= fb.abs ? a : b
        best_value = [fa, fb].min_by(&:abs)

        while (b - a) > @tol
          mid = midpoint(a, b)
          fm = evaluate(mid)
          if fm.zero?
            best_rate = mid
            best_value = 0.0
            break
          end

          if cross_zero?(fa, fm)
            b = mid
            fb = fm
          else
            a = mid
            fa = fm
          end

          next unless fm.abs < best_value.abs

          best_value = fm
          best_rate = mid
        end

        low = [a, b].min
        high = [a, b].max
        Root.new(rate: best_rate, low: low, high: high,
                 residual: @cash_flow.build_money(best_value))
      end

      # Locates a stationary point of NPV inside a terminal same-sign interval
      # by bisecting the derivative. Returns nil when the derivative values do
      # not bracket zero.
      def stationary_point(interval)
        a = interval.low
        b = interval.high
        da = derivative(a)
        db = derivative(b)
        return nil unless cross_zero?(da, db)

        80.times do
          break if (b - a) <= @tol

          mid = midpoint(a, b)
          dm = derivative(mid)
          if dm.zero?
            a = b = mid
            break
          elsif cross_zero?(da, dm)
            b = mid
            db = dm
          else
            a = mid
            da = dm
          end
        end

        rate = da.abs <= db.abs ? a : b
        [rate, evaluate(rate)]
      end

      # A bracket whose endpoints are both below the residual tolerance is a
      # tangent/multiple root only when NPV' vanishes there too. At a simple
      # root NPV crosses with a non-zero slope.
      def stationary_zero?(interval, fa, fb)
        rate = fa.abs <= fb.abs ? interval.low : interval.high
        derivative(rate).abs <= derivative_scale * 1e-7
      end

      def derivative_scale
        @derivative_scale ||= @terms.sum { |t, coefficient| (t * coefficient).abs }
      end

      # Locates the stationary point of a tangent root and its NPV value.
      def tangent_root(interval)
        stationary = stationary_point(interval)
        if stationary && stationary.last.abs <= @residual_tol
          stationary
        else
          mid = midpoint(interval.low, interval.high)
          [mid, evaluate(mid)]
        end
      end

      def dedupe(roots, multiple_roots)
        [
          merge_adjacent(roots.sort_by(&:low)),
          merge_adjacent(multiple_roots.sort_by(&:low))
        ]
      end

      def merge_adjacent(sorted)
        sorted.each_with_object([]) do |current, merged|
          if merged.any? && current.low <= merged.last.high + 4 * @tol
            merged[-1] = merge_roots(merged.last, current)
          else
            merged << current
          end
        end
      end

      def merge_roots(left, right)
        better = [left, right].min_by { |root| root.residual.fractional.abs }
        better.class.new(
          rate: better.rate,
          low: [left.low, right.low].min,
          high: [left.high, right.high].max,
          residual: better.residual
        )
      end

      # Term-wise range of NPV over [a, b]. Every term is monotone, so its
      # extrema are attained at the endpoints.
      def value_enclosure(interval)
        sum_ranges(@terms.map { |t, coefficient| term_range(t, coefficient, interval) })
      end

      # Term-wise range of NPV' over [a, b]. Each term -t*c*x^(-t-1) is also
      # monotone, so endpoint sampling bounds it exactly.
      def derivative_enclosure(interval)
        sum_ranges(@terms.map do |t, coefficient|
          factors = endpoint_factors(t, interval)
          values = factors.map { |factor| -t * coefficient * factor }
          values.minmax
        end)
      end

      def term_range(t, coefficient, interval)
        lo_factor, hi_factor = endpoint_factors(t, interval).minmax
        lo = lo_factor * coefficient
        hi = hi_factor * coefficient
        lo, hi = hi, lo if coefficient.negative?
        [lo, hi]
      end

      def endpoint_factors(t, interval)
        [discount(t, interval.low), discount(t, interval.high)]
      end

      def sum_ranges(ranges)
        lo = safe_sum(ranges.map(&:first))
        hi = safe_sum(ranges.map(&:last))
        [lo, hi]
      end

      # Sums values while avoiding +Infinity + (-Infinity)+ NaN by rescaling
      # around the largest magnitude. Mixed infinities yield NaN, which callers
      # treat conservatively (the interval cannot be excluded).
      def safe_sum(values)
        values = values.reject(&:zero?)
        return 0.0 if values.empty?

        positive = values.count { |value| value > 0 }
        negative = values.count { |value| value < 0 }
        if values.any?(&:infinite?)
          return Float::NAN if positive.positive? && negative.positive?
          return positive.positive? ? Float::INFINITY : -Float::INFINITY
        end

        largest = values.map(&:abs).max
        scaled = values.sum { |value| value / largest }
        scaled * largest
      end

      def evaluate(rate)
        @value_cache[rate] ||= begin
          @evaluations += 1
          raise BudgetExhausted.new(@evaluations) if @evaluations > @budget

          safe_sum(@terms.map { |t, coefficient| coefficient * discount(t, rate) })
        end
      end

      def derivative(rate)
        safe_sum(@terms.map { |t, coefficient| -t * coefficient * discount(t, rate) })
      end

      def discount(t, rate)
        return 1.0 if t.zero?

        exponent = -t * Math.log(1.0 + rate)
        return 0.0 if exponent < -745.0

        Math.exp(exponent)
      end

      def midpoint(a, b)
        mid = (a + b) / 2.0
        mid == a || mid == b ? b : mid
      end

      def cross_zero?(x, y)
        return false if x.nan? || y.nan?

        (x <= 0 && y >= 0) || (x >= 0 && y <= 0)
      end

      def same_sign?(x, y)
        return false if x.nan? || y.nan?

        (x > 0 && y > 0) || (x < 0 && y < 0)
      end

      def range_contains_zero?(range)
        lo, hi = range
        return true if lo.nan? || hi.nan?

        lo <= 0 && hi >= 0
      end

      def result(status, roots, multiple_roots, unresolved, evaluations, lower, upper)
        Result.new(
          status: status,
          roots: roots,
          multiple_roots: multiple_roots,
          unresolved_intervals: unresolved,
          evaluations: evaluations,
          budget: @budget,
          low: lower,
          high: upper,
          currency: @cash_flow.currency,
          cash_flow: @cash_flow
        )
      end
    end
  end
end
