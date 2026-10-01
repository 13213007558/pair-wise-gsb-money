# frozen_string_literal: true

class Money
  # Decomposes a tax-inclusive gross amount into an integer net amount and
  # per-tax amounts, all expressed in the currency's minor unit (e.g. cents).
  #
  # Each tax is computed from a base that may depend on the net amount and on
  # other taxes (e.g. a tax levied on net + a previous tax). Dependencies must
  # form an acyclic graph. Rates are exact, non-negative numbers and every tax
  # is rounded individually to a whole minor unit according to its own
  # rounding rule.
  #
  # Because rates are non-negative, each rounded tax amount is non-decreasing
  # in the net amount, which makes the gross total a strictly increasing
  # function of the net amount. Therefore any gross total has at most one
  # exact integer decomposition. The search exploits that monotonicity: it
  # returns the unique exact decomposition, or nil when the per-item rounding
  # rules make the gross total unreachable. No fractional penny adjustment
  # is ever introduced to force a match.
  #
  # This is a pure calculation helper: it ships no jurisdiction-specific tax
  # rules.
  #
  # @example Decompose a total with one tax on the net and one on net + first tax
  #   result = Money::TaxDecomposition.decompose(11_547, [
  #     { name: :gst, rate: Rational(5, 100), base: [:net], rounding: :half_up },
  #     { name: :qst, rate: Rational(9975, 100_000), base: [:net, :gst], rounding: :half_up },
  #   ])
  #   result.net   # => 10_000
  #   result.taxes # => { gst: 500, qst: 1047 }
  class TaxDecomposition
    # Raised when the tax base dependencies form a cycle.
    class CyclicTaxBaseError < StandardError; end

    # Per-tax rounding rules applied to the exact (rational) tax amount.
    #
    # - +:half_up+   round half away from zero
    # - +:half_down+ round half towards zero
    # - +:half_even+ round half to even (banker's rounding)
    # - +:down+      round towards zero
    # - +:up+        round away from zero
    ROUNDING_MODES = %i[half_up half_down half_even down up].freeze

    # Definition of a single tax.
    class Tax
      # @return [Symbol] unique name of the tax, referenced by other taxes' bases.
      attr_reader :name

      # @return [Rational] exact, non-negative rate applied to the base.
      attr_reader :rate

      # @return [Array<Symbol>] components summed into the taxable base:
      #   +:net+ and/or names of other taxes.
      attr_reader :base

      # @return [Symbol] rounding rule, one of ROUNDING_MODES.
      attr_reader :rounding

      def initialize(name:, rate:, base: [:net], rounding: :half_up)
        @name = name.to_sym
        @rate = TaxDecomposition.send(:normalize_rate, rate)
        @base = Array(base).map(&:to_sym).freeze
        @rounding = rounding.to_sym

        raise ArgumentError, "tax #{@name.inspect} must have at least one base component" if @base.empty?

        unless ROUNDING_MODES.include?(@rounding)
          raise ArgumentError, "unknown rounding rule #{rounding.inspect}, expected one of #{ROUNDING_MODES.inspect}"
        end
      end
    end

    # The unique exact decomposition of a gross total.
    class Result
      # @return [Integer] net amount in minor units.
      attr_reader :net

      # @return [Hash{Symbol => Integer}] tax amounts in minor units, keyed by tax name.
      attr_reader :taxes

      # @return [Integer] the gross total in minor units (always == net + taxes.sum).
      attr_reader :total

      def initialize(net:, taxes:, total:)
        @net = net
        @taxes = taxes.freeze
        @total = total
      end

      def ==(other)
        other.is_a?(Result) && net == other.net && taxes == other.taxes && total == other.total
      end
      alias eql? ==

      def hash
        [net, taxes, total].hash
      end
    end

    # Finds the unique integer net amount and per-tax amounts that reproduce
    # the given gross total exactly.
    #

    # @param total [Integer] gross (tax-inclusive) amount in minor units, >= 0.
    # @param taxes [Array<Tax, Hash>] tax definitions (see Tax).
    #
    # @return [Result, nil] the unique exact decomposition, or nil when no
    #   integer net amount reproduces the total under the given rounding rules.
    #
    # @raise [ArgumentError] on a negative total, an invalid rate, an unknown
    #   base component, or an unknown rounding rule.
    # @raise [CyclicTaxBaseError] when tax base dependencies form a cycle.
    def self.decompose(total, taxes)
      total = normalize_total(total)
      ordered = topological_order(normalize_taxes(taxes))

      # gross(net) is strictly increasing in net, so binary search finds the
      # only candidate that can match +total+.
      lo = 0
      hi = total
      while lo <= hi
        mid = (lo + hi) / 2
        amounts = tax_amounts(mid, ordered)
        gross = mid + amounts.values.sum

        return Result.new(net: mid, taxes: amounts, total: total) if gross == total

        if gross < total
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      nil
    end

    # Computes the gross total produced by a given integer net amount.
    #
    # @param net [Integer] net amount in minor units, >= 0.
    # @param taxes [Array<Tax, Hash>] tax definitions (see Tax).
    #
    # @return [Integer] gross amount in minor units.
    def self.gross_for(net, taxes)
      net = normalize_total(net)
      ordered = topological_order(normalize_taxes(taxes))
      net + tax_amounts(net, ordered).values.sum
    end

    class << self
      private

      def normalize_total(total)
        unless total.is_a?(Integer)
          raise ArgumentError, "amount must be an Integer in the currency's minor unit, got #{total.inspect}"
        end
        raise ArgumentError, "amount must be non-negative, got #{total}" if total.negative?

        total
      end

      def normalize_rate(rate)
        rational =
          case rate
          when Rational then rate
          when Integer then Rational(rate)
          when String then Rational(rate)
          when BigDecimal then rate.to_r
          when Float
            raise ArgumentError,
              "tax rate must be exact; use a Rational, Integer, String, or BigDecimal instead of Float #{rate.inspect}"
          else
            raise ArgumentError, "tax rate must be numeric, got #{rate.inspect}"
          end

        raise ArgumentError, "tax rate must be non-negative, got #{rate.inspect}" if rational.negative?

        rational
      end

      def normalize_taxes(taxes)
        taxes.map do |tax|
          next tax if tax.is_a?(Tax)

          Tax.new(**tax.to_h { |key, value| [key.to_sym, value] })
        end
      end

      # Orders taxes so that every tax appears after the taxes it depends on.
      def topological_order(taxes)
        by_name = {}
        taxes.each do |tax|
          raise ArgumentError, "duplicate tax name #{tax.name.inspect}" if by_name.key?(tax.name)

          by_name[tax.name] = tax
        end

        indegree = Hash.new(0)
        dependents = Hash.new { |hash, key| hash[key] = [] }
        taxes.each do |tax|
          tax.base.each do |component|
            next if component == :net

            unless by_name.key?(component)
              raise ArgumentError, "tax #{tax.name.inspect} depends on unknown base #{component.inspect}"
            end

            dependents[component] << tax.name
            indegree[tax.name] += 1
          end
        end

        queue = taxes.map(&:name).select { |name| indegree[name].zero? }
        ordered = []
        until queue.empty?
          name = queue.shift
          ordered << by_name.fetch(name)
          dependents[name].each do |dependent|
            indegree[dependent] -= 1
            queue << dependent if indegree[dependent].zero?
          end
        end

        raise CyclicTaxBaseError, "tax base dependencies contain a cycle" if ordered.size < taxes.size

        ordered
      end

      def tax_amounts(net, ordered_taxes)
        amounts = {}
        ordered_taxes.each do |tax|
          base_amount = tax.base.sum { |component| component == :net ? net : amounts.fetch(component) }
          amounts[tax.name] = round_tax(tax.rate * base_amount, tax.rounding)
        end
        amounts
      end

      def round_tax(value, rounding)
        case rounding
        when :half_up then value.round(half: :up)
        when :half_down then value.round(half: :down)
        when :half_even then value.round(half: :even)
        when :down then value.floor
        when :up then value.ceil
        end
      end
    end
  end
end
