# frozen_string_literal: true

require "money/bank/base"

class Money
  module Bank
    # Finds the conversion route that delivers the largest amount through a
    # caller-provided graph of exchange quotes, honoring per-edge fixed fees,
    # per-hop cash rounding and a maximum number of hops.
    #
    # Each quote is a directed edge: it converts an amount of +from+ currency
    # into +to+ currency at +rate+, then charges a fixed +fee+ expressed in
    # minor units of the +to+ currency. Every hop rounds the converted amount
    # to whole minor units before the fee is deducted, and a hop whose
    # resulting balance would become negative cannot be taken.
    #
    # Because fees and rounding are applied at every hop, the route with the
    # highest product of rates is not necessarily the route that pays out the
    # most. The solver therefore dynamic-programs over (hops used, currency)
    # states instead of greedily maximizing the rate product: states that
    # arrive at the same currency with different hop counts are kept
    # separately, since a smaller balance with more remaining hops may still
    # win. Routes may revisit currencies, bounded only by +max_hops+.
    #
    # Ties are broken deterministically: a route that delivers more wins,
    # then the route with fewer hops, then the lexicographically smaller
    # sequence of currency ISO codes.
    #
    # Quotes are normalized once at the start of a solve, so a single solve
    # always works on a fixed set of quotes; pass a new set of quotes to
    # replan.
    #
    # @example
    #   quotes = [
    #     Money::Bank::Routing::Quote.new("USD", "EUR", 0.9, fee: 50),
    #     { from: "USD", to: "GBP", rate: 0.8, fee: 0 },
    #     { from: "GBP", to: "EUR", rate: 1.15, fee: 10 },
    #   ]
    #   route = Money::Bank::Routing.best_route(Money.new(100_00, "USD"), "EUR", quotes: quotes, max_hops: 2)
    #   route.amount      #=> #<Money fractional:... currency:EUR>
    #   route.currencies  #=> [#<Currency USD>, #<Currency GBP>, #<Currency EUR>]
    module Routing
      # A single directed conversion offer in a quote graph.
      class Quote
        # @return [Money::Currency] currency the quote converts from.
        attr_reader :from

        # @return [Money::Currency] currency the quote converts to.
        attr_reader :to

        # @return [BigDecimal] multiplier applied to the +from+ amount.
        attr_reader :rate

        # @return [BigDecimal] fixed fee in minor units of the +to+ currency,
        #   deducted after conversion and rounding.
        attr_reader :fee

        # @param [Money::Currency, String, Symbol] from Currency to convert from.
        # @param [Money::Currency, String, Symbol] to Currency to convert to.
        # @param [Numeric] rate Exchange rate applied to the +from+ amount.
        # @param [Numeric] fee Fixed fee in minor units of the +to+ currency.
        def initialize(from, to, rate, fee: 0)
          @from = Currency.wrap(from)
          @to = Currency.wrap(to)
          @rate = Routing.to_bigdecimal(rate)
          @fee = Routing.to_bigdecimal(fee)
        end

        def ==(other)
          other.is_a?(Quote) && from == other.from && to == other.to &&
            rate == other.rate && fee == other.fee
        end
      end

      # One conversion step of a solved +Route+.
      class Hop
        # @return [Money::Bank::Routing::Quote] the quote that was used.
        attr_reader :quote

        # @return [Money] balance before the hop, in the +from+ currency.
        attr_reader :amount_before

        # @return [Money] balance after conversion, rounding and the fee, in
        #   the +to+ currency.
        attr_reader :amount_after

        def initialize(quote:, amount_before:, amount_after:)
          @quote = quote
          @amount_before = amount_before
          @amount_after = amount_after
        end

        # @return [Money::Currency]
        def from_currency
          quote.from
        end

        # @return [Money::Currency]
        def to_currency
          quote.to
        end

        # @return [BigDecimal]
        def rate
          quote.rate
        end

        # @return [BigDecimal] fee charged by this hop, in minor units of the
        #   +to+ currency.
        def fee
          quote.fee
        end

        def ==(other)
          other.is_a?(Hop) && quote == other.quote &&
            amount_before == other.amount_before && amount_after == other.amount_after
        end
      end

      # The winning sequence of hops found by +Routing.best_route+.
      class Route
        # @return [Array<Money::Bank::Routing::Hop>] ordered hops; empty when
        #   the source and target currencies are the same.
        attr_reader :hops

        # @return [Money] final amount in the target currency.
        attr_reader :amount

        def initialize(hops:, amount:)
          @hops = hops.freeze
          @amount = amount
        end

        # @return [Array<Money::Currency>] currencies visited by the route,
        #   starting with the source currency.
        def currencies
          return [amount.currency] if hops.empty?

          [hops.first.from_currency, *hops.map(&:to_currency)]
        end

        def ==(other)
          other.is_a?(Route) && hops == other.hops && amount == other.amount
        end
      end

      class << self
        # Finds the route through +quotes+ that delivers the largest amount
        # of +to_currency+ for the given +Money+ object, using at most
        # +max_hops+ conversions.
        #
        # @param [Money] from The amount to route.
        # @param [Money::Currency, String, Symbol] to_currency The currency to
        #   receive.
        # @param [Array<Money::Bank::Routing::Quote, Hash>] quotes The quote
        #   graph. Hashes must provide +:from+, +:to+ and +:rate+ keys and may
        #   provide a +:fee+ key (default 0, minor units of the +to+ currency).
        # @param [Integer] max_hops Maximum number of conversions allowed.
        # @param [Proc, nil] rounding Optional callable applied to the
        #   converted amount at every hop before the fee is deducted. Defaults
        #   to rounding half up to whole minor units.
        #
        # @return [Money::Bank::Routing::Route]
        #
        # @raise [ArgumentError] if +max_hops+ is negative.
        # @raise [Money::Bank::UnknownRate] if no valid route exists.
        def best_route(from, to_currency, quotes:, max_hops:, rounding: nil)
          to_currency = Currency.wrap(to_currency)
          unless max_hops.is_a?(Integer) && max_hops >= 0
            raise ArgumentError, "max_hops must be a non-negative Integer"
          end

          edges = quotes.map { |quote| normalize_quote(quote) }.group_by { |quote| quote.from.iso_code }
          rounding ||= ->(n) { n.round(0, :half_up) }

          amount, path = solve(to_bigdecimal(from.fractional), from.currency, to_currency, edges, max_hops, rounding)
          build_route(from, to_currency, amount, path)
        end

        # @private
        def to_bigdecimal(number)
          number.is_a?(BigDecimal) ? number : BigDecimal(number.to_s)
        end

        private

        def normalize_quote(quote)
          case quote
          when Quote
            quote
          when Hash
            Quote.new(quote.fetch(:from), quote.fetch(:to), quote.fetch(:rate), fee: quote.fetch(:fee, 0))
          else
            raise ArgumentError, "quotes must be Money::Bank::Routing::Quote objects or Hashes, got #{quote.inspect}"
          end
        end

        # Dynamic programming over (hops used, currency) states. For each
        # state only the largest balance is kept: with the hop count fixed,
        # a larger balance can always follow the same remaining edges to an
        # at-least-as-good outcome, while states with different hop counts
        # are never merged.
        def solve(start_amount, from_currency, to_currency, edges, max_hops, rounding)
          best = Array.new(max_hops + 1) { {} }
          best[0][from_currency.iso_code] = [start_amount, []]

          max_hops.times do |hops|
            best[hops].each do |iso_code, (amount, path)|
              edges.fetch(iso_code, []).each do |quote|
                after = to_bigdecimal(rounding.call(amount * quote.rate)) - quote.fee
                next if after.negative?

                update_state(best[hops + 1], quote.to.iso_code, after, path + [[quote, amount, after]], from_currency)
              end
            end
          end

          select_winner(best, to_currency, from_currency)
        end

        def update_state(states, iso_code, amount, path, from_currency)
          current = states[iso_code]
          if current.nil? || amount > current.first ||
              (amount == current.first && lexicographically_smaller?(currency_sequence(path, from_currency), currency_sequence(current.last, from_currency)))
            states[iso_code] = [amount, path]
          end
        end

        def select_winner(best, to_currency, from_currency)
          winner = nil
          best.each_with_index do |states, hops|
            state = states[to_currency.iso_code]
            next unless state

            if winner.nil? || state.first > winner.first ||
                (state.first == winner.first && hops < winner_hops(winner)) ||
                (state.first == winner.first && hops == winner_hops(winner) &&
                  lexicographically_smaller?(currency_sequence(state.last, from_currency), currency_sequence(winner.last, from_currency)))
              winner = state
            end
          end

          if winner.nil?
            raise UnknownRate, "No conversion route found within the given quotes and max_hops"
          end

          winner
        end

        def winner_hops(winner)
          winner.last.length
        end

        def currency_sequence(path, from_currency)
          [from_currency.iso_code, *path.map { |quote, _before, _after| quote.to.iso_code }]
        end

        def lexicographically_smaller?(sequence, other)
          (sequence <=> other) == -1
        end

        def build_route(from, to_currency, amount, path)
          hops = path.map do |quote, before, after|
            Hop.new(
              quote: quote,
              amount_before: from.dup_with(fractional: before, currency: quote.from),
              amount_after: from.dup_with(fractional: after, currency: quote.to),
            )
          end
          Route.new(hops: hops, amount: from.dup_with(fractional: amount, currency: to_currency))
        end
      end
    end
  end
end
