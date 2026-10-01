# frozen_string_literal: true

require "money"

RSpec.describe Money::Bank::VariableExchange, "exchange routes" do
  subject(:bank) { described_class.new }

  let(:rates) do
    {
      "USD" => {
        "EUR" => BigDecimal("2.0"),
        "GBP" => BigDecimal("1.1"),
      },
      "EUR" => { "CHF" => BigDecimal("0.4") },
      "GBP" => { "CHF" => BigDecimal("1.0") },
    }
  end

  let(:fees) do
    {
      %w[USD EUR] => Money.new(0, "USD"),
      %w[EUR CHF] => Money.new(0, "EUR"),
      %w[USD GBP] => Money.new(0, "USD"),
      %w[GBP CHF] => Money.new(50, "GBP"),
    }
  end

  it "chooses received money instead of the largest rate product" do
    route = bank.best_exchange_route(
      Money.new(1000, "USD"), "CHF", rates, fees, 3
    )

    expect(route.currencies).to eq(%w[USD GBP CHF])
    expect(route.amounts).to eq([
      Money.new(1000, "USD"),
      Money.new(1100, "GBP"),
      Money.new(1050, "CHF"),
    ])
    expect(route.fees).to eq([Money.new(0, "USD"), Money.new(50, "GBP")])
    expect(route.rates).to eq([BigDecimal("1.1"), BigDecimal("1.0")])
    expect(route.final_amount).to eq(Money.new(1050, "CHF"))
    expect(route.hops.map(&:amount_after_fee)).to eq([
      Money.new(1000, "USD"),
      Money.new(1050, "GBP"),
    ])
  end

  it "rejects routes that become negative after paying an edge fee" do
    unaffordable_rates = {
      "USD" => { "EUR" => BigDecimal("10.0") },
      "EUR" => { "CHF" => BigDecimal("1.0") },
    }
    unaffordable_fees = {
      %w[USD EUR] => Money.new(1001, "USD"),
      %w[EUR CHF] => Money.new(0, "EUR"),
    }

    route = bank.best_exchange_route(
      Money.new(1000, "USD"), "CHF", unaffordable_rates, unaffordable_fees, 2
    )

    expect(route).to be_nil
  end

  it "allows a route whose fee leaves zero" do
    zero_fee_rates = { "USD" => { "EUR" => BigDecimal("5.0") } }
    zero_fees = { %w[USD EUR] => Money.new(1000, "USD") }

    route = bank.best_exchange_route(
      Money.new(1000, "USD"), "EUR", zero_fee_rates, zero_fees, 1
    )

    expect(route.final_amount).to eq(Money.new(0, "EUR"))
    expect(route.hops.first.amount_after_fee).to eq(Money.new(0, "USD"))
  end

  it "rounds each conversion to the destination cash denomination" do
    cash_rates = {
      "USD" => { "EUR" => BigDecimal("1.0") },
      "EUR" => { "CHF" => BigDecimal("1.0") },
    }
    cash_fees = {
      %w[USD EUR] => Money.new(1, "USD"),
      %w[EUR CHF] => Money.new(1, "EUR"),
    }

    route = bank.best_exchange_route(
      Money.new(103, "USD"), "CHF", cash_rates, cash_fees, 2
    )

    expect(route.amounts).to eq([
      Money.new(103, "USD"),
      Money.new(102, "EUR"),
      Money.new(100, "CHF"),
    ])
    expect(route.hops.last.output_amount.fractional).to eq(100)
  end

  it "rounds Swiss franc output to a five-cent cash unit" do
    cash_rates = { "USD" => { "CHF" => BigDecimal("1.0") } }

    route = bank.best_exchange_route(
      Money.new(103, "USD"), "CHF", cash_rates, nil, 1
    )

    expect(route.final_amount).to eq(Money.new(105, "CHF"))
  end

  it "rounds output again after a destination-currency fee" do
    destination_fee_rates = {
      "USD" => {
        "CHF" => {
          rate: BigDecimal("1.04"),
          fee: { amount: 1, fee_currency: "CHF" },
        },
      },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", destination_fee_rates, nil, 1
    )

    expect(route.hops.first.amount_after_fee).to eq(Money.new(104, "CHF"))
    expect(route.final_amount).to eq(Money.new(105, "CHF"))
  end

  it "uses the bank rounding block on each raw converted amount" do
    rounding_bank = described_class.new { |amount| amount.floor }
    cash_rates = { "USD" => { "CHF" => BigDecimal("1.039") } }

    route = rounding_bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", cash_rates, nil, 1
    )

    expect(route.final_amount).to eq(Money.new(103, "CHF"))
  end

  it "keeps a lower intermediate amount when it has enough hops to improve" do
    state_rates = {
      "USD" => {
        "EUR" => BigDecimal("2.0"),
        "CHF" => BigDecimal("9.0"),
      },
      "EUR" => { "CHF" => BigDecimal("6.0") },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", state_rates, nil, 2
    )

    expect(route.currencies).to eq(%w[USD EUR CHF])
    expect(route.final_amount).to eq(Money.new(1200, "CHF"))
  end

  it "enumerates routes containing repeated currencies up to the hop limit" do
    cycle_rates = {
      "USD" => {
        "EUR" => BigDecimal("1.0"),
        "CHF" => BigDecimal("1.0"),
      },
      "EUR" => {
        "USD" => BigDecimal("2.0"),
        "CHF" => BigDecimal("1.0"),
      },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", cycle_rates, nil, 3
    )

    expect(route.currencies).to eq(%w[USD EUR USD CHF])
    expect(route.final_amount).to eq(Money.new(200, "CHF"))
  end

  it "does not take a repeated-currency route past the hop limit" do
    cycle_rates = {
      "USD" => { "EUR" => BigDecimal("1.0") },
      "EUR" => { "USD" => BigDecimal("2.0") },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "USD", cycle_rates, nil, 1
    )

    expect(route.currencies).to eq(["USD"])
    expect(route.final_amount).to eq(Money.new(100, "USD"))
  end

  it "prefers the shorter path on an equal final amount tie" do
    tied_rates = {
      "USD" => {
        "EUR" => BigDecimal("1.0"),
        "CHF" => BigDecimal("1.0"),
      },
      "EUR" => { "CHF" => BigDecimal("1.0") },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", tied_rates, nil, 2
    )

    expect(route.currencies).to eq(%w[USD CHF])
    expect(route.hops_count).to eq(1)
  end

  it "breaks equal-length ties lexicographically by currency path" do
    tied_rates = {
      "USD" => {
        "EUR" => BigDecimal("1.0"),
        "GBP" => BigDecimal("1.0"),
      },
      "EUR" => { "CHF" => BigDecimal("1.0") },
      "GBP" => { "CHF" => BigDecimal("1.0") },
    }

    route = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", tied_rates, nil, 2
    )

    expect(route.currencies).to eq(%w[USD EUR CHF])
  end

  it "freezes rates for one search even if the caller mutates the graph" do
    mutable_rates = {
      "USD" => { "EUR" => BigDecimal("1.0") },
      "EUR" => { "CHF" => BigDecimal("1.0") },
    }
    quote = Money::Bank::ExchangeQuote.new(rates: mutable_rates)
    route = quote.outgoing("USD")
    mutable_rates["USD"]["EUR"] = BigDecimal("99.0")

    expect(route.first.rate).to eq(BigDecimal("1.0"))

    planned = bank.best_exchange_route(
      Money.new(100, "USD"), "CHF", quote: quote, max_hops: 2
    )

    expect(planned.final_amount).to eq(Money.new(100, "CHF"))
  end

  it "accepts quote hashes with inline fees and keyword arguments" do
    quote_rates = {
      "USD" => {
        "EUR" => { rate: BigDecimal("1.1"), fee: Money.new(50, "USD") },
      },
    }

    route = bank.best_exchange_route(
      Money.new(1000, "USD"), "EUR", rates: quote_rates, max_hops: 1
    )

    expect(route.final_amount).to eq(Money.new(1045, "EUR"))
  end

  it "uses rates already registered in the bank when no graph is supplied" do
    bank.add_rate("USD", "EUR", BigDecimal("2.0"))

    route = bank.best_exchange_route(Money.new(100, "USD"), "EUR", max_hops: 1)

    expect(route.final_amount).to eq(Money.new(200, "EUR"))
  end

  it "preserves the input Money class on every hop" do
    special_money_class = Class.new(Money)
    cash_rates = { "USD" => { "EUR" => BigDecimal("1.0") } }

    route = bank.best_exchange_route(
      special_money_class.new(100, "USD"), "EUR", cash_rates, nil, 1
    )

    expect(route.hops.first.output_amount).to be_a(special_money_class)
    expect(route.final_amount).to be_a(special_money_class)
  end

  it "reuses a fixed quote for separate input amounts" do
    quote = Money::Bank::ExchangeQuote.new(rates: {
      "USD" => { "EUR" => BigDecimal("2.0") },
    })

    first = bank.best_exchange_route(Money.new(100, "USD"), "EUR", quote: quote, max_hops: 1)
    second = bank.best_exchange_route(Money.new(200, "USD"), "EUR", quote: quote, max_hops: 1)

    expect(first.final_amount).to eq(Money.new(200, "EUR"))
    expect(second.final_amount).to eq(Money.new(400, "EUR"))
  end

  it "validates the hop limit" do
    expect do
      bank.best_exchange_route(Money.new(100, "USD"), "EUR", rates, max_hops: -1)
    end.to raise_error(ArgumentError, "max_hops must be a non-negative Integer")
  end
end
