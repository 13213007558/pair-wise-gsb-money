# frozen_string_literal: true

require "date"

class Money
  # An independent table of historical redenominations (currency reforms),
  # where an old currency is replaced by a new one at a fixed, exact ratio
  # starting on a known date. Unlike +Money::Bank+ exchange rates, these
  # rules are supplied entirely by the caller and are never fetched online.
  #
  # Each rule is effective over the half-open interval
  # +[valid_from, valid_to)+: the rule applies on +valid_from+ itself, and
  # stops applying on +valid_to+, when the next era's rule (if any) takes
  # over. A +nil+ +valid_to+ means the rule is open-ended.
  #
  # Conversion follows the chain of rules forward in time and may span
  # several redenominations. The result carries both a bookable +Money+
  # amount (rounded once, at the end, to the final currency's smallest unit
  # and optional cash rounding step) and the exact +remainder+ that the
  # smallest unit could not absorb, so callers can accumulate and settle it
  # later.
  #
  # @example
  #   table = Money::Redenomination::Table.new
  #   table.register(from: "XOA", to: "XNA", ratio: Rational(1, 1000),
  #                  valid_from: Date.new(2000, 1, 1),
  #                  valid_to: Date.new(2010, 1, 1))
  #   result = table.convert(Money.new(1, "XOA"), Date.new(2005, 6, 1))
  #   result.money     # bookable amount in XNA
  #   result.remainder # exact leftover in XNA subunits (Rational)
  module Redenomination
    # Base class for redenomination errors.
    class Error < StandardError; end

    # Raised when a rule is malformed (bad dates, non-positive ratio, etc).
    class InvalidRuleError < Error; end

    # Raised when a rule's effective interval overlaps another rule for the
    # same +from+ currency.
    class OverlappingRuleError < Error; end

    # Raised when rules form a cycle (A -> B -> ... -> A).
    class CyclicChainError < Error; end

    # Raised when a new rule would create a second conversion path between
    # two currencies whose composed ratio disagrees with the existing one.
    class InconsistentPathError < Error; end

    # A single redenomination rule.
    class Rule
      attr_reader :from_currency, :to_currency, :ratio, :valid_from, :valid_to, :cash_step

      def initialize(from_currency:, to_currency:, ratio:, valid_from:, valid_to:, cash_step:)
        @from_currency = from_currency
        @to_currency   = to_currency
        @ratio         = ratio
        @valid_from    = valid_from
        @valid_to      = valid_to
        @cash_step     = cash_step
      end

      # Whether the rule is in effect on +date+. Intervals are half-open:
      # the rule applies on +valid_from+ but not on +valid_to+.
      def covers?(date)
        valid_from <= date && (valid_to.nil? || date < valid_to)
      end
    end

    # The outcome of a conversion: a bookable +Money+ amount plus the exact
    # remainder that the smallest unit of the target currency (and its cash
    # rounding step) could not absorb.
    class Result
      # @return [Money] bookable amount in the final currency
      attr_reader :money

      # @return [Rational] exact leftover, in subunits of the final
      #   currency, not absorbed by the smallest unit or cash step
      attr_reader :remainder

      # @return [Rational] exact converted amount before rounding, in
      #   subunits of the final currency
      attr_reader :exact_fractional

      # @return [Array<Rule>] the rules that were applied, in order
      attr_reader :rules

      def initialize(money:, remainder:, exact_fractional:, rules:)
        @money            = money
        @remainder        = remainder
        @exact_fractional = exact_fractional
        @rules            = rules
      end

      # @return [Money::Currency] the currency of the result
      def currency
        money.currency
      end

      # @return [Boolean] whether any redenomination rule was applied
      def converted?
        rules.any?
      end
    end

    # A standalone, caller-managed table of redenomination rules.
    class Table
      def initialize
        @rules = []
        @mutex = Mutex.new
      end

      # @return [Array<Rule>] the registered rules
      def rules
        @rules.dup
      end

      # Removes every registered rule.
      def reset!
        @mutex.synchronize { @rules = [] }
      end

      # Registers a redenomination rule.
      #
      # @param from [Money::Currency, String, Symbol] the old currency
      # @param to [Money::Currency, String, Symbol] the new currency
      # @param ratio [Integer, Rational, BigDecimal, String] exact ratio:
      #   1 unit of +from+ equals +ratio+ units of +to+. Floats are rejected
      #   because they cannot represent the ratio exactly.
      # @param valid_from [Date, Time, String] first day the rule applies
      #   (inclusive)
      # @param valid_to [Date, Time, String, nil] day the rule stops applying
      #   (exclusive); +nil+ means open-ended
      # @param cash_step [Integer, nil] optional cash rounding step, in
      #   subunits of +to+ (e.g. 5 for 0.05 rounding)
      #
      # @return [Rule]
      #
      # @raise [InvalidRuleError] on malformed input
      # @raise [OverlappingRuleError] on overlapping intervals for +from+
      # @raise [CyclicChainError] if the rule closes a cycle
      # @raise [InconsistentPathError] if the rule creates a second,
      #   differently-valued conversion path between two currencies
      def register(from:, to:, ratio:, valid_from:, valid_to: nil, cash_step: nil)
        @mutex.synchronize do
          build_rule(from, to, ratio, valid_from, valid_to, cash_step).tap do |candidate|
            validate_no_overlap!(candidate)
            validate_no_cycle!(candidate)
            validate_consistent_path!(candidate)
            @rules << candidate
          end
        end
      end

      # Converts +money+ through every redenomination in effect from +date+
      # onwards, possibly spanning several reforms.
      #
      # The amount is carried through the chain with exact rational
      # arithmetic and rounded only once, at the end, to the final
      # currency's smallest unit (and the last rule's +cash_step+, if any)
      # using +Money.rounding_mode+.
      #
      # @param money [Money] the historical amount
      # @param date [Date, Time, String] the date of the historical amount,
      #   used to select the first applicable rule
      #
      # @return [Result]
      def convert(money, date)
        date     = coerce_date(date)
        currency = money.currency
        exact    = money.fractional.to_r
        applied  = []
        visited  = {}

        loop do
          rule = rule_for(currency, date)
          break unless rule

          if visited[currency.id]
            raise CyclicChainError, "redenomination chain loops back to '#{currency.id}'"
          end
          visited[currency.id] = true

          exact = exact * rule.ratio *
                  subunit_to_unit(rule.to_currency) / subunit_to_unit(currency)
          currency = rule.to_currency
          applied << rule
          break unless rule.valid_to

          date = rule.valid_to
        end

        step    = applied.empty? ? 1 : (applied.last.cash_step || 1)
        rounded = round_rational(exact / step, Money.rounding_mode) * step

        Result.new(
          money: Money.new(rounded.to_i, currency),
          remainder: exact - rounded,
          exact_fractional: exact,
          rules: applied
        )
      end

      private

      def build_rule(from, to, ratio, valid_from, valid_to, cash_step)
        from_currency = Currency.wrap(from)
        to_currency   = Currency.wrap(to)
        valid_from    = coerce_date(valid_from)
        valid_to      = valid_to.nil? ? nil : coerce_date(valid_to)
        ratio         = coerce_ratio(ratio)

        if from_currency == to_currency
          raise InvalidRuleError, "from and to currencies must differ"
        end
        if valid_to && valid_to <= valid_from
          raise InvalidRuleError, "valid_to must be after valid_from"
        end
        unless ratio.positive?
          raise InvalidRuleError, "ratio must be positive"
        end
        if cash_step && (!cash_step.is_a?(Integer) || cash_step <= 0)
          raise InvalidRuleError, "cash_step must be a positive Integer"
        end

        subunit_to_unit(from_currency)
        subunit_to_unit(to_currency)

        Rule.new(
          from_currency: from_currency,
          to_currency: to_currency,
          ratio: ratio,
          valid_from: valid_from,
          valid_to: valid_to,
          cash_step: cash_step
        )
      end

      def validate_no_overlap!(candidate)
        @rules.each do |rule|
          next unless rule.from_currency == candidate.from_currency

          candidate_end = candidate.valid_to
          rule_end      = rule.valid_to
          overlaps      = (candidate_end.nil? || rule.valid_from < candidate_end) &&
                          (rule_end.nil? || candidate.valid_from < rule_end)
          if overlaps
            raise OverlappingRuleError,
                  "rule for '#{candidate.from_currency.id}' starting " +                  "#{candidate.valid_from} overlaps existing rule starting #{rule.valid_from}"
          end
        end
      end

      def validate_no_cycle!(candidate)
        return unless path_ratio(candidate.to_currency.id, candidate.from_currency.id)

        raise CyclicChainError,
              "rule '#{candidate.from_currency.id}' -> '#{candidate.to_currency.id}' " +              "would close a redenomination cycle"
      end

      def validate_consistent_path!(candidate)
        existing = path_ratio(candidate.from_currency.id, candidate.to_currency.id)
        return if existing.nil? || existing == candidate.ratio

        raise InconsistentPathError,
              "'#{candidate.from_currency.id}' can already be converted to " +              "'#{candidate.to_currency.id}' at ratio #{existing.to_f}, which " +              "disagrees with the new rule's ratio #{candidate.ratio.to_f}"
      end

      # Composed ratio of an existing chain of rules from +source_id+ to
      # +target_id+, or +nil+ when no such chain exists.
      def path_ratio(source_id, target_id, seen = {})
        return Rational(1) if source_id == target_id
        return if seen[source_id]

        seen[source_id] = true
        @rules.each do |rule|
          next unless rule.from_currency.id == source_id

          rest = path_ratio(rule.to_currency.id, target_id, seen)
          return rule.ratio * rest if rest
        end
        nil
      end

      def rule_for(currency, date)
        @rules.find do |rule|
          rule.from_currency == currency && rule.covers?(date)
        end
      end

      def subunit_to_unit(currency)
        value = currency.subunit_to_unit
        unless value.is_a?(Numeric) && value.positive?
          raise InvalidRuleError,
                "currency '#{currency.id}' has no usable subunit_to_unit"
        end
        value.to_r
      end

      def coerce_ratio(value)
        case value
        when Float
          raise InvalidRuleError,
                "ratio must be exact; pass an Integer, Rational, BigDecimal " +                "or String instead of a Float"
        when Rational then value
        when Integer then value
        when BigDecimal then value.to_r
        when String then Rational(value)
        else
          raise InvalidRuleError, "unsupported ratio #{value.inspect}"
        end
      end

      def coerce_date(value)
        case value
        when Date then value
        when Time then value.to_date
        when String then Date.parse(value)
        else
          raise InvalidRuleError, "cannot coerce #{value.inspect} to a Date"
        end
      end

      # Rounds a Rational to an Integer honouring +Money.rounding_mode+,
      # exactly (BigDecimal's ROUND_HALF_UP rounds ties away from zero).
      def round_rational(value, mode)
        case mode
        when BigDecimal::ROUND_CEILING
          value.ceil
        when BigDecimal::ROUND_FLOOR
          value.floor
        when BigDecimal::ROUND_UP
          value.negative? ? -value.abs.ceil : value.ceil
        when BigDecimal::ROUND_DOWN
          value.negative? ? -value.abs.floor : value.floor
        when BigDecimal::ROUND_HALF_DOWN
          (value.negative? ? -1 : 1) * (value.abs - Rational(1, 2)).ceil
        when BigDecimal::ROUND_HALF_EVEN
          floor = value.floor
          diff  = value - floor
          if diff < Rational(1, 2)
            floor
          elsif diff > Rational(1, 2)
            floor + 1
          else
            floor.even? ? floor : floor + 1
          end
        else # BigDecimal::ROUND_HALF_UP and any unknown mode
          (value.negative? ? -1 : 1) * (value.abs + Rational(1, 2)).floor
        end
      end
    end

    @default_table = nil
    @default_table_mutex = Mutex.new

    class << self
      # The process-wide default table used by {Money#redenominate}.
      #
      # @return [Table]
      def default_table
        @default_table_mutex.synchronize { @default_table ||= Table.new }
      end

      # Registers a rule on the default table. See {Table#register}.
      def register(**attributes)
        default_table.register(**attributes)
      end

      # Converts using the default table. See {Table#convert}.
      def convert(money, date)
        default_table.convert(money, date)
      end

      # Clears the default table.
      def reset!
        default_table.reset!
      end
    end
  end

  # Converts this amount through the historical redenomination table,
  # possibly spanning several reforms. See
  # {Money::Redenomination::Table#convert}.
  #
  # @param date [Date, Time, String] the date of this historical amount
  # @param table [Money::Redenomination::Table] defaults to the shared
  #   {Money::Redenomination.default_table}
  #
  # @return [Money::Redenomination::Result]
  def redenominate(date, table: Redenomination.default_table)
    table.convert(self, date)
  end
end
