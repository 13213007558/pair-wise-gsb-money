# frozen_string_literal: true

class Money
  # Finds the best directed currency-conversion route while charging and
  # rounding every edge independently.
  class RouteQuoter
    # A tradable directed quote.
    class Edge
      FROM_KEYS = [:from_currency, :from, :source_currency, :source].freeze
      TO_KEYS = [:to_currency, :to, :target_currency, :target].freeze
      RATE_KEYS = [:exchange_rate, :rate].freeze
      FIXED_FEE_KEYS = [:fixed_fee, :fee_fixed].freeze
      PROPORTIONAL_FEE_KEYS = [
        :proportional_fee,
        :percentage_fee,
        :percent_fee,
        :fee_rate,
      ].freeze
      MINIMUM_KEYS = [
        :minimum_amount,
        :minimum_trade_amount,
        :min_amount,
      ].freeze
      EXPIRES_KEYS = [:expires_at, :expiration, :expiry].freeze

      attr_reader :from_currency, :to_currency, :rate, :fixed_fee,
                  :proportional_fee, :minimum_amount, :expires_at, :ordinal

      def self.wrap(edge, ordinal)
        return edge.with_ordinal(ordinal) if edge.is_a?(Edge)

        new(
          from_currency: fetch_value(edge, FROM_KEYS),
          to_currency: fetch_value(edge, TO_KEYS),
          rate: fetch_value(edge, RATE_KEYS),
          fixed_fee: fetch_value(edge, FIXED_FEE_KEYS, 0),
          proportional_fee: fetch_value(edge, PROPORTIONAL_FEE_KEYS, 0),
          minimum_amount: fetch_value(edge, MINIMUM_KEYS, 0),
          expires_at: fetch_value(edge, EXPIRES_KEYS),
          ordinal: ordinal,
        )
      end

      def self.fetch_value(edge, keys, default = nil)
        keys.each do |key|
          if edge.respond_to?(:key?) && (edge.key?(key) || edge.key?(key.to_s))
            return edge.key?(key) ? edge[key] : edge[key.to_s]
          elsif edge.respond_to?(key)
            return edge.public_send(key)
          end
        end
        default
      end

      def initialize(from_currency:, to_currency:, rate:, fixed_fee: 0,
                     proportional_fee: 0, minimum_amount: 0, expires_at: nil,
                     ordinal: nil)
        @from_currency = Currency.wrap(from_currency)
        @to_currency = Currency.wrap(to_currency)
        @rate = BigDecimal(rate.to_s)
        @fixed_fee = source_money(fixed_fee)
        @proportional_fee = BigDecimal(proportional_fee.to_s)
        @minimum_amount = source_money(minimum_amount)
        @expires_at = expires_at
        @ordinal = ordinal

        validate!
      end

      def with_ordinal(new_ordinal)
        self.class.new(
          from_currency: from_currency,
          to_currency: to_currency,
          rate: rate,
          fixed_fee: fixed_fee,
          proportional_fee: proportional_fee,
          minimum_amount: minimum_amount,
          expires_at: expires_at,
          ordinal: new_ordinal,
        )
      end

      def available?(now = nil)
        expires_at.nil? || now.nil? || now < expires_at
      end

      def quote(amount, now: nil, rounding_mode: Money.rounding_mode)
        return unless available?(now)
        return unless amount.currency == from_currency
        return unless amount.fractional >= minimum_amount.fractional

        proportional_fee_amount = Money.new(
          round_fractional(amount.fractional * proportional_fee, rounding_mode),
          from_currency,
          amount.bank,
        )
        total_fee = fixed_fee + proportional_fee_amount
        net_input_amount = amount - total_fee
        return unless net_input_amount.positive?

        destination_subunits = BigDecimal(to_currency.subunit_to_unit.to_s)
        source_subunits = BigDecimal(from_currency.subunit_to_unit.to_s)
        raw_received_fractional =
          BigDecimal(net_input_amount.fractional.to_s) *
          rate * destination_subunits / source_subunits
        received_amount = Money.new(
          raw_received_fractional.round(0, rounding_mode).to_i,
          to_currency,
          amount.bank,
        )
        return unless received_amount.positive?

        Step.new(
          edge: self,
          input_amount: amount,
          fixed_fee: fixed_fee,
          proportional_fee: proportional_fee_amount,
          total_fee: total_fee,
          net_input_amount: net_input_amount,
          raw_received_fractional: raw_received_fractional,
          received_amount: received_amount,
        )
      end

      private

      def validate!
        raise ArgumentError, "rate must be positive" unless rate.positive? && rate.finite?

        unless proportional_fee >= 0 && proportional_fee <= 1 && proportional_fee.finite?
          raise ArgumentError, "proportional fee must be between 0 and 1"
        end

        unless fixed_fee.fractional >= 0 && minimum_amount.fractional >= 0
          raise ArgumentError, "fixed fee and minimum amount cannot be negative"
        end
      end

      def source_money(value)
        if value.is_a?(Money)
          unless value.currency == from_currency
            raise ArgumentError, "money value must be #{from_currency}"
          end

          value
        else
          Money.new(value, from_currency)
        end
      end

      def round_fractional(value, rounding_mode)
        value.round(0, rounding_mode).to_i
      end
    end

    # The independently charged and rounded result of one edge.
    Step = Struct.new(
      :edge,
      :input_amount,
      :fixed_fee,
      :proportional_fee,
      :total_fee,
      :net_input_amount,
      :raw_received_fractional,
      :received_amount,
      keyword_init: true,
    )

    # A complete sequence of successful edge quotes.
    Route = Struct.new(:steps, :source_amount, keyword_init: true) do
      def received_amount
        steps.last&.received_amount || source_amount
      end

      def edges
        steps.map(&:edge)
      end

      def currencies
        return [source_amount.currency] if steps.empty?

        [steps.first.edge.from_currency, *steps.map { |step| step.edge.to_currency }]
      end

      def hops
        steps.length
      end

      def ordinal_path
        edges.map(&:ordinal)
      end
    end

    # The successful or unsuccessful result returned by a quote request.
    Result = Struct.new(:route, keyword_init: true) do
      def found?
        !route.nil?
      end

      alias success? found?
      alias successful? found?

      def received_amount
        route&.received_amount
      end

      def status
        route ? :found : :no_route
      end

      def message
        route ? "Route found" : "No viable route found within the maximum number of hops"
      end
    end

    def self.quote(amount, to_currency, network, max_hops:, now: Time.now,
                   rounding_mode: Money.rounding_mode)
      new(network).quote(
        amount,
        to_currency,
        max_hops: max_hops,
        now: now,
        rounding_mode: rounding_mode,
      )
    end

    def initialize(network)
      @edges = network.each_with_index.map { |edge, index| Edge.wrap(edge, index) }
      @adjacent = @edges.group_by(&:from_currency)
    end

    def quote(amount, to_currency, max_hops:, now: Time.now,
              rounding_mode: Money.rounding_mode)
      unless amount.is_a?(Money)
        raise ArgumentError, "amount must be a Money instance"
      end

      to_currency = Currency.wrap(to_currency)
      raise ArgumentError, "max_hops cannot be negative" if max_hops.negative?

      if amount.currency == to_currency
        return Result.new(route: Route.new(steps: [], source_amount: amount))
      end

      route = find_route(
        amount,
        to_currency,
        max_hops,
        now,
        rounding_mode,
        [amount.currency],
      )
      Result.new(route: route)
    end

    private

    def find_route(amount, target_currency, remaining_hops, now, rounding_mode, visited)
      return if remaining_hops.zero?

      best = nil
      edges_from(amount.currency).each do |edge|
        next if visited.include?(edge.to_currency)

        step = edge.quote(amount, now: now, rounding_mode: rounding_mode)
        next unless step

        route =
          if edge.to_currency == target_currency
            Route.new(steps: [step], source_amount: amount)
          else
            continuation = find_route(
              step.received_amount,
              target_currency,
              remaining_hops - 1,
              now,
              rounding_mode,
              visited + [edge.to_currency],
            )
            next unless continuation

            Route.new(
              steps: [step, *continuation.steps],
              source_amount: amount,
            )
          end

        best = route if preferred?(route, best)
      end
      best
    end

    def edges_from(currency)
      @adjacent.fetch(currency, []).sort_by(&:ordinal)
    end

    def preferred?(candidate, current)
      return true if current.nil?

      candidate_amount = candidate.received_amount.fractional
      current_amount = current.received_amount.fractional
      return true if candidate_amount > current_amount
      return false if candidate_amount < current_amount
      return true if candidate.hops < current.hops
      return false if candidate.hops > current.hops

      (candidate.ordinal_path <=> current.ordinal_path) == -1
    end
  end
end
