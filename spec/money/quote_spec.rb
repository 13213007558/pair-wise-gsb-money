# frozen_string_literal: true

RSpec.describe Money::Quote do
  let(:bank) do
    Money::Bank::VariableExchange.new(
      FluctuatingRatesStore.new(
        ["USD", "USD"] => BigDecimal("1"),
        ["EUR", "USD"] => BigDecimal("1"),
        ["JPY", "USD"] => BigDecimal("0.1")
      )
    )
  end

  let(:basket) do
    Money::Basket.new(
      Money.new(100_00, "USD"),
      Money.new(-20_00, "EUR"),
      Money.new(1_000, "JPY")
    )
  end

  describe ".capture" do
    it "records the rates actually used and the original currency totals" do
      quote = described_class.capture(basket, "USD", bank: bank)

      expect(quote.from_currency_totals.keys).to eq(%w[EUR JPY USD])
      expect(quote["EUR", "USD"]).to eq(BigDecimal("1.1"))
      expect(quote["JPY", "USD"]).to eq(BigDecimal("0.3"))
      expect(quote["USD", "USD"]).to eq(BigDecimal("1"))
      expect(quote.totals["EUR"]).to eq(Money.new(-20_00, "EUR"))
      expect(quote.totals["JPY"]).to eq(Money.new(1_000, "JPY"))
      expect(quote.totals["USD"]).to eq(Money.new(100_00, "USD"))
    end

    it "fails atomically when any rate is missing" do
      incomplete = Money::Bank::VariableExchange.new(
        FluctuatingRatesStore.new(["USD", "USD"] => BigDecimal("1"))
      )

      expect do
        described_class.capture(basket, "USD", bank: incomplete)
      end.to raise_error(Money::Bank::UnknownRate, /EUR.*JPY|JPY.*EUR/)
    end

    it "does not call the bank for an empty basket and quotes identity rate" do
      quote = described_class.capture(Money::Basket.new, "USD", bank: bank)

      expect(quote.rates).to be_empty
      expect(quote.convert).to eq(Money.new(0, "USD"))
    end
  end

  describe "stale rates" do
    it "keeps using the captured rates on repeated evaluation" do
      quote = described_class.capture(basket, "USD", bank: bank)
      first = quote.convert
      second = quote.convert

      expect(first).to eq(second)
      # 10000 USD + (-2000 EUR * 1.1) + (1000 JPY * 0.3) = 8100
      expect(first.fractional).to eq(8_100)
    end

    it "does not mix snapshots taken at different times" do
      first_quote = described_class.capture(basket, "USD", bank: bank)
      first_result = first_quote.convert

      second_quote = described_class.capture(basket, "USD", bank: bank)
      second_result = second_quote.convert

      # the second snapshot keeps reading fresh, drifting rates: EUR 1.3,
      # JPY 0.5 (reads 3 and 4) -> 10000 - 2600 + 500 = 7900
      expect(second_result.fractional).to eq(7_900)
      expect(second_result.fractional).not_to eq(first_result.fractional)
      expect(first_quote.convert).to eq(first_result)
      expect(second_quote.convert).to eq(second_result)
    end

    it "keeps interleaved evaluations pinned to their own snapshot" do
      first_quote = described_class.capture(basket, "USD", bank: bank)
      second_quote = described_class.capture(basket, "USD", bank: bank)

      first_result = first_quote.convert
      4.times do
        expect(first_quote.convert).to eq(first_result)
        expect(second_quote.convert).to eq(second_quote.convert)
      end
    end

    it "is immutable after formation" do
      quote = described_class.capture(basket, "USD", bank: bank)

      expect(quote).to be_frozen
      expect(quote.rates).to be_frozen
      expect(quote.totals).to be_frozen
    end
  end

  describe "#convert" do
    it "rounds only the final sum" do
      quote = described_class.capture(basket, "USD", bank: bank)
      # EUR contributes -2000 * (100/100) * 1.1   = -2200
      # JPY contributes 1000 * 0.3               = 300
      # USD contributes 10000
      # Sum 8100 -> 8100
      expect(quote.convert.fractional).to eq(8_100)
    end

    it "returns money in the report currency" do
      quote = described_class.capture(basket, "USD", bank: bank)

      expect(quote.convert.currency).to eq(Money::Currency.new("USD"))
    end
  end
end
