# frozen_string_literal: true

class Money
  # Finds the route through a caller-supplied directed quote network that
  # maximizes the amount actually received when converting from one currency
  # to another, optionally transiting through intermediate currencies.
  #
  # Every edge of the network quotes a rate together with a fixed fee, a
  # proportional fee and a minimum tradeable amount. Each leg of a route is
  # settled independently: fees are deducted and the proceeds are rounded to
  # the subunit agreed on the edge before the next leg is quoted. Rates are
  # never multiplied together first with fees applied only at the end.
  #
  # Edges that are expired or whose minimum tradeable amount is not met are
  # unusable, and a route never visits the same currency twice. Routes that
  # receive the same amount are ordered by fewer hops first and then by the
  # stable order in which edges were added to the network.
  #
  # The quoter is read-only: it never assigns +Money.default_bank+ or any
  # other global state.
  #
  # @example
  #   network = Money::RouteQuoter::Network.new
  #   network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)
  #   network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8, fixed_fee: 5_00)
  #   network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.18, fixed_fee: 3_00)
  #
  #   quote = Money::RouteQuoter.new(network).quote(
  #     from: "USD",
  #     to: "EUR",
  #     amount: Money.new(100_00, "USD"),
  #     max_hops: 2,
  #   )
  #   quote.received #=> #<Money fractional:9000 currency:EUR>
  class RouteQuoter
    # A single directed quote offered between two currencies.
    #
    # Fees are charged in the source currency of the edge: the fixed fee is
    # deducted from the incoming amount first, then the proportional fee is
    # charged on the remainder. The remaining net amount is converted at the
    # quoted rate and rounded to the subunit the edge settles in.
    class Edge
      # @return [Money::Currency] Currency the edge converts from.
      attr_reader :from_currency

      # @return [Money::Currency] Currency the edge converts to.
      attr_reader :to_currency

      # @return [BigDecimal] Rate in +to_currency+ main units per
      #   +from_currency+ main unit.
      attr_reader :rate

      # @return [Integer] Fixed fee in +from_currency+ fractional units,
      #   deducted before conversion.
      attr_reader :fixed_fee

      # @return [BigDecimal] Proportional fee as a fraction of the amount
      #   remaining after the fixed fee, in +from_currency+.
      attr_reader :proportional_fee

      # @return [Integer] Minimum tradeable amount in +from_currency+
      #   fractional units. Amounts below this make the edge unusable.
      attr_reader :min_amount

      # @return [Time, nil] Time after which the quote is no longer usable.
      attr_reader :expires_at

      # @return [Integer] Subunit per main unit the edge settles in. The
      #   converted amount of each leg is rounded to this precision. Must
      #   divide the +to_currency+ subunit. Defaults to the +to_currency+
      #   subunit.
      attr_reader :subunit_to_unit

      # @return [Integer] BigDecimal rounding mode used when settling a leg.
      attr_reader :rounding_mode

      # @return [Integer, nil] Stable order assigned by the network when the
      #   edge was added.
      attr_reader :position

      def initialize(from_currency:, to_currency:, rate:, fixed_fee: 0, proportional_fee: 0,
                     min_amount: 0, expires_at: nil, subunit_to_unit: nil,
                     rounding_mode: BigDecimal::ROUND_HALF_UP, position: nil)
        @from_currency = Currency.wrap(from_currency)
        @to_currency = Currency.wrap(to_currency)
        @rate = BigDecimal(rate.to_s)
        @fixed_fee = Integer(fixed_fee)
        @proportional_fee = BigDecimal(proportional_fee.to_s)
        @min_amount = Integer(min_amount)
        @expires_at = expires_at
        @subunit_to_unit = subunit_to_unit.nil? ? @to_currency.subunit_to_unit : Integer(subunit_to_unit)
        @rounding_mode = rounding_mode
        @position = position

        raise ArgumentError, "rate must be positive" unless @rate.positive?
        raise ArgumentError, "fixed_fee must be non-negative" if @fixed_fee.negative?
        raise ArgumentError, "min_amount must be non-negative" if @min_amount.negative?
        raise ArgumentError, "subunit_to_unit must be positive" unless @subunit_to_unit.positive?

        if @proportional_fee.negative? || @proportional_fee >= 1
          raise ArgumentError, "proportional_fee must be within [0, 1)"
        end

        unless (@to_currency.subunit_to_unit % @subunit_to_unit).zero?
          raise ArgumentError, "subunit_to_unit must divide the subunit of to_currency"
        end
      end

      # Whether the quote is no longer usable at the given time.
      #
      # @param [Time] at
      #
      # @return [Boolean]
      def expired?(at)
        !expires_at.nil? && expires_at <= at
      end

      # Number of +to_currency+ fractional units per subunit this edge
      # settles in.
      #
      # @return [Integer]
      def fractional_per_subunit
        to_currency.subunit_to_unit / subunit_to_unit
      end
    end

    # A directed quote network. Edges are kept in the order they are added,
    # which defines the stable edge order used to break ties between routes
    # that receive the same amount in the same number of hops.
    class Network
      include Enumerable

      def initialize
        @edges = []
      end

      # Adds an edge to the network and returns it. See
      # +Money::RouteQuoter::Edge#initialize+ for the available options.
      #
      # @return [Money::RouteQuoter::Edge]
      def add_edge(from_currency:, to_currency:, **options)
        edge = Edge.new(
          from_currency: from_currency,
          to_currency: to_currency,
          position: @edges.length,
          **options,
        )
        @edges << edge
        edge
      end

      def each(&)
        @edges.each(&)
      end

      # All edges converting from the given currency, in the order they were
      # added to the network.
      #
      # @param [Money::Currency, String, Symbol] currency
      #
      # @return [Array<Money::RouteQuoter::Edge>]
      def edges_from(currency)
        wrapped = Currency.wrap(currency)
        @edges.select { |edge| edge.from_currency == wrapped }
      end
    end

    # One settled hop of a quoted route. Keeps the incoming amount, the
    # charged fees and the rounded amount credited by the leg.
    class Leg
      # @return [Money::RouteQuoter::Edge] The edge that was settled.
      attr_reader :edge

      # @return [Money] Amount entering the leg.
      attr_reader :amount_in

      # @return [Money] Fixed fee charged by the leg.
      attr_reader :fixed_fee

      # @return [Money] Proportional fee charged by the leg.
      attr_reader :proportional_fee

      # @return [Money] Amount converted after fees.
      attr_reader :net

      # @return [Money] Rounded amount credited by the leg.
      attr_reader :amount_out

      def initialize(edge:, amount_in:, fixed_fee:, proportional_fee:, net:, amount_out:)
        @edge = edge
        @amount_in = amount_in
        @fixed_fee = fixed_fee
        @proportional_fee = proportional_fee
        @net = net
        @amount_out = amount_out
      end

      def from_currency
        edge.from_currency
      end

      def to_currency
        edge.to_currency
      end
    end

    # The result of quoting a route.
    class Quote
      # @return [Money] The amount that was offered for conversion.
      attr_reader :amount

      # @return [Money::Currency] The currency to convert to.
      attr_reader :to_currency

      # @return [Array<Money::RouteQuoter::Leg>, nil] The settled legs of the
      #   best route, or +nil+ when no feasible route exists.
      attr_reader :legs

      # @return [Symbol, nil] Why no feasible route exists (+:no_route+).
      attr_reader :reason

      def self.infeasible(amount:, to_currency:, reason:)
        new(amount: amount, to_currency: to_currency, legs: nil, reason: reason)
      end

      def initialize(amount:, to_currency:, legs:, reason: nil)
        @amount = amount
        @to_currency = Currency.wrap(to_currency)
        @legs = legs&.freeze
        @reason = reason
      end

      # Whether a feasible route was found.
      #
      # @return [Boolean]
      def feasible?
        !legs.nil?
      end

      # Number of edges the route settles through.
      #
      # @return [Integer]
      def hops
        feasible? ? legs.length : 0
      end

      # The amount actually received, or +nil+ when no feasible route
      # exists.
      #
      # @return [Money, nil]
      def received
        return nil unless feasible?

        legs.empty? ? amount : legs.last.amount_out
      end
    end

    def initialize(network)
      @network = network
    end

    # Finds the route that maximizes the amount actually received when
    # converting +amount+ from +from+ to +to+ within +max_hops+ edges.
    #
    # @param [Money::Currency, String, Symbol] from Currency to convert from.
    # @param [Money::Currency, String, Symbol] to Currency to convert to.
    # @param [Money] amount Amount to convert, denominated in +from+.
    # @param [Integer] max_hops Maximum number of edges a route may settle
    #   through.
    # @param [Time] at Time at which edge expiry is evaluated.
    #
    # @return [Money::RouteQuoter::Quote]
    def quote(from:, to:, amount:, max_hops: 3, at: Time.now)
      from_currency = Currency.wrap(from)
      to_currency = Currency.wrap(to)

      raise ArgumentError, "max_hops must be non-negative" if max_hops.negative?

      unless amount.currency == from_currency
        raise ArgumentError, "amount must be denominated in the from currency"
      end

      if from_currency == to_currency
        return Quote.new(amount: amount, to_currency: to_currency, legs: [])
      end

      routes = []
      collect_routes(from_currency, to_currency, amount, max_hops, at, [from_currency], [], routes)

      if routes.empty?
        return Quote.infeasible(amount: amount, to_currency: to_currency, reason: :no_route)
      end

      Quote.new(amount: amount, to_currency: to_currency, legs: routes.min_by { |legs| route_key(legs) })
    end

    # Settles a single edge for the given amount. Returns +nil+ when the
    # edge cannot be traded: the amount is below the minimum tradeable
    # amount, or the fixed fee consumes it entirely.
    #
    # @param [Money::RouteQuoter::Edge] edge
    # @param [Money] amount Amount entering the leg, denominated in the
    #   edge's +from_currency+.
    #
    # @return [Money::RouteQuoter::Leg, nil]
    def quote_leg(edge, amount)
      fractional = amount.fractional
      return nil if fractional < edge.min_amount

      after_fixed = fractional - edge.fixed_fee
      return nil unless after_fixed.positive?

      rounding_mode = edge.rounding_mode
      proportional = (BigDecimal(after_fixed.to_s) * edge.proportional_fee).round(0, rounding_mode)
      net = after_fixed - proportional

      raw = BigDecimal(net.to_s) /
            BigDecimal(edge.from_currency.subunit_to_unit.to_s) *
            edge.rate * edge.subunit_to_unit
      received = raw.round(0, rounding_mode) * edge.fractional_per_subunit

      Leg.new(
        edge: edge,
        amount_in: amount,
        fixed_fee: Money.new(edge.fixed_fee, edge.from_currency),
        proportional_fee: Money.new(proportional, edge.from_currency),
        net: Money.new(net, edge.from_currency),
        amount_out: Money.new(received, edge.to_currency),
      )
    end

    private

    def collect_routes(from_currency, to_currency, amount, max_hops, at, visited, legs, routes)
      @network.edges_from(from_currency).each do |edge|
        next if edge.expired?(at)
        next if visited.include?(edge.to_currency)

        leg = quote_leg(edge, amount)
        next if leg.nil?

        new_legs = legs + [leg]
        if edge.to_currency == to_currency
          routes << new_legs
        elsif new_legs.length < max_hops
          collect_routes(edge.to_currency, to_currency, leg.amount_out, max_hops, at,
                         visited + [edge.to_currency], new_legs, routes)
        end
      end
    end

    def route_key(legs)
      [-legs.last.amount_out.fractional, legs.length, legs.map { |leg| leg.edge.position }]
    end
  end
end
