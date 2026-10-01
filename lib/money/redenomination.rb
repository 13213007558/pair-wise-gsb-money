# frozen_string_literal: true

require "date"

class Money
  # Historical, caller-provided currency redenomination rules. This table does
  # not perform foreign-exchange lookups and never accesses the network.
  module Redenomination
    Error = Class.new(StandardError)
    InvalidRule = Class.new(Error)
    OverlappingRules = Class.new(InvalidRule)
    CircularChain = Class.new(InvalidRule)
    InconsistentPath = Class.new(InvalidRule)
    MissingPath = Class.new(InvalidRule)

    # A single exact historical replacement.
    #
    # +ratio+ is expressed in major monetary units: one old unit converts to
    # +ratio+ new units. The effective interval is half-open:
    # [effective_from, effective_to). On +effective_from+ this rule is used;
    # on +effective_to+ a rule starting on that date is used instead.
    Rule = Struct.new(:from_currency, :to_currency, :ratio,
                      :effective_from, :effective_to, keyword_init: true) do
      def active_on?(date)
        effective_from <= date && (effective_to.nil? || date < effective_to)
      end
    end

    # Exact result of a historical conversion. +money+ is aligned to the
    # destination currency's smallest bookkeeping subunit. +remainder+ is the
    # remaining amount in that same fractional unit and can be aggregated with
    # other remainders before rounding.
    Result = Struct.new(:money, :remainder, :cash, :exact_amount,
                        :applied_rules, keyword_init: true)

    # Stores an immutable set of redenomination rules.
    class Table
      def initialize(rules = [])
        @rules = rules.map { |rule| build_rule(rule) }.freeze
        validate!
      end

      # Converts old money through a historical chain. +date+ selects the rule
      # active for the source money using [effective_from, effective_to); on
      # +effective_from+ the rule is active, while on +effective_to+ it is not.
      # After that first step, later rules are applied in chronological order.
      def redenominate(money, date:, to_currency: nil, rounding_mode: Money.rounding_mode)
        date = parse_date(date)
        target = wrap_currency(to_currency)
        path = find_path(money.currency, target, date)

        exact_major_amount = Rational(money.fractional.to_s) /
                             Rational(money.currency.subunit_to_unit.to_s)
        path.each do |rule|
          exact_major_amount *= Rational(rule.ratio)
        end

        destination = destination_currency(money.currency, path)
        exact_fractional = exact_major_amount * Rational(destination.subunit_to_unit.to_s)
        build_result(money, destination, exact_fractional, path, rounding_mode)
      end

      def rules_for(currency, date)
        date = parse_date(date)
        code = code_from(currency)
        active_rules(code, date)
      end

      private

      attr_reader :rules

      def build_rule(value)
        unless value.is_a?(Hash) || value.is_a?(Rule)
          raise InvalidRule, "redenomination rule must be a Hash or Rule"
        end

        attributes = value.to_h.transform_keys(&:to_sym)
        from = attributes.fetch(:from_currency)
        to = attributes.fetch(:to_currency)
        ratio = parse_ratio(attributes.fetch(:ratio))
        starts_on = parse_date(attributes.fetch(:effective_from))
        ends_on = parse_optional_date(attributes[:effective_to])

        raise InvalidRule, "rule must start before it ends" if ends_on && starts_on >= ends_on
        if code_from(from) == code_from(to)
          raise CircularChain, "redenomination rule cannot use the same source and destination currency"
        end

        Rule.new(
          from_currency: code_from(from),
          to_currency: code_from(to),
          ratio: ratio,
          effective_from: starts_on,
          effective_to: ends_on,
        ).freeze
      end

      def parse_ratio(value)
        exact = value.is_a?(Integer) || value.is_a?(Rational) ||
                value.is_a?(BigDecimal) || value.is_a?(String)
        raise InvalidRule, "ratio must be Integer, Rational, BigDecimal, or an exact String" unless exact

        ratio = Rational(value)
        unless ratio.positive? && ratio.finite?
          raise InvalidRule, "ratio must be positive and finite"
        end

        ratio
      rescue ArgumentError, ZeroDivisionError
        raise InvalidRule, "ratio must be an exact rational number"
      end

      def validate!
        validate_overlaps!
        validate_cycles!
        validate_paths!
      end

      def validate_overlaps!
        rules.group_by(&:from_currency).each_value do |source_rules|
          sorted = source_rules.sort_by(&:effective_from)
          sorted.each_cons(2) do |first, second|
            next if first.effective_to && first.effective_to <= second.effective_from

            raise OverlappingRules,
                  "overlapping redenomination rules from #{first.from_currency}: " \
                  "#{first.effective_from}...#{first.effective_to} and " \
                  "#{second.effective_from}...#{second.effective_to}"
          end
        end
      end

      def validate_cycles!
        nodes.each { |node| visit_for_cycle(node, {}) }
      end

      def visit_for_cycle(node, visited)
        case visited[node]
        when :active
          raise CircularChain, "redenomination chain contains a cycle at #{node}"
        when :done
          return
        end

        visited[node] = :active
        adjacency.fetch(node, []).each { |edge| visit_for_cycle(edge.to_currency, visited) }
        visited[node] = :done
      end

      def validate_paths!
        nodes.each do |source|
          known = {}
          adjacency.fetch(source, []).each do |first|
            collect_path_rates(source, first, first, first.ratio, known)
          end
        end
      end

      def collect_path_rates(start, current, previous, rate, known)
        destination = current.to_currency
        known_pair = known[[start, destination]]
        if known_pair && known_pair != rate
          raise InconsistentPath,
                "inconsistent redenomination path from #{start} to #{destination}"
        end
        known[[start, destination]] = rate

        adjacency.fetch(destination, []).each do |rule|
          next unless rule.effective_from >= previous.effective_from

          collect_path_rates(start, rule, rule, rate * rule.ratio, known)
        end
      end

      def find_path(source_currency, target, date)
        source = code_from(source_currency)
        return [] if target && source == target.id.to_s

        candidates = active_rules(source, date)
        raise MissingPath, "no historical redenomination path from #{source}" if candidates.empty?

        candidates.each do |rule|
          path = find_chain(rule, target)
          return path unless path.nil?
        end

        raise MissingPath, "no historical redenomination path from #{source} to #{target.id.upcase}"
      end

      def active_rules(source, date)
        rules_by_from[source].to_a
                        .select { |rule| rule.active_on?(date) }
                        .sort_by(&:effective_from)
      end

      def find_chain(rule, target)
        path = [rule]
        return path if target && rule.to_currency == target.id.to_s

        later_rules(rule).each do |next_rule|
          continuation = find_chain(next_rule, target)
          next if continuation.nil?

          return path + continuation
        end

        target.nil? ? path : nil
      end

      def later_rules(rule)
        rules_by_from[rule.to_currency].to_a.filter_map do |candidate|
          candidate if candidate.effective_from >= rule.effective_from
        end.sort_by(&:effective_from)
      end

      def destination_currency(source_currency, path)
        path.empty? ? source_currency : Money::Currency.wrap(path.last.to_currency)
      end

      def build_result(original_money, destination, exact_fractional, path, rounding_mode)
        bookable_fractional = exact_fractional.truncate
        remainder = exact_fractional - bookable_fractional

        money = Money.new(bookable_fractional.to_i, destination, bank: original_money.bank)
        step = destination.smallest_denomination
        unless step
          raise Money::UndefinedSmallestDenomination,
                "Smallest denomination of this currency is not defined"
        end

        cash_step = Rational(step.to_s)
        cash_fractional = round_cash(exact_fractional, cash_step, rounding_mode)
        cash = Money.new(cash_fractional.to_i, destination, bank: original_money.bank)

        Result.new(
          money: money,
          remainder: remainder,
          cash: cash,
          exact_amount: exact_fractional / Rational(destination.subunit_to_unit.to_s),
          applied_rules: path,
        )
      end

      def round_cash(amount, step, rounding_mode)
        units = amount / step
        rounded = case rounding_mode
                  when BigDecimal::ROUND_UP
                    amount.negative? ? units.floor : units.ceil
                  when BigDecimal::ROUND_DOWN
                    amount.negative? ? units.ceil : units.floor
                  when BigDecimal::ROUND_CEILING
                    units.ceil
                  when BigDecimal::ROUND_FLOOR
                    units.floor
                  when BigDecimal::ROUND_HALF_DOWN
                    round_half(units, 0)
                  when BigDecimal::ROUND_HALF_EVEN
                    round_half_even(units)
                  else
                    round_half(units, 1)
                  end
        rounded * step
      end

      def round_half(units, up_at_half)
        floor = units.floor
        fraction = units - floor
        if units >= 0
          fraction >= Rational(1, 2) ? floor + up_at_half : floor
        elsif fraction >= Rational(1, 2)
          floor - (1 - up_at_half)
        else
          floor + 1
        end
      end

      def round_half_even(units)
        floor = units.floor
        fraction = units - floor
        if units >= 0
          return floor if fraction < Rational(1, 2)
          return floor if fraction == Rational(1, 2) && floor.even?

          floor + 1
        else
          ceil = floor + 1
          distance = 1 - fraction
          return ceil if distance < Rational(1, 2)
          return ceil if distance == Rational(1, 2) && ceil.even?

          floor
        end
      end

      def rules_by_from
        @rules_by_from ||= rules.group_by(&:from_currency)
      end

      def adjacency
        @adjacency ||= rules.group_by(&:from_currency)
      end

      def nodes
        rules.flat_map { |rule| [rule.from_currency, rule.to_currency] }.uniq
      end

      def wrap_currency(currency)
        return if currency.nil?

        Money::Currency.wrap(currency)
      rescue Money::Currency::UnknownCurrency => error
        raise InvalidRule, error.message
      end

      def code_from(currency)
        if currency.respond_to?(:id)
          currency.id.to_s
        else
          currency.to_s.downcase
        end
      end

      def parse_optional_date(value)
        return if value.nil?

        parse_date(value)
      end

      def parse_date(value)
        case value
        when Date
          value
        when Time, DateTime
          value.to_date
        when String
          Date.iso8601(value)
        else
          raise ArgumentError, "expected a date, got #{value.class}"
        end
      end
    end
  end
end
