# frozen_string_literal: true

require "spec_helper"

RSpec.describe Money::RateConsistencyChecker do
  subject(:checker) { described_class.new }

  def check(snapshot, **opts)
    checker.check(snapshot, **opts)
  end

  describe ".check" do
    it "delegates to an instance" do
      result = described_class.check({ ["USD", "EUR"] => 2, ["EUR", "USD"] => Rational(3, 5) })

      expect(result).to be_arbitrage
    end
  end

  describe "#check" do
    context "with an arbitrage cycle" do
      subject(:result) { check({ ["USD", "EUR"] => 2, ["EUR", "JPY"] => 3, ["JPY", "USD"] => Rational(1, 5) }) }

      it "reports :arbitrage" do
        expect(result.status).to eq(:arbitrage)
        expect(result).to be_arbitrage
        expect(result).not_to be_consistent
        expect(result).not_to be_inconclusive
      end

      it "returns a closed currency path through the cycle" do
        currencies = result.cycle.currencies

        expect(currencies.first).to eq(currencies.last)
        expect(currencies.length).to eq(4)
        expect(currencies[0..-2]).to contain_exactly("USD", "EUR", "JPY")
      end

      it "rotates the path to start at the smallest currency code" do
        expect(result.cycle.currencies).to eq(["EUR", "JPY", "USD", "EUR"])
      end

      it "keeps the original rate object on every edge" do
        rates = result.cycle.edges.map(&:rate)

        expect(rates).to contain_exactly(2, 3, Rational(1, 5))
      end

      it "computes the exact product from the witness alone" do
        cycle = result.cycle
        recomputed = cycle.edges.map(&:rational).reduce(1r, :*)

        expect(recomputed).to eq(cycle.product)
        expect(cycle.product).to eq(Rational(6, 5))
        expect(cycle.product).to be > 1
      end
    end

    context "with a cycle exceeding 1 by a tiny amount" do
      let(:epsilon_string) { "1.#{'0' * 29}1" }
      let(:epsilon) { Rational(10**30 + 1, 10**30) }
      let(:snapshot) do
        {
          ["USD", "EUR"] => 1,
          ["EUR", "JPY"] => epsilon_string,
          ["JPY", "USD"] => BigDecimal("1"),
        }
      end

      it "detects the cycle exactly" do
        result = check(snapshot)

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(epsilon)
        expect(result.cycle.product).to be > 1
      end

      it "returns a witness that recomputes exactly, beyond float precision" do
        cycle = check(snapshot).cycle

        expect(cycle.product.to_f).to eq(1.0)
        expect(cycle.edges.map(&:rational).reduce(1r, :*)).to eq(epsilon)
        expect(cycle.product - 1).to eq(Rational(1, 10**30))
      end

      it "keeps the original rate objects on the edges" do
        edge = check(snapshot).cycle.edges.find { |e| e.from == "EUR" && e.to == "JPY" }

        expect(edge.rate).to eq(epsilon_string)
        expect(edge.rational).to eq(epsilon)
      end
    end

    context "with a cycle whose product is exactly 1" do
      it "reports :consistent" do
        result = check({ ["USD", "EUR"] => 2, ["EUR", "USD"] => Rational(1, 2) })

        expect(result.status).to eq(:consistent)
        expect(result).to be_consistent
        expect(result.cycle).to be_nil
      end
    end

    context "with a cycle whose product is just below 1" do
      it "reports :consistent" do
        result = check({ ["USD", "EUR"] => 1, ["EUR", "USD"] => Rational(10**30 - 1, 10**30) })

        expect(result).to be_consistent
      end
    end

    context "with a missing reverse edge" do
      it "does not invent the reciprocal rate" do
        result = check({ ["USD", "EUR"] => 1000 })

        expect(result).to be_consistent
      end
    end

    context "with disconnected components" do
      it "finds arbitrage in any component" do
        result = check({
          ["USD", "EUR"] => 2,
          ["EUR", "USD"] => Rational(1, 2),
          ["GBP", "JPY"] => 3,
          ["JPY", "GBP"] => Rational(1, 2),
        })

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(Rational(3, 2))
      end
    end

    context "with a self-loop" do
      it "detects a rate greater than 1" do
        result = check({ ["USD", "USD"] => Rational(3, 2) })

        expect(result).to be_arbitrage
        expect(result.cycle.currencies).to eq(["USD", "USD"])
        expect(result.cycle.product).to eq(Rational(3, 2))
      end

      it "accepts a rate of exactly 1" do
        expect(check({ ["USD", "USD"] => 1 })).to be_consistent
      end
    end

    context "with an empty snapshot" do
      it "reports :consistent" do
        expect(check({})).to be_consistent
      end
    end

    context "with lowercase currency names" do
      it "normalizes them to ISO codes" do
        result = check({ ["usd", "eur"] => 2, ["eur", "usd"] => 0.6 })

        expect(result).to be_arbitrage
        expect(result.cycle.currencies).to eq(["EUR", "USD", "EUR"])
      end
    end

    describe "snapshot formats" do
      let(:expected_product) { Rational(6, 5) }

      it "accepts a hash with 'FROM_TO' string keys" do
        result = check({ "USD_TO_EUR" => 2, "EUR_TO_USD" => Rational(3, 5) })

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(expected_product)
      end

      it "accepts an array of [from, to, rate] triples" do
        result = check([["USD", "EUR", 2], ["EUR", "USD", Rational(3, 5)]])

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(expected_product)
      end

      it "accepts a Money::RatesStore::Memory" do
        store = Money::RatesStore::Memory.new
        store.add_rate("USD", "EUR", 2)
        store.add_rate("EUR", "USD", Rational(3, 5))

        result = check(store)

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(expected_product)
      end

      it "accepts a Money::Bank::VariableExchange" do
        bank = Money::Bank::VariableExchange.new
        bank.add_rate("USD", "EUR", 2)
        bank.add_rate("EUR", "USD", Rational(3, 5))

        result = check(bank)

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(expected_product)
      end

      it "rejects an unsupported snapshot" do
        expect { check(42) }.to raise_error(described_class::InvalidSnapshot)
      end

      it "rejects a hash key without a currency pair" do
        expect { check({ "USD" => 2 }) }.to raise_error(described_class::InvalidSnapshot)
      end

      it "rejects a hash key that is not a pair or string" do
        expect { check({ 42 => 2 }) }.to raise_error(described_class::InvalidSnapshot)
      end

      it "rejects an incomplete currency pair" do
        expect { check({ ["USD"] => 2 }) }.to raise_error(described_class::InvalidSnapshot)
      end

      it "rejects a triple with a missing currency" do
        expect { check([["USD", nil, 2]]) }.to raise_error(described_class::InvalidSnapshot)
      end
    end

    describe "rate validation" do
      it "rejects zero and negative rates" do
        [0, -1, 0.0, "-0.5", BigDecimal("-0.01"), 0r].each do |rate|
          expect { check({ ["USD", "EUR"] => rate }) }.to raise_error(described_class::InvalidRate)
        end
      end

      it "rejects non-finite rates" do
        [Float::NAN, Float::INFINITY, -Float::INFINITY, BigDecimal("NaN"), BigDecimal("Infinity")].each do |rate|
          expect { check({ ["USD", "EUR"] => rate }) }.to raise_error(described_class::InvalidRate)
        end
      end

      it "rejects unparseable and unsupported rates" do
        ["abc", "", "1.2.3", nil, true, Object.new].each do |rate|
          expect { check({ ["USD", "EUR"] => rate }) }.to raise_error(described_class::InvalidRate)
        end
      end

      it "accepts exact decimal strings" do
        result = check({ ["USD", "EUR"] => "1.5", ["EUR", "USD"] => "0.75" })

        expect(result).to be_arbitrage
        expect(result.cycle.product).to eq(Rational(9, 8))
      end
    end

    describe "analysis budget" do
      # A chain whose edges are ordered against the flow, so proving
      # consistency needs four full passes (12 edge examinations).
      let(:path_snapshot) do
        {
          ["JPY", "GBP"] => 2,
          ["EUR", "JPY"] => 2,
          ["USD", "EUR"] => 2,
        }
      end

      it "reports :inconclusive when the budget runs out before the proof completes" do
        result = check(path_snapshot, max_steps: 11)

        expect(result.status).to eq(:inconclusive)
        expect(result).to be_inconclusive
        expect(result).not_to be_consistent
        expect(result).not_to be_arbitrage
        expect(result.cycle).to be_nil
      end

      it "reports :inconclusive immediately with a zero budget" do
        expect(check(path_snapshot, max_steps: 0)).to be_inconclusive
      end

      it "proves consistency once the budget suffices" do
        expect(check(path_snapshot, max_steps: 12)).to be_consistent
      end

      it "returns a found witness even near the budget limit" do
        result = check({ ["USD", "EUR"] => 2, ["EUR", "USD"] => Rational(3, 5) }, max_steps: 4)

        expect(result).to be_arbitrage
      end

      it "rejects invalid budgets" do
        [-1, 1.5, "10"].each do |budget|
          expect { check({}, max_steps: budget) }.to raise_error(ArgumentError)
        end
      end
    end
  end
end
