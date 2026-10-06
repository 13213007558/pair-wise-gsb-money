# frozen_string_literal: true

RSpec.describe Money::RouteQuoter do
  def build_network
    Money::RouteQuoter::Network.new
  end

  def quote(network, from:, to:, amount:, max_hops: 3, at: Time.now)
    described_class.new(network).quote(from: from, to: to, amount: amount, max_hops: max_hops, at: at)
  end

  describe Money::RouteQuoter::Edge do
    it "rejects invalid attributes" do
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 0) }
        .to raise_error(ArgumentError, /rate/)
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, fixed_fee: -1) }
        .to raise_error(ArgumentError, /fixed_fee/)
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, proportional_fee: 1) }
        .to raise_error(ArgumentError, /proportional_fee/)
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, proportional_fee: -0.1) }
        .to raise_error(ArgumentError, /proportional_fee/)
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, min_amount: -1) }
        .to raise_error(ArgumentError, /min_amount/)
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, subunit_to_unit: 0) }
        .to raise_error(ArgumentError, /subunit_to_unit/)
    end

    it "rejects a subunit that does not divide the target currency subunit" do
      expect { described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, subunit_to_unit: 3) }
        .to raise_error(ArgumentError, /subunit_to_unit/)
    end

    it "defaults the settlement subunit to the target currency subunit" do
      edge = described_class.new(from_currency: "USD", to_currency: "JPY", rate: 150)
      expect(edge.subunit_to_unit).to eq(1)
      expect(edge.fractional_per_subunit).to eq(1)
    end

    it "knows when it is expired" do
      now = Time.now
      edge = described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1, expires_at: now)
      expect(edge.expired?(now - 1)).to be(false)
      expect(edge.expired?(now)).to be(true)
      expect(edge.expired?(now + 1)).to be(true)

      timeless = described_class.new(from_currency: "USD", to_currency: "EUR", rate: 1)
      expect(timeless.expired?(now)).to be(false)
    end
  end

  describe "#quote_leg" do
    it "deducts the fixed fee, then the proportional fee, then converts and rounds" do
      network = build_network
      edge = network.add_edge(
        from_currency: "USD",
        to_currency: "EUR",
        rate: 0.9,
        fixed_fee: 5_00,
        proportional_fee: 0.1,
      )

      leg = described_class.new(network).quote_leg(edge, Money.new(100_00, "USD"))

      expect(leg.amount_in).to eq(Money.new(100_00, "USD"))
      expect(leg.fixed_fee).to eq(Money.new(5_00, "USD"))
      expect(leg.proportional_fee).to eq(Money.new(9_50, "USD"))
      expect(leg.net).to eq(Money.new(85_50, "USD"))
      expect(leg.amount_out).to eq(Money.new(76_95, "EUR"))
    end

    it "rounds each leg to the subunit agreed on the edge" do
      network = build_network
      edge = network.add_edge(from_currency: "GBP", to_currency: "USD", rate: 1.2504, subunit_to_unit: 1)

      leg = described_class.new(network).quote_leg(edge, Money.new(10_00, "GBP"))

      expect(leg.amount_out).to eq(Money.new(13_00, "USD"))
    end

    it "returns nil when the amount is below the minimum tradeable amount" do
      network = build_network
      edge = network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9, min_amount: 200_00)

      expect(described_class.new(network).quote_leg(edge, Money.new(100_00, "USD"))).to be_nil
      expect(described_class.new(network).quote_leg(edge, Money.new(200_00, "USD"))).not_to be_nil
    end

    it "returns nil when the fixed fee consumes the whole amount" do
      network = build_network
      edge = network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9, fixed_fee: 100_00)

      expect(described_class.new(network).quote_leg(edge, Money.new(100_00, "USD"))).to be_nil
    end
  end

  describe "#quote" do
    it "picks the route with the worse rate product when fixed fees make the better product worse" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8, fixed_fee: 5_00)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.18, fixed_fee: 3_00)

      # The transit route has the better rate product (0.8 * 1.18 = 0.944 > 0.9),
      # but after the fixed fees it only pays out 86_14 instead of 90_00.
      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(result).to be_feasible
      expect(result.hops).to eq(1)
      expect(result.received).to eq(Money.new(90_00, "EUR"))
      expect(result.legs.map { |leg| leg.to_currency.iso_code }).to eq(["EUR"])
    end

    it "rounds and charges fees per leg instead of multiplying rates first" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "JPY", rate: 150.5)
      network.add_edge(from_currency: "JPY", to_currency: "GBP", rate: 0.0053)

      # Per leg: 1.99 USD -> 299.495 -> 299 JPY -> 1.5847 GBP -> 158 pence.
      # Multiplying rates first would give 1.5872635 GBP -> 159 pence.
      result = quote(network, from: "USD", to: "GBP", amount: Money.new(1_99, "USD"), max_hops: 2)

      expect(result.legs[0].amount_out).to eq(Money.new(299, "JPY"))
      expect(result.legs[1].amount_out).to eq(Money.new(158, "GBP"))
      expect(result.received).to eq(Money.new(158, "GBP"))
    end

    it "charges the proportional fee on every leg" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "CAD", rate: 1.0, proportional_fee: 0.1)
      network.add_edge(from_currency: "CAD", to_currency: "EUR", rate: 1.0, proportional_fee: 0.1)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(result.legs[0].proportional_fee).to eq(Money.new(10_00, "USD"))
      expect(result.legs[0].amount_out).to eq(Money.new(90_00, "CAD"))
      expect(result.legs[1].proportional_fee).to eq(Money.new(9_00, "CAD"))
      expect(result.received).to eq(Money.new(81_00, "EUR"))
    end

    it "ignores edges whose minimum tradeable amount is not met" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9, min_amount: 200_00)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.0)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(result.hops).to eq(2)
      expect(result.received).to eq(Money.new(80_00, "EUR"))
    end

    it "ignores expired edges and evaluates expiry at the given time" do
      now = Time.now
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9, expires_at: now - 60)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.0)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2, at: now)
      expect(result.hops).to eq(2)
      expect(result.received).to eq(Money.new(80_00, "EUR"))

      earlier = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2, at: now - 120)
      expect(earlier.hops).to eq(1)
      expect(earlier.received).to eq(Money.new(90_00, "EUR"))
    end

    it "never visits the same currency twice, even around a profitable cycle" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)
      network.add_edge(from_currency: "EUR", to_currency: "USD", rate: 1.2)
      network.add_edge(from_currency: "EUR", to_currency: "GBP", rate: 0.85)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)

      result = quote(network, from: "USD", to: "GBP", amount: Money.new(100_00, "USD"), max_hops: 5)

      currencies = [result.legs.first.from_currency] + result.legs.map(&:to_currency)
      expect(currencies.uniq.length).to eq(currencies.length)
      expect(result.received).to eq(Money.new(80_00, "GBP"))
    end

    it "prefers fewer hops when routes receive the same amount" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.125)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(result.received).to eq(Money.new(90_00, "EUR"))
      expect(result.hops).to eq(1)
    end

    it "prefers the stable edge order when routes tie on amount and hops" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "CAD", rate: 0.9)
      network.add_edge(from_currency: "CAD", to_currency: "EUR", rate: 1.0)
      network.add_edge(from_currency: "USD", to_currency: "AUD", rate: 0.9)
      network.add_edge(from_currency: "AUD", to_currency: "EUR", rate: 1.0)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(result.received).to eq(Money.new(90_00, "EUR"))
      expect(result.legs.map { |leg| leg.to_currency.iso_code }).to eq(["CAD", "EUR"])
    end

    it "respects max_hops" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "CAD", rate: 1.0)
      network.add_edge(from_currency: "CAD", to_currency: "GBP", rate: 1.0)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.0)

      expect(quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2))
        .not_to be_feasible

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 3)
      expect(result).to be_feasible
      expect(result.hops).to eq(3)
      expect(result.received).to eq(Money.new(100_00, "EUR"))
    end

    it "returns a clear result when no feasible route exists" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"))

      expect(result).not_to be_feasible
      expect(result.reason).to eq(:no_route)
      expect(result.received).to be_nil
      expect(result.legs).to be_nil
      expect(result.hops).to eq(0)
    end

    it "returns a clear result when every route is blocked by fees or thresholds" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9, fixed_fee: 100_00)

      result = quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"))

      expect(result).not_to be_feasible
      expect(result.reason).to eq(:no_route)
    end

    it "treats converting a currency to itself as a zero-hop route" do
      amount = Money.new(100_00, "USD")
      result = quote(build_network, from: "USD", to: "USD", amount: amount)

      expect(result).to be_feasible
      expect(result.hops).to eq(0)
      expect(result.legs).to eq([])
      expect(result.received).to eq(amount)
    end

    it "validates its arguments" do
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)

      expect { quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "GBP")) }
        .to raise_error(ArgumentError, /from currency/)
      expect { quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: -1) }
        .to raise_error(ArgumentError, /max_hops/)
    end

    it "does not modify Money.default_bank" do
      bank_before = Money.default_bank
      network = build_network
      network.add_edge(from_currency: "USD", to_currency: "EUR", rate: 0.9)
      network.add_edge(from_currency: "USD", to_currency: "GBP", rate: 0.8)
      network.add_edge(from_currency: "GBP", to_currency: "EUR", rate: 1.1)

      quote(network, from: "USD", to: "EUR", amount: Money.new(100_00, "USD"), max_hops: 2)

      expect(Money.default_bank).to equal(bank_before)
    end
  end

  describe "exhaustive comparison" do
    # Independently enumerates every legal path and picks the best one using
    # the documented ordering: most received, then fewest hops, then stable
    # edge order.
    def enumerate_best_legs(network, from:, to:, amount:, max_hops:, at:)
      quoter = described_class.new(network)
      adjacency = network.each.group_by(&:from_currency)
      best = nil
      stack = [[from, amount, [], [from]]]
      until stack.empty?
        currency, current, legs, visited = stack.pop
        adjacency.fetch(currency, []).each do |edge|
          next if edge.expired?(at)
          next if visited.include?(edge.to_currency)

          leg = quoter.quote_leg(edge, current)
          next if leg.nil?

          new_legs = legs + [leg]
          if edge.to_currency == to
            key = [-new_legs.last.amount_out.fractional, new_legs.length, new_legs.map { |l| l.edge.position }]
            best = [key, new_legs] if best.nil? || (key <=> best[0]) < 0
          elsif new_legs.length < max_hops
            stack.push([edge.to_currency, leg.amount_out, new_legs, visited + [edge.to_currency]])
          end
        end
      end
      best && best[1]
    end

    it "matches an independent enumeration of every legal path" do
      currencies = ["USD", "EUR", "GBP", "JPY", "CAD"]
      [7, 23, 42, 99, 1234].each do |seed|
        random = Random.new(seed)
        now = Time.now
        network = build_network
        currencies.permutation(2) do |from, to|
          next unless random.rand < 0.45

          network.add_edge(
            from_currency: from,
            to_currency: to,
            rate: (random.rand * 1.5 + 0.5).round(4),
            fixed_fee: random.rand(0..4) * 100,
            proportional_fee: [0, 0.005, 0.02].sample(random: random),
            min_amount: [0, 100, 5000].sample(random: random),
            expires_at: [nil, now - 3600, now + 3600].sample(random: random),
          )
        end

        amount = Money.new(100_00, "USD")
        expected_legs = enumerate_best_legs(
          network,
          from: Money::Currency.new("USD"),
          to: Money::Currency.new("EUR"),
          amount: amount,
          max_hops: 3,
          at: now,
        )
        result = quote(network, from: "USD", to: "EUR", amount: amount, max_hops: 3, at: now)

        if expected_legs.nil?
          expect(result).not_to be_feasible
        else
          expect(result).to be_feasible
          expect(result.received).to eq(expected_legs.last.amount_out)
          expect(result.legs.map { |leg| leg.edge.position })
            .to eq(expected_legs.map { |leg| leg.edge.position })
        end
      end
    end
  end
end
