# frozen_string_literal: true

require "money/bank/variable_exchange"

RSpec.describe Money::MultiCurrencyAmounts do
  subject(:amounts) do
    described_class.new(
      Money.new(1_000, "USD"),
      Money.new(-3_00, "EUR"),
      Money.new(250, "JPY"),
      bank: bank,
    )
  end

  let(:bank) { Money::Bank::VariableExchange.new }

  describe ".new" do
    it "nets amounts by currency without querying rates" do
      expect(bank).not_to receive(:get_rate)

      collection = described_class.new(
        Money.new(1_200, "USD", bank: bank),
        Money.new(-200, "USD", bank: bank),
        Money.new(-500, "EUR", bank: bank),
        Money.new(200, "EUR", bank: bank),
      )

      expect(collection.to_h).to eq(
        "EUR" => -300,
        "USD" => 1_000,
      )
    end

    it "accepts nested arrays and fractional currency hashes" do
      collection = described_class.new(
        [Money.new(100, "USD"), { "EUR" => 200 }],
        { "USD" => -50, "EUR" => Money.new(-50, "EUR") },
      )

      expect(collection.to_h).to eq(
        "EUR" => 150,
        "USD" => 50,
      )
    end

    it "eliminates net zero currencies" do
      collection = described_class.new(
        Money.new(100, "USD"),
        Money.new(-100, "USD"),
      )

      expect(collection).to be_empty
      expect(collection.to_a).to eq([])
      expect(collection.amount_for("USD")).to eq(Money.new(0, "USD"))
    end

    it "is deeply immutable" do
      expect(amounts).to be_frozen
      expect(amounts.to_a).to all(be_frozen)
      expect(amounts.to_h).to be_frozen
      expect(amounts.to_h).to eq({
        "EUR" => -300,
        "JPY" => 250,
        "USD" => 1_000,
      })
    end

    it "rejects unsupported values" do
      expect { described_class.new(100) }
        .to raise_error(TypeError, /Unsupported multi-currency amount/)
    end
  end

  describe "arithmetic" do
    it "merges collections without exchange" do
      expect(bank).not_to receive(:get_rate)

      merged = amounts + described_class.new(
        Money.new(200, "USD"),
        Money.new(100, "GBP"),
        bank: bank,
      )

      expect(merged.to_h).to eq({
        "EUR" => -300,
        "GBP" => 100,
        "JPY" => 250,
        "USD" => 1_200,
      })
    end

    it "subtracts collections and removes resulting zero items" do
      result = amounts - described_class.new(
        Money.new(1_000, "USD"),
        Money.new(-300, "EUR"),
      )

      expect(result.to_h).to eq("JPY" => 250)
    end

    it "negates every nonzero amount" do
      expect((-amounts).to_h).to eq({
        "EUR" => 300,
        "JPY" => -250,
        "USD" => -1_000,
      })
    end

    it "does not mutate either operand" do
      other = described_class.new(Money.new(100, "USD"), bank: bank)

      _first_result = amounts + other
      _second_result = amounts - other

      expect(amounts["USD"]).to eq(Money.new(1_000, "USD"))
      expect(other["USD"]).to eq(Money.new(100, "USD"))
    end
  end

  describe "serialization" do
    it "serializes currencies in stable ISO order" do
      expect(amounts.as_json).to eq(
        "EUR" => "-300",
        "JPY" => "250",
        "USD" => "1000",
      )
      expect(JSON.parse(amounts.to_json)).to eq(amounts.as_json)
    end

    it "has value equality and hashing" do
      duplicate = described_class.new(
        Money.new(1_000, "USD"),
        Money.new(-3_00, "EUR"),
        Money.new(250, "JPY"),
      )

      expect(amounts).to eq(duplicate)
      expect(amounts.hash).to eq(duplicate.hash)
      expect([amounts]).to include(duplicate)
    end
  end

  describe "#quote" do
    let(:volatile_store_class) do
      Class.new do
        attr_reader :read_count

        def initialize
          @rates = {}
          @read_count = Hash.new(0)
        end

        def add_rate(from, to, rate)
          @rates[[from, to].join("_TO_")] = rate
        end

        def get_rate(from, to)
          key = [from, to].join("_TO_")
          @read_count[key] += 1
          rate = @rates[key]
          return nil if rate.nil?

          rate_value = BigDecimal(rate.to_s)
          @rates[key] = (rate_value + 1).to_s
          rate_value
        end
      end
    end

    it "rejects a source that is not a multi-currency collection" do
      expect { Money::ConversionQuote.new(Money.new(100, "USD"), "EUR") }
        .to raise_error(TypeError, /must be a Money::MultiCurrencyAmounts/)
    end

    let(:volatile_store) { volatile_store_class.new }
    let(:volatile_bank) { Money::Bank::VariableExchange.new(volatile_store) }

    before do
      volatile_store.add_rate("USD", "EUR", "1.0")
      volatile_store.add_rate("EUR", "EUR", nil)
      volatile_store.add_rate("JPY", "EUR", "0.00001")
    end

    it "builds a snapshot of actual rates and source currency totals" do
      quote = amounts.quote("EUR", bank: volatile_bank)

      expect(quote.target_currency).to eq(Money::Currency.new("EUR"))
      expect(quote.rates).to eq({
        "EUR" => BigDecimal("1"),
        "JPY" => BigDecimal("0.00001"),
        "USD" => BigDecimal("1.0"),
      })
      expect(quote.source_totals.transform_values(&:fractional)).to eq({
        "EUR" => -300,
        "JPY" => 250,
        "USD" => 1_000,
      })
    end

    it "fails as a whole when any rate is missing" do
      volatile_store.add_rate("JPY", "EUR", nil)

      expect { amounts.quote("EUR", bank: volatile_bank) }
        .to raise_error(Money::Bank::UnknownRate, /JPY -> EUR/)
      expect(volatile_store.read_count["USD_TO_EUR"]).to eq(1)
    end

    it "does not read the bank when adding or subtracting" do
      other = described_class.new(Money.new(10, "USD"), bank: volatile_bank)

      expect { amounts + other }.not_to change(volatile_store, :read_count)
      expect { amounts - other }.not_to change(volatile_store, :read_count)
    end

    it "reuses the same quote even if the bank changes between evaluations" do
      quote = amounts.quote("EUR", bank: volatile_bank)
      volatile_store.add_rate("USD", "EUR", "999")
      volatile_store.add_rate("JPY", "EUR", "999")

      first = quote.convert
      second = quote.convert

      expect(first).to eq(Money.new(700, "EUR"))
      expect(second).to eq(first)
      expect(quote).to be_frozen
    end

    it "creates a separate snapshot on the next quote" do
      original = amounts.quote("EUR", bank: volatile_bank)

      expect(original.convert).to eq(Money.new(700, "EUR"))
      new_quote = amounts.quote("EUR", bank: volatile_bank)

      expect(new_quote.rates["USD"]).to eq(BigDecimal("2.0"))
      expect(new_quote.convert).not_to eq(original.convert)
    end

    it "rounds only the final report-currency total" do
      collection = described_class.new(
        Money.new(200, "EUR"),
        Money.new(1, "JPY"),
        Money.new(1, "JPY"),
        bank: volatile_bank,
      )
      volatile_store.add_rate("JPY", "EUR", "0.007")

      quote = collection.quote("EUR")

      expect(quote.unrounded_fractional).to eq(BigDecimal("201.4"))
      expect(quote.convert).to eq(Money.new(201, "EUR"))
      expect(quote.convert(rounding_mode: BigDecimal::ROUND_UP)).to eq(Money.new(202, "EUR"))
    end

    it "preserves target fractional precision when infinite precision is enabled" do
      Money.default_infinite_precision = true
      bank.add_rate("USD", "EUR", "1.5")
      collection = described_class.new(Money.new(BigDecimal("10.25"), "USD"), bank: bank)

      converted = collection.quote("EUR").convert

      expect(converted.fractional).to eq(BigDecimal("15.375"))
    ensure
      Money.default_infinite_precision = false
    end

    it "serializes the quote snapshot stably" do
      quote = amounts.quote("EUR", bank: volatile_bank)

      expect(JSON.parse(quote.to_json)).to eq(
        "target_currency" => "EUR",
        "source_totals" => {
          "EUR" => "-300",
          "JPY" => "250",
          "USD" => "1000",
        },
        "rates" => {
          "EUR" => "1.0",
          "JPY" => "0.00001",
          "USD" => "1.0",
        },
      )
    end

    it "does not query for an amount already in the report currency" do
      collection = described_class.new(Money.new(100, "EUR"), bank: volatile_bank)

      quote = collection.quote("EUR")

      expect(quote.rates).to eq("EUR" => BigDecimal("1"))
      expect(quote.convert).to eq(Money.new(100, "EUR"))
      expect(volatile_store.read_count).to be_empty
    end
  end
end
