# frozen_string_literal: true

require "json"

RSpec.describe Money::Basket do
  let(:usd_income) { Money.new(100_00, "USD") }
  let(:eur_refund) { Money.new(-20_00, "EUR") }
  let(:jpy_fee_out) { Money.new(-1_50, "JPY") }
  let(:jpy_fee_back) { Money.new(1_50, "JPY") }

  def build_basket
    described_class.new(usd_income) +
      described_class.new(eur_refund) +
      described_class.new(jpy_fee_out, jpy_fee_back)
  end

  describe "construction and netting" do
    it "keeps one net amount per currency and eliminates zero entries" do
      basket = build_basket

      expect(basket.amounts.keys).to eq(%w[EUR USD])
      expect(basket["USD"].fractional).to eq(100_00)
      expect(basket["EUR"].fractional).to eq(-20_00)
      expect(basket["JPY"]).to be_nil
    end

    it "nets same-currency money passed to the constructor" do
      basket = described_class.new(
        Money.new(30_00, "USD"),
        Money.new(-10_00, "USD"),
        Money.new(0, "USD")
      )

      expect(basket.amounts.keys).to eq(%w[USD])
      expect(basket["USD"].fractional).to eq(20_00)
    end

    it "rejects non-money entries" do
      expect { described_class.new(100) }.to raise_error(TypeError)
    end

    it "is empty when every entry nets to zero" do
      basket = described_class.new(Money.new(5, "USD"), Money.new(-5, "USD"))

      expect(basket).to be_empty
      expect(basket).to be_zero
    end
  end

  describe "#+ and merge" do
    it "merges per currency without converting" do
      basket = described_class.new(Money.new(10_00, "USD"))
      merged = basket + described_class.new(
        Money.new(5_00, "USD"),
        Money.new(2_00, "EUR")
      )

      expect(merged["USD"].fractional).to eq(15_00)
      expect(merged["EUR"].fractional).to eq(2_00)
      expect(basket["USD"].fractional).to eq(10_00)
    end

    it "accepts a single Money object" do
      basket = described_class.new(Money.new(10_00, "USD")) + Money.new(2_00, "EUR")

      expect(basket["EUR"].fractional).to eq(2_00)
    end

    it "never queries the bank" do
      bank = spy("bank")
      left = described_class.new(Money.new(10_00, "USD", bank))
      right = described_class.new(Money.new(5_00, "EUR", bank))

      _sum = left + right
      _difference = left - right
      _negated = -left

      expect(bank).not_to have_received(:get_rate)
      expect(bank).not_to have_received(:exchange_with)
    end
  end

  describe "#- and negation" do
    it "subtracts per currency" do
      basket = described_class.new(Money.new(10_00, "USD"), Money.new(3_00, "EUR"))
      result = basket - described_class.new(Money.new(4_00, "USD"))

      expect(result["USD"].fractional).to eq(6_00)
      expect(result["EUR"].fractional).to eq(3_00)
    end

    it "removes entries that become zero" do
      result = described_class.new(Money.new(10_00, "USD")) -
               described_class.new(Money.new(10_00, "USD"))

      expect(result.amounts).to be_empty
    end

    it "negates every amount" do
      basket = -described_class.new(Money.new(10_00, "USD"), Money.new(-3_00, "EUR"))

      expect(basket["USD"].fractional).to eq(-10_00)
      expect(basket["EUR"].fractional).to eq(3_00)
    end
  end

  describe "immutability" do
    it "is frozen and does not mutate through operations" do
      basket = build_basket

      expect(basket).to be_frozen
      expect(basket.amounts).to be_frozen
      expect { basket.amounts["USD"] = Money.new(1, "USD") }.to raise_error(FrozenError)
    end
  end

  describe "equality" do
    it "is equal when currency nets match regardless of insertion order" do
      first = described_class.new(Money.new(1, "USD"), Money.new(2, "EUR"))
      second = described_class.new(Money.new(2, "EUR"), Money.new(1, "USD"))

      expect(first).to eq(second)
      expect(first.hash).to eq(second.hash)
      expect(first).to eql(second)
    end

    it "is not equal to a basket with different amounts" do
      expect(described_class.new(Money.new(1, "USD"))).not_to eq(
        described_class.new(Money.new(2, "USD"))
      )
    end
  end

  describe "stable serialization" do
    it "serializes currency codes in a stable order" do
      basket = described_class.new(
        Money.new(100_00, "USD"),
        Money.new(-20_00, "EUR"),
        Money.new(1_50, "JPY")
      )

      expect(basket.as_json).to eq(
        "EUR" => "-2000",
        "JPY" => "150",
        "USD" => "10000"
      )
      expect(basket.to_json).to eq(%({"EUR":"-2000","JPY":"150","USD":"10000"}))
    end

    it "round trips losslessly through JSON" do
      basket = build_basket
      restored = described_class.from_json(basket.to_json)

      expect(restored).to eq(basket)
      expect(restored.to_json).to eq(basket.to_json)
      expect(restored["USD"].fractional).to be_a(Integer)
    end

    it "round trips fractional amounts" do
      Money.default_infinite_precision = true
      begin
        half_cent = Money.new(BigDecimal("100.5"), "USD")
        basket = described_class.new(half_cent)
        restored = described_class.from_json(basket.to_json)

        expect(restored["USD"].fractional).to eq(BigDecimal("100.5"))
      ensure
        Money.default_infinite_precision = false
      end
    end
  end

  describe "#convert_to" do
    let(:bank) do
      bank = Money::Bank::VariableExchange.new
      bank.add_rate("EUR", "USD", "1.08")
      bank.add_rate("JPY", "USD", "0.67")
      bank
    end

    it "converts the net amounts with a single explicit quote" do
      basket = described_class.new(
        Money.new(100_00, "USD"),
        Money.new(-50_00, "EUR"),
        Money.new(1_000, "JPY")
      )

      result = basket.convert_to("USD", bank: bank)

      expect(result.currency).to eq(Money::Currency.new("USD"))
      # 10000 USD + (-5000 EUR * 1.08) + (1000 JPY * 0.67) = 5270
      expect(result.fractional).to eq(5_270)
    end

    it "rounds only once, at the final boundary" do
      bank.add_rate("KRW", "USD", "1.5")
      basket = described_class.new(
        Money.new(1, "JPY"),
        Money.new(1, "KRW")
      )

      result = basket.convert_to("USD", bank: bank)

      # Each leg is sub-cent fractional: 0.67 and 1.5; rounding per leg
      # would yield 1 + 2 = 3, rounding the combined 2.17 yields 2.
      expect(result.fractional).to eq(2)
    end

    it "converts an empty basket to zero without reading rates" do
      result = described_class.new.convert_to("USD", bank: bank)

      expect(result).to eq(Money.new(0, "USD"))
    end
  end
end
