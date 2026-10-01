# frozen_string_literal: true

RSpec.describe Money::Bank::Routing do
  def best_route(amount, target, quotes, max_hops, from: "USD")
    described_class.best_route(Money.new(amount, from), target, quotes: quotes, max_hops: max_hops)
  end

  # Exhaustively walks every bounded path (cycles included) and returns the
  # winning [amount, currency sequence] under the documented tie-breaking
  # rules: larger amount, then fewer hops, then lexicographically smaller
  # currency sequence.
  def brute_force_route(amount, source, target, quotes, max_hops)
    best = nil
    stack = [[amount, source, max_hops, [source]]]
    until stack.empty?
      current, iso, hops_left, sequence = stack.pop
      if iso == target && (best.nil? || current > best[0] ||
          (current == best[0] && sequence.length < best[1].length) ||
          (current == best[0] && sequence.length == best[1].length && (sequence <=> best[1]) == -1))
        best = [current, sequence]
      end
      next if hops_left.zero?

      quotes.each do |quote|
        next unless quote.from.iso_code == iso

        after = (current * quote.rate).round(0, :half_up) - quote.fee
        stack << [after, quote.to.iso_code, hops_left - 1, sequence + [quote.to.iso_code]] unless after.negative?
      end
    end
    best
  end

  describe ".best_route" do
    it "converts, rounds and charges the fee on a direct quote" do
      route = best_route(100_00, "EUR", [{ from: "USD", to: "EUR", rate: 0.9, fee: 50 }], 1)
      expect(route.amount).to eq(Money.new(8950, "EUR"))
      expect(route.currencies.map(&:iso_code)).to eq(["USD", "EUR"])
    end

    it "reports every hop with amounts, rate and fee" do
      quotes = [
        { from: "USD", to: "GBP", rate: 0.8 },
        { from: "GBP", to: "EUR", rate: 1.15, fee: 10 },
      ]
      route = best_route(100_00, "EUR", quotes, 2)
      expect(route.hops.length).to eq(2)
      expect(route.hops[0].amount_before).to eq(Money.new(100_00, "USD"))
      expect(route.hops[0].amount_after).to eq(Money.new(8000, "GBP"))
      expect(route.hops[1].amount_before).to eq(Money.new(8000, "GBP"))
      expect(route.hops[1].amount_after).to eq(Money.new(9190, "EUR"))
      expect(route.hops[1].rate).to eq(BigDecimal("1.15"))
      expect(route.hops[1].fee).to eq(BigDecimal("10"))
    end

    it "does not treat the highest rate product as the answer when fees eat it" do
      quotes = [
        { from: "USD", to: "EUR", rate: 0.9 },
        { from: "USD", to: "GBP", rate: 0.98 },
        { from: "GBP", to: "EUR", rate: 1.0, fee: 1000 },
      ]
      route = best_route(100_00, "EUR", quotes, 2)
      expect(route.amount).to eq(Money.new(9000, "EUR"))
      expect(route.currencies.map(&:iso_code)).to eq(["USD", "EUR"])
    end

    it "picks a multi-hop route when it pays out more" do
      quotes = [
        { from: "USD", to: "EUR", rate: 0.9, fee: 50 },
        { from: "USD", to: "GBP", rate: 0.8 },
        { from: "GBP", to: "EUR", rate: 1.15, fee: 10 },
      ]
      route = best_route(100_00, "EUR", quotes, 2)
      expect(route.amount).to eq(Money.new(9190, "EUR"))
      expect(route.currencies.map(&:iso_code)).to eq(["USD", "GBP", "EUR"])
    end

    it "discards routes whose balance goes negative after a fee" do
      quotes = [
        { from: "USD", to: "EUR", rate: 0.9 },
        { from: "USD", to: "GBP", rate: 0.01 },
        { from: "GBP", to: "EUR", rate: 1.0, fee: 500 },
      ]
      route = best_route(100_00, "EUR", quotes, 2)
      expect(route.currencies.map(&:iso_code)).to eq(["USD", "EUR"])
    end

    it "raises UnknownRate when every route goes negative" do
      quotes = [
        { from: "USD", to: "GBP", rate: 0.01 },
        { from: "GBP", to: "EUR", rate: 1.0, fee: 500 },
      ]
      expect { best_route(100_00, "EUR", quotes, 2) }.to raise_error(Money::Bank::UnknownRate)
    end

    it "rounds to whole minor units at every hop, not only at the end" do
      quotes = [
        { from: "USD", to: "EUR", rate: 1.5 },
        { from: "EUR", to: "GBP", rate: 1.5 },
      ]
      route = best_route(3, "GBP", quotes, 2)
      expect(route.hops[0].amount_after).to eq(Money.new(5, "EUR"))
      expect(route.amount).to eq(Money.new(8, "GBP"))
    end

    it "uses at most max_hops conversions" do
      quotes = [
        { from: "USD", to: "EUR", rate: 0.9 },
        { from: "EUR", to: "GBP", rate: 1.0 },
      ]
      expect { best_route(100_00, "GBP", quotes, 1) }.to raise_error(Money::Bank::UnknownRate)
      expect(best_route(100_00, "GBP", quotes, 2).amount).to eq(Money.new(9000, "GBP"))
    end

    it "raises ArgumentError for a negative or non-integer max_hops" do
      expect { best_route(100_00, "EUR", [], -1) }.to raise_error(ArgumentError)
      expect { best_route(100_00, "EUR", [], 1.5) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for quotes that are neither Quote nor Hash" do
      expect { best_route(100_00, "EUR", ["bogus"], 1) }.to raise_error(ArgumentError)
    end

    context "when source and target currencies are the same" do
      it "returns the input amount with no hops" do
        route = best_route(100_00, "USD", [], 3)
        expect(route.amount).to eq(Money.new(100_00, "USD"))
        expect(route.hops).to be_empty
        expect(route.currencies.map(&:iso_code)).to eq(["USD"])
      end

      it "still uses a profitable cycle within max_hops" do
        quotes = [
          { from: "USD", to: "EUR", rate: 1.0 },
          { from: "EUR", to: "USD", rate: 1.5 },
        ]
        route = best_route(100_00, "USD", quotes, 2)
        expect(route.amount).to eq(Money.new(150_00, "USD"))
        expect(route.hops.length).to eq(2)
      end
    end

    context "with cyclic quotes" do
      let(:quotes) do
        [
          { from: "USD", to: "EUR", rate: 1.0 },
          { from: "EUR", to: "USD", rate: 1.5 },
        ]
      end

      it "revisits currencies up to the hop limit" do
        route = best_route(100_00, "EUR", quotes, 3)
        expect(route.amount).to eq(Money.new(150_00, "EUR"))
        expect(route.currencies.map(&:iso_code)).to eq(["USD", "EUR", "USD", "EUR"])
      end

      it "does not exceed the hop limit" do
        route = best_route(100_00, "EUR", quotes, 1)
        expect(route.amount).to eq(Money.new(100_00, "EUR"))
        expect(route.hops.length).to eq(1)
      end
    end

    context "with tied outcomes" do
      it "prefers the route with fewer hops" do
        quotes = [
          { from: "USD", to: "EUR", rate: 0.9 },
          { from: "USD", to: "GBP", rate: 0.9 },
          { from: "GBP", to: "EUR", rate: 1.0 },
        ]
        route = best_route(100_00, "EUR", quotes, 2)
        expect(route.amount).to eq(Money.new(9000, "EUR"))
        expect(route.hops.length).to eq(1)
      end

      it "prefers the lexicographically smaller currency sequence" do
        quotes = [
          { from: "USD", to: "EUR", rate: 1.0 },
          { from: "EUR", to: "GBP", rate: 1.0 },
          { from: "USD", to: "AUD", rate: 1.0 },
          { from: "AUD", to: "GBP", rate: 1.0 },
        ]
        route = best_route(100_00, "GBP", quotes, 2)
        expect(route.currencies.map(&:iso_code)).to eq(["USD", "AUD", "GBP"])
      end

      it "breaks ties at intermediate currencies the same way" do
        quotes = [
          { from: "USD", to: "CAD", rate: 1.0 },
          { from: "CAD", to: "EUR", rate: 1.0 },
          { from: "USD", to: "AUD", rate: 1.0 },
          { from: "AUD", to: "EUR", rate: 1.0 },
          { from: "EUR", to: "GBP", rate: 1.0 },
        ]
        route = best_route(100_00, "GBP", quotes, 3)
        expect(route.currencies.map(&:iso_code)).to eq(["USD", "AUD", "EUR", "GBP"])
      end
    end

    context "with a small random quote graph" do
      it "matches an exhaustive enumeration of every bounded path" do
        rng = Random.new(1234)
        currencies = ["USD", "EUR", "GBP", "JPY"]
        200.times do
          quotes = currencies.permutation(2).filter_map do |from, to|
            next unless rng.rand < 0.6

            described_class::Quote.new(from, to, rng.rand(0.5..2.0).round(2), fee: rng.rand(0..40))
          end
          amount = rng.rand(1..2000)
          max_hops = rng.rand(0..4)
          target = currencies.sample(random: rng)
          brute = brute_force_route(BigDecimal(amount.to_s), "USD", target, quotes, max_hops)
          route = begin
            best_route(amount, target, quotes, max_hops)
          rescue Money::Bank::UnknownRate
            nil
          end

          expect(route.nil?).to eq(brute.nil?)
          next if brute.nil?

          expect(route.amount.fractional).to eq(brute[0])
          expect(route.currencies.map(&:iso_code)).to eq(brute[1])
        end
      end
    end
  end

  describe Money::Bank::VariableExchange do
    let(:bank) { described_class.new }

    let(:quotes) do
      [
        { from: "USD", to: "EUR", rate: 0.9, fee: 50 },
        { from: "USD", to: "GBP", rate: 0.8 },
        { from: "GBP", to: "EUR", rate: 1.15, fee: 10 },
      ]
    end

    it "finds the best route through the caller-provided quotes" do
      route = bank.best_route(Money.new(100_00, "USD"), "EUR", quotes: quotes, max_hops: 2)
      expect(route.amount).to eq(Money.new(9190, "EUR"))
      expect(route.currencies.map(&:iso_code)).to eq(["USD", "GBP", "EUR"])
    end

    it "ignores the rates stored on the bank itself" do
      bank.add_rate("USD", "EUR", 0.5)
      route = bank.best_route(Money.new(100_00, "USD"), "EUR", quotes: quotes, max_hops: 1)
      expect(route.amount).to eq(Money.new(8950, "EUR"))
    end

    it "uses the bank's rounding method at every hop" do
      bank = described_class.new { |n| n.floor }
      quotes = [
        { from: "USD", to: "EUR", rate: 1.5 },
        { from: "EUR", to: "GBP", rate: 1.5 },
      ]
      route = bank.best_route(Money.new(3, "USD"), "GBP", quotes: quotes, max_hops: 2)
      expect(route.hops[0].amount_after).to eq(Money.new(4, "EUR"))
      expect(route.amount).to eq(Money.new(6, "GBP"))
    end

    it "replans when the caller passes a new set of quotes" do
      first = bank.best_route(Money.new(100_00, "USD"), "EUR", quotes: quotes, max_hops: 2)
      new_quotes = [{ from: "USD", to: "EUR", rate: 0.95 }]
      second = bank.best_route(Money.new(100_00, "USD"), "EUR", quotes: new_quotes, max_hops: 2)
      expect(first.amount).to eq(Money.new(9190, "EUR"))
      expect(second.amount).to eq(Money.new(9500, "EUR"))
    end
  end
end
