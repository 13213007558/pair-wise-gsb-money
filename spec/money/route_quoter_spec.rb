# frozen_string_literal: true

RSpec.describe Money::RouteQuoter do
  def edge(from, to, rate:, fixed_fee: 0, proportional_fee: 0,
           minimum_amount: 0, expires_at: nil)
    {
      from_currency: from,
      to_currency: to,
      rate: rate,
      fixed_fee: fixed_fee,
      proportional_fee: proportional_fee,
      minimum_amount: minimum_amount,
      expires_at: expires_at,
    }
  end

  def independently_quote(amount, edge, now:)
    return unless edge[:expires_at].nil? || now < edge[:expires_at]
    return unless amount.fractional >= edge[:minimum_amount]

    proportional_fee = Money.new(
      (amount.fractional * BigDecimal(edge[:proportional_fee].to_s)).round(
        0,
        Money.rounding_mode,
      ).to_i,
      amount.currency,
    )
    total_fee = Money.new(edge[:fixed_fee], amount.currency) + proportional_fee
    net_input = amount - total_fee
    return unless net_input.positive?

    target = Money::Currency.wrap(edge[:to_currency])
    source = Money::Currency.wrap(edge[:from_currency])
    raw_fractional =
      BigDecimal(net_input.fractional.to_s) *
      BigDecimal(edge[:rate].to_s) *
      BigDecimal(target.subunit_to_unit.to_s) /
      BigDecimal(source.subunit_to_unit.to_s)
    received = Money.new(raw_fractional.round(0, Money.rounding_mode).to_i, target)
    return unless received.positive?

    { received: received, fee: total_fee }
  end

  def enumerate_routes(network, amount, target, max_hops, now,
                       visited = [amount.currency])
    return [] if max_hops.zero?

    network.each_with_index.flat_map do |candidate_edge, edge_index|
      next [] unless candidate_edge[:from_currency] == amount.currency
      next [] if visited.include?(candidate_edge[:to_currency])

      quote = independently_quote(amount, candidate_edge, now: now)
      next [] unless quote

      if candidate_edge[:to_currency] == target
        [{ amount: quote[:received], hops: 1, indices: [edge_index] }]
      else
        continuations = enumerate_routes(
          network,
          quote[:received],
          target,
          max_hops - 1,
          now,
          visited + [candidate_edge[:to_currency]],
        )
        continuations.map do |continuation|
          {
            amount: continuation[:amount],
            hops: continuation[:hops] + 1,
            indices: [edge_index, *continuation[:indices]],
          }
        end
      end
    end
  end

  def expected_route(network, amount, target, max_hops, now)
    routes = enumerate_routes(network, amount, target, max_hops, now)
    routes.min_by { |route| [-route[:amount].fractional, route[:hops], route[:indices]] }
  end

  it "does not let a better rate product beat a cheaper direct quote" do
    amount = Money.new(10_000, "USD")
    network = [
      edge("USD", "GBP", rate: "1.0"),
      edge("USD", "EUR", rate: "1.0", fixed_fee: 600),
      edge("EUR", "GBP", rate: "1.0501", fixed_fee: 25),
    ]

    indirect_result = described_class.quote(amount, "GBP", network[1..], max_hops: 2)
    expect(indirect_result.received_amount).to eq(Money.new(9_845, "GBP"))

    result = described_class.quote(amount, "GBP", network, max_hops: 2)

    expect(result).to be_found
    expect(result.received_amount).to eq(Money.new(10_000, "GBP"))
    expect(result.route.hops).to eq(1)
    expect(result.route.currencies.map(&:to_s)).to eq(%w[USD GBP])

    first_step, second_step = indirect_result.route.steps
    expect(first_step.input_amount).to eq(amount)
    expect(first_step.fixed_fee).to eq(Money.new(600, "USD"))
    expect(first_step.proportional_fee).to eq(Money.new(0, "USD"))
    expect(first_step.total_fee).to eq(Money.new(600, "USD"))
    expect(first_step.net_input_amount).to eq(Money.new(9_400, "USD"))
    expect(first_step.received_amount).to eq(Money.new(9_400, "EUR"))
    expect(second_step.fixed_fee).to eq(Money.new(25, "EUR"))
    expect(second_step.net_input_amount).to eq(Money.new(9_375, "EUR"))
    expect(second_step.raw_received_fractional).to eq(BigDecimal("9844.6875"))
    expect(second_step.received_amount).to eq(Money.new(9_845, "GBP"))
  end

  it "charges and rounds every edge before continuing" do
    amount = Money.new(1_000, "USD")
    network = [
      edge("USD", "EUR", rate: "1", proportional_fee: "0.001"),
      edge("EUR", "JPY", rate: "100", proportional_fee: "0.001"),
    ]

    result = described_class.quote(amount, "JPY", network, max_hops: 2)

    expect(result).to be_found
    expect(result.route.steps[0].proportional_fee).to eq(Money.new(1, "USD"))
    expect(result.route.steps[0].received_amount).to eq(Money.new(999, "EUR"))
    expect(result.route.steps[1].proportional_fee).to eq(Money.new(1, "EUR"))
    expect(result.route.steps[1].received_amount).to eq(Money.new(998, "JPY"))
  end

  it "ignores expired edges and trades below the minimum" do
    now = Time.now
    amount = Money.new(10_000, "USD")
    network = [
      edge("USD", "EUR", rate: "2", expires_at: now),
      edge("USD", "GBP", rate: "2", minimum_amount: 10_001),
      edge("USD", "JPY", rate: "2", minimum_amount: 10_000),
    ]

    result = described_class.quote(amount, "EUR", network, max_hops: 2, now: now)

    expect(result).not_to be_found
    expect(result.status).to eq(:no_route)
    expect(result.received_amount).to be_nil
    expect(result.message).to eq(
      "No viable route found within the maximum number of hops",
    )

    available = described_class.quote(amount, "JPY", network, max_hops: 1, now: now)
    expect(available).to be_found
    expect(available.received_amount).to eq(Money.new(200, "JPY"))
  end

  it "respects the maximum hop count and never revisits a currency" do
    amount = Money.new(10_000, "USD")
    network = [
      edge("USD", "EUR", rate: "1"),
      edge("EUR", "GBP", rate: "1"),
      edge("GBP", "USD", rate: "1"),
      edge("EUR", "JPY", rate: "1"),
      edge("JPY", "GBP", rate: "1"),
    ]

    expect(described_class.quote(amount, "GBP", network, max_hops: 1)).not_to be_found

    two_hops = described_class.quote(amount, "GBP", network, max_hops: 2)
    expect(two_hops.route.currencies.map(&:to_s)).to eq(%w[USD EUR GBP])

    three_hops = described_class.quote(amount, "GBP", network, max_hops: 3)
    expect(three_hops.route.currencies.map(&:to_s)).to eq(%w[USD EUR GBP])
  end

  it "ties on amount, hop count, and stable edge order" do
    amount = Money.new(10_000, "USD")
    network = [
      edge("USD", "EUR", rate: "1", fixed_fee: 1),
      edge("USD", "GBP", rate: "1", fixed_fee: 1),
      edge("EUR", "JPY", rate: "1", fixed_fee: 1),
      edge("GBP", "JPY", rate: "1", fixed_fee: 1),
    ]

    result = described_class.quote(amount, "JPY", network, max_hops: 2)

    expect(result.route.ordinal_path).to eq([0, 2])
  end

  it "matches exhaustive enumeration on a small directed graph" do
    now = Time.now
    amount = Money.new(7_341, "USD")
    network = [
      edge("USD", "EUR", rate: "0.91", fixed_fee: 35, proportional_fee: "0.002"),
      edge("USD", "GBP", rate: "0.79", fixed_fee: 80, proportional_fee: "0.001"),
      edge("EUR", "GBP", rate: "0.87", fixed_fee: 25, proportional_fee: "0.003"),
      edge("EUR", "JPY", rate: "156.2", fixed_fee: 10, proportional_fee: "0.0015"),
      edge("GBP", "EUR", rate: "1.14", fixed_fee: 60, proportional_fee: "0.002"),
      edge("GBP", "JPY", rate: "181.7", fixed_fee: 45, proportional_fee: "0.001"),
      edge("JPY", "EUR", rate: "0.0058", fixed_fee: 30),
      edge("JPY", "GBP", rate: "0.0049", fixed_fee: 20),
    ]

    %w[EUR GBP JPY].each do |target|
      [1, 2, 3].each do |max_hops|
        expected = expected_route(network, amount, target, max_hops, now)
        result = described_class.quote(
          amount,
          target,
          network,
          max_hops: max_hops,
          now: now,
        )

        if expected
          expect(result).to be_found
          expect(result.received_amount).to eq(expected[:amount])
          expect(result.route.hops).to eq(expected[:hops])
          expect(result.route.ordinal_path).to eq(expected[:indices])
        else
          expect(result).not_to be_found
        end
      end
    end
  end

  it "does not use or modify Money.default_bank" do
    bank = Object.new
    amount = Money.new(10_000, "USD", bank)
    network = [edge("USD", "EUR", rate: "1")]

    result = described_class.quote(amount, "EUR", network, max_hops: 1)

    expect(Money.default_bank).not_to equal(bank)
    expect(result.route.steps.first.received_amount.bank).to equal(bank)
  end

  it "accepts string-keyed network hashes and wrapped Edge objects" do
    amount = Money.new(10_000, "USD")
    network = [
      {
        "from" => "USD",
        "to" => "EUR",
        "rate" => "0.9",
        "fixed_fee" => 10,
        "minimum_trade_amount" => 5_000,
      },
      Money::RouteQuoter::Edge.new(
        from_currency: "EUR",
        to_currency: "GBP",
        rate: "1",
      ),
    ]

    result = described_class.quote(amount, "GBP", network, max_hops: 2)

    expect(result).to be_found
    expect(result.route.steps[0].received_amount).to eq(Money.new(8_991, "EUR"))
    expect(result.received_amount).to eq(Money.new(8_991, "GBP"))
  end
end
