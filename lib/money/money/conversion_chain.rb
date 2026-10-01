# frozen_string_literal: true

class Money
  # An explicit, numerically exact sequence of currency conversions. Each
  # step applies a positive rational exchange rate, subtracts a fixed fee in
  # the destination subunit, and rounds to an integer amount using the given
  # BigDecimal rounding mode.
  class ConversionChain
    # Rational preimage interval with explicit endpoint inclusion.
    RationalInterval = Struct.new(:lower, :upper, :lower_inclusive, :upper_inclusive) do
      def empty?
        lower > upper ||
          (lower == upper && (!lower_inclusive || !upper_inclusive))
      end
    end

    attr_reader :source_currency, :steps

    def initialize(source_currency, steps)
      @source_currency = Currency.wrap(source_currency)
      @steps = normalize_steps(steps)
      validate_currency_sequence
    end

    def self.from_steps(steps, source_currency: nil)
      new(source_currency || infer_source_currency(steps), steps)
    rescue KeyError
      raise ArgumentError, "must provide the source currency"
    end

    def target_currency
      steps.last.to_currency
    end

    def convert(amount)
      money =
        if amount.is_a?(Money)
          amount
        else
          Money.new(ConversionChain.send(:exact_value, amount), source_currency)
        end

      raise ArgumentError, "amount currency does not match the chain source" unless money.currency == source_currency

      steps.reduce(money) { |result, step| step.convert(result) }
    end

      def reverse(target_amount, source_range)
        target_integer = target_integer(target_amount)
        output_domain = RationalInterval.new(target_integer, target_integer, true, true)
        source_domain = integer_domain(source_range)

        return [] if source_domain.empty?

        intervals = steps.reverse.reduce([output_domain]) do |domains, step|
          domains.flat_map do |domain|
            integer_domains(step.preimage(domain.lower, domain.upper))
          end
        end
        ranges = intervals.filter_map do |interval|
          clipped = intersect(interval, source_domain)
          next if clipped.empty?

          integer_range(clipped)
        end
        merge_ranges(ranges.sort_by { |range| [range.begin, range.end] })
      end

    def self.infer_source_currency(steps)
      first = steps.first
      first = first.to_h if first.respond_to?(:to_h)
      first.fetch(:from_currency) { first.fetch(:from) }
    end
    private_class_method :infer_source_currency

    private

    def normalize_steps(steps)
      raise ArgumentError, "conversion chain must not be empty" if steps.empty?

      currency = source_currency
      steps.map do |step|
        normalized = step.is_a?(Step) ? step : Step.new(**step_options(step))
        unless normalized.match_source?(currency)
          raise ArgumentError, "conversion step currencies are not adjacent"
        end
        currency = normalized.to_currency
        normalized
      end
    end

    def step_options(step)
      options = step.to_h.transform_keys(&:to_sym)
      {
        from_currency: options[:from_currency] || options[:from] || options[:input_currency] || source_currency,
        to_currency: options[:to_currency] || options[:to] || options[:output_currency] || options[:currency],
        rate: options[:rate] || options[:exchange_rate],
        fixed_fee: options.fetch(:fixed_fee, options.fetch(:fee, 0)),
        rounding_mode: options.fetch(:rounding_mode, Money.rounding_mode),
      }
    end

    def validate_currency_sequence
      steps.each_cons(2) do |first, second|
        unless first.to_currency == second.from_currency
          raise ArgumentError, "conversion step currencies are not adjacent"
        end
      end
    end

    def target_integer(target_amount)
      amount =
        if target_amount.is_a?(Money)
          unless target_amount.currency == target_currency
            raise ArgumentError, "target currency does not match the chain target"
          end

          ConversionChain.send(:exact_value, target_amount.fractional)
        else
          ConversionChain.send(:exact_value, target_amount)
        end

      unless amount.denominator == 1
        raise ArgumentError, "target amount must be an integer number of subunits"
      end

      amount.to_i
    end

    def integer_domain(range)
      unless range.is_a?(Range)
        raise ArgumentError, "source range must be a finite Range of Integers"
      end
      unless range.begin.is_a?(Integer) && range.end.is_a?(Integer)
        raise ArgumentError, "source range endpoints must be Integers"
      end

      RationalInterval.new(range.begin.to_r, range.end.to_r, true, !range.exclude_end?)
    end

    def integer_domains(interval)
      range = integer_range(interval)
      return [] unless range

      upper = range.end - (range.exclude_end? ? 1 : 0)
      [RationalInterval.new(range.begin.to_r, upper.to_r, true, true)]
    end

    def intersect(first, second)
      lower =
        if first.lower > second.lower
          first
        elsif first.lower < second.lower
          second
        else
          first.lower_inclusive &&= second.lower_inclusive
          first
        end

      upper =
        if first.upper < second.upper
          first
        elsif first.upper > second.upper
          second
        else
          first.upper_inclusive &&= second.upper_inclusive
          first
        end

      RationalInterval.new(
        lower.lower,
        upper.upper,
        lower.lower_inclusive,
        upper.upper_inclusive,
      )
    end

    def integer_range(interval)
      first = interval.lower.ceil
      first += 1 if integer_bound?(interval.lower) && !interval.lower_inclusive

      if integer_bound?(interval.upper)
        endpoint = interval.upper.to_i
        last = interval.upper_inclusive ? endpoint : endpoint - 1
        return if first > last

        first..last
      else
        last = interval.upper.floor
        return if first > last

        first..last
      end
    end

    def merge_ranges(ranges)
      ranges.each_with_object([]) do |range, merged|
        if merged.empty?
          merged << range
        else
          previous = merged.last
          previous_last = previous.end - (previous.exclude_end? ? 1 : 0)
          current_first = range.begin
          current_last = range.end - (range.exclude_end? ? 1 : 0)
          if current_first <= previous_last
            upper = [previous_last, current_last].max
            merged[-1] = previous.begin..upper
          else
            merged << range
          end
        end
      end
    end

    def integer_bound?(value)
      value.denominator == 1
    end

    def self.exact_value(value)
      case value
      when Integer, Rational
        value.to_r
      when BigDecimal
        raise ArgumentError, "numeric value must be finite" unless value.finite?

        value.to_r
      when Money
        exact_value(value.fractional)
      else
        raise ArgumentError, "#{value.class} is not an exact numeric value; use Integer, Rational, or BigDecimal"
      end
    end
    private_class_method :exact_value

    # One currency conversion with an optional fixed, destination-currency fee.
    class Step
      # BigDecimal rounding constants accepted by an explicit chain step.
      ROUNDING_MODES = [
        BigDecimal::ROUND_UP,
        BigDecimal::ROUND_DOWN,
        BigDecimal::ROUND_CEILING,
        BigDecimal::ROUND_FLOOR,
        BigDecimal::ROUND_HALF_UP,
        BigDecimal::ROUND_HALF_DOWN,
        BigDecimal::ROUND_HALF_EVEN,
      ].freeze

      attr_reader :from_currency, :to_currency, :rate, :fixed_fee, :rounding_mode

      def initialize(rate:, to_currency:, from_currency:, fixed_fee: 0, rounding_mode: Money.rounding_mode)
        @from_currency = Currency.wrap(from_currency)
        @to_currency = Currency.wrap(to_currency)
        @rate = exact_value(rate)
        @fixed_fee = exact_value(fixed_fee)
        @rounding_mode = rounding_mode

        raise ArgumentError, "exchange rate must be positive" unless @rate.positive?
        unless ROUNDING_MODES.include?(@rounding_mode)
          raise ArgumentError, "unsupported rounding mode"
        end
      end

      def convert(money)
        unless money.currency == from_currency
          raise ArgumentError, "amount currency does not match the conversion step source"
        end

        unrounded = money.fractional.to_r * effective_rate - @fixed_fee
        rounded = round_exact(unrounded)
        money.dup_with(fractional: rounded, currency: to_currency)
      end

      def match_source?(currency)
        from_currency == Currency.wrap(currency)
      end

      def preimage(minimum_output, maximum_output)
        minimum = minimum_output.to_i
        maximum = maximum_output.to_i
        interval = rounded_preimage(minimum, maximum, rounding_mode)
        RationalInterval.new(
          invert(interval.lower),
          invert(interval.upper),
          interval.lower_inclusive,
          interval.upper_inclusive,
        )
      end

      private

      def effective_rate
        rate * Rational(to_currency.subunit_to_unit, from_currency.subunit_to_unit)
      end

      def invert(value)
        (value + @fixed_fee) / effective_rate
      end

      def rounded_preimage(minimum, maximum, mode)
        candidates = boundary_candidates(minimum, maximum)
        target_cells = candidates.each_cons(2).filter_map do |left, right|
          next if left == right
          next unless (minimum..maximum).cover?(round_exact((left + right) / 2))

          [left, right]
        end
        return single_preimage(minimum, mode) if target_cells.empty? && minimum == maximum

        left = target_cells.map(&:first).min
        right = target_cells.map(&:last).max
        RationalInterval.new(
          left,
          right,
          (minimum..maximum).cover?(round_exact(left)),
          (minimum..maximum).cover?(round_exact(right)),
        )
      end

      def single_preimage(output, mode)
        return RationalInterval.new(0, 0, true, true) if output.zero? && mode == BigDecimal::ROUND_UP
        return RationalInterval.new(-1, 0, false, true) if output.zero? && mode == BigDecimal::ROUND_CEILING
        return RationalInterval.new(0, 1, true, false) if output.zero? && mode == BigDecimal::ROUND_FLOOR
        return RationalInterval.new(-1, 1, false, false) if output.zero? && mode == BigDecimal::ROUND_DOWN

        candidates = boundary_candidates(output, output)
        target_cells = candidates.each_cons(2).filter_map do |left, right|
          midpoint = (left + right) / 2
          next unless round_exact(midpoint) == output

          [left, right]
        end
        left = target_cells.map(&:first).min
        right = target_cells.map(&:last).max
        RationalInterval.new(left, right, round_exact(left) == output, round_exact(right) == output)
      end

      def boundary_candidates(minimum, maximum)
        edges = [minimum - 1, minimum, maximum, maximum + 1]
        half_edges = [
          minimum - Rational(1, 2),
          minimum + Rational(1, 2),
          maximum - Rational(1, 2),
          maximum + Rational(1, 2),
        ]
        (edges + half_edges).uniq.sort
      end

      def round_exact(value)
        numerator = value.numerator
        denominator = value.denominator
        floor, remainder = numerator.divmod(denominator)

        case rounding_mode
        when BigDecimal::ROUND_UP
          return value.positive? ? value.ceil : value.floor unless value.zero?
          0
        when BigDecimal::ROUND_DOWN
          value.positive? ? floor : value.ceil
        when BigDecimal::ROUND_CEILING
          value.ceil
        when BigDecimal::ROUND_FLOOR
          floor
        else
          round_nearest(value, numerator, floor, remainder, denominator)
        end
      end

      def round_nearest(value, numerator, floor, remainder, denominator)
        tie = remainder * 2 == denominator
        if remainder * 2 < denominator
          floor
        elsif !tie
          floor + 1
        elsif rounding_mode == BigDecimal::ROUND_HALF_EVEN
          floor.even? ? floor : floor + 1
        elsif value.negative?
          rounding_mode == BigDecimal::ROUND_HALF_UP ? floor : floor + 1
        else
          rounding_mode == BigDecimal::ROUND_HALF_UP ? floor + 1 : floor
        end
      end

      def exact_value(value)
        ConversionChain.send(:exact_value, value)
      end
    end
  end

  # Finds every integer subunit amount in a finite source range that reaches
  # the target amount after applying the explicit conversion chain.
  def self.reverse_convert(target_amount, source_range, chain_or_steps, from_currency: nil)
    chain =
      if chain_or_steps.is_a?(ConversionChain)
        chain_or_steps
      else
        ConversionChain.from_steps(chain_or_steps, source_currency: from_currency)
      end

    chain.reverse(target_amount, source_range)
  end

  class << self
    alias reverse_exchange reverse_convert
  end
end
