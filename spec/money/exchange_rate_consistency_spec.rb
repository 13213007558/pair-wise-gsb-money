# frozen_string_literal: true

RSpec.describe Money::ExchangeRateConsistency do
  describe ".find_profitable_cycle" do
    it "returns a directed witness with the original rates" do
      rates = {
        "A" => { "B" => Rational(2, 1), "X" => 1 },
        "B" => { "C" => Rational(3, 4) },
        "C" => { "A" => Rational(3, 4) },
      }

      result = described_class.find_profitable_cycle(rates)

      expect(result).to be_found
      expect(result.status).to eq(:found)
      expect(result.path).to eq(["A", "B", "C", "A"])
      expect(result.edges.map { |edge| [edge.from, edge.to] }).to eq([
        ["A", "B"],
        ["B", "C"],
        ["C", "A"],
      ])
      expect(result.edges.map(&:rate)).to eq([
        Rational(2, 1),
        Rational(3, 4),
        Rational(3, 4),
      ])
      expect(result.product).to eq(Rational(9, 8))
      expect(result.edges.map(&:rate).map(&:to_r).inject(:*)).to eq(result.product)
      expect(result.rates.map(&:to_r).inject(:*)).to eq(result.product_rational)
      expect(result.budget_remaining).to be_nil
    end

    it "does not infer missing reverse edges or reciprocals" do
      rates = {
        "A" => { "B" => Rational(2, 1) },
        "B" => { "A" => Rational(2, 5), "C" => Rational(3, 4) },
        "C" => { "A" => Rational(3, 4) },
      }

      result = described_class.find_profitable_cycle(rates)

      expect(result.path).to eq(["A", "B", "C", "A"])
      expect(result.edges.map(&:rate)).to eq([
        Rational(2, 1),
        Rational(3, 4),
        Rational(3, 4),
      ])
    end

    it "reports not found when every complete directed cycle has product at most one" do
      rates = {
        "A" => { "B" => Rational(2, 1) },
        "B" => { "C" => Rational(3, 4) },
        "C" => { "A" => Rational(2, 3) },
      }

      result = described_class.find_profitable_cycle(rates)

      expect(result).to be_complete
      expect(result).not_to be_found
      expect(result.status).to eq(:not_found)
      expect(result.path).to be_nil
      expect(result.edges).to eq([])
      expect(result.product).to be_nil
    end

    it "preserves a gain smaller than floating-point display precision" do
      tiny_gain_rate = BigDecimal("1") + BigDecimal("1E-30")
      one = BigDecimal("1")
      rates = {
        "A" => { "B" => tiny_gain_rate },
        "B" => { "C" => one },
        "C" => { "A" => one },
      }

      result = described_class.find_profitable_cycle(rates)
      exact_product = Rational(10**30 + 1, 10**30)

      expect(result).to be_found
      expect(result.edges.first.rate).to equal(tiny_gain_rate)
      expect(result.product).to eq(exact_product)
      expect(result.product).to be >(1)
      expect(result.edges.map { |edge| edge.rate.to_r }.inject(:*)).to eq(exact_product)
    end

    it "uses the exact rational value of floating-point rates" do
      result = described_class.find_profitable_cycle({
        "A" => { "B" => 0.1 },
        "B" => { "C" => 5 },
        "C" => { "A" => 2 },
      })

      expect(result).to be_found
      expect(result.product).to eq(Rational(18_014_398_509_481_985, 18_014_398_509_481_984))
      expect(result.rates.map(&:to_r).inject(:*)).to eq(result.product)
    end

    it "detects a profitable self-loop as a simple directed cycle" do
      result = described_class.find_profitable_cycle({ "A" => { "A" => Rational(101, 100) } })

      expect(result.path).to eq(["A", "A"])
      expect(result.rates).to eq([Rational(101, 100)])
      expect(result.product).to eq(Rational(101, 100))
    end

    it "accepts a fixed bank snapshot through its rate store" do
      store = Money::RatesStore::Memory.new
      store.add_rate("A", "B", "2")
      store.add_rate("B", "C", "0.75")
      store.add_rate("C", "A", "0.75")
      bank = Money::Bank::VariableExchange.new(store)

      result = described_class.find_profitable_cycle(bank)

      expect(result.path).to eq(["A", "B", "C", "A"])
      expect(result.edges.map(&:rate)).to eq(["2", "0.75", "0.75"])
      expect(result.product).to eq(Rational(9, 8))
    end

    it "accepts a snapshot whose each_rate requires a block" do
      source = Object.new
      rates = [
        ["A", "B", "2"],
        ["B", "C", "0.75"],
        ["C", "A", "0.75"],
      ]
      source.define_singleton_method(:each_rate) do |&block|
        rates.each { |rate| block.call(*rate) }
      end

      result = described_class.find_profitable_cycle(source)

      expect(result.path).to eq(["A", "B", "C", "A"])
      expect(result.product).to eq(Rational(9, 8))
    end

    it "distinguishes a completed search from an unfinished budget-limited search" do
      rates = {
        "A" => { "B" => Rational(2, 1) },
        "B" => { "C" => Rational(3, 4) },
        "C" => { "A" => Rational(3, 4) },
      }

      incomplete = described_class.find_profitable_cycle(rates, budget: 2)
      found = described_class.find_profitable_cycle(rates, budget: 3)

      expect(incomplete.status).to eq(:incomplete)
      expect(incomplete).to be_incomplete
      expect(incomplete).not_to be_complete
      expect(incomplete.path).to be_nil
      expect(incomplete.budget_remaining).to eq(0)
      expect(found).to be_found
      expect(found.budget_remaining).to eq(0)
    end

    [0, -1, BigDecimal("0"), BigDecimal("-0.1"), BigDecimal("NaN"), BigDecimal("Infinity"), "0", "-1", "NaN", "Infinity", "not-a-rate", nil].each do |invalid_rate|
      it "rejects invalid rate #{invalid_rate.inspect}" do
        rates = { "A" => { "B" => invalid_rate } }

        expect { described_class.find_profitable_cycle(rates) }.to raise_error(
          described_class::InvalidRate,
          /finite positive Numeric/,
        )
      end
    end

    it "rejects duplicate directed edges" do
      rates = {
        "A" => { "B" => 1 },
        "A_TO_B" => 2,
      }

      expect { described_class.find_profitable_cycle(rates) }.to raise_error(
        described_class::InvalidSnapshot,
        /duplicate directed rate A -> B/,
      )
    end

    it "rejects an unsupported snapshot" do
      expect { described_class.find_profitable_cycle(42) }.to raise_error(
        described_class::InvalidSnapshot,
        /must be a Hash/,
      )
    end

    it "rejects an invalid budget" do
      expect { described_class.find_profitable_cycle({}, budget: -1) }.to raise_error(ArgumentError)
    end
  end
end
