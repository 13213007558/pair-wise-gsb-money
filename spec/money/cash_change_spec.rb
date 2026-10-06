# frozen_string_literal: true

require "timeout"

RSpec.describe Money::CashChange do
  def money(value)
    Money.new(value, "USD")
  end

  def inventory(values, stocks)
    values.zip(stocks).to_h { |value, stock| [money(value), stock] }
  end

  def brute_force(values, stocks, target, priority = values)
    ranges = stocks.map { |stock| 0..stock }
    combinations = ranges.first.to_a.product(*ranges.drop(1).map(&:to_a))
    priority_indexes = priority.map { |value| values.index(value) }

    combinations
      .select { |counts| counts.zip(values).sum { |count, value| count * value } == target }
      .min do |left, right|
        comparison = left.sum <=> right.sum
        next comparison unless comparison.zero?

        left_priority = priority_indexes.map { |index| -left[index] }
        right_priority = priority_indexes.map { |index| -right[index] }
        left_priority <=> right_priority
      end
  end

  describe "#cash_change" do
    it "matches exhaustive search for non-standard denominations and limited stock" do
      values = [8, 5, 3]
      stocks = [1, 1, 2]
      available = inventory(values, stocks)

      (0..values.zip(stocks).sum { |value, stock| value * stock }).each do |target|
        expected = brute_force(values, stocks, target)
        result = money(target).cash_change(available)

        if expected
          expect(result.solution?).to be(true)
          expect(result.total_count).to eq(expected.sum)
          values.each_with_index do |value, index|
            expect(result.quantities[money(value)]).to eq(expected[index])
          end
        else
          expect(result).to be(Money::CashChange::NO_SOLUTION)
        end
      end
    end

    it "returns an exact minimum when taking the largest denomination first would fail" do
      available = inventory([6, 4], [1, 2])

      result = money(8).cash_change(available)

      expect(result.total_count).to eq(2)
      expect(result.quantities).to eq(money(6) => 0, money(4) => 2)
    end

    it "uses larger denominations as the stable default tie-breaker" do
      available = inventory([8, 6, 4], [1, 2, 1])

      result = money(12).cash_change(available)

      expect(result.total_count).to eq(2)
      expect(result.quantities).to eq(
        money(8) => 1,
        money(6) => 0,
        money(4) => 1,
      )
    end

    it "honors a caller-provided tie-breaking priority" do
      values = [8, 6, 4]
      available = inventory(values, [1, 2, 1])
      priority = [6, 4, 8].map { |value| money(value) }

      result = money(12).cash_change(available, priority: priority)

      expect(result.total_count).to eq(2)
      expect(result.quantities).to eq(
        money(8) => 0,
        money(6) => 2,
        money(4) => 0,
      )
    end

    it "returns the explicit no-solution result for an unreachable amount" do
      result = money(7).cash_change(inventory([6, 4], [1, 2]))

      expect(result.solution?).to be(false)
      expect(result.solvable?).to be(false)
      expect(result.quantities).to be_nil
      expect(result.total_count).to be_nil
      expect(result).to be(Money::CashChange::NO_SOLUTION)
    end

    it "returns zero of every denomination for zero change" do
      result = money(0).cash_change(inventory([10, 5], [2, 3]))

      expect(result.solution?).to be(true)
      expect(result.quantities).to eq(money(10) => 0, money(5) => 0)
      expect(result.total_count).to eq(0)
    end

    it "supports an empty inventory for zero change" do
      result = money(0).cash_change({})

      expect(result.solution?).to be(true)
      expect(result.quantities).to eq({})
      expect(result.total_count).to eq(0)
    end

    it "keeps the caller inventory unchanged" do
      available = inventory([6, 4], [1, 2]).freeze
      priority = [money(6), money(4)].freeze
      original = available.transform_values(&:itself)

      money(8).cash_change(available, priority: priority)

      expect(available).to eq(original)
    end

    it "supports the class-level entry point" do
      available = inventory([6, 4], [1, 2])

      expect(Money.cash_change(money(8), available).total_count).to eq(2)
    end

    it "handles a large amount without an array indexed by amount" do
      available = inventory([100, 1], [10_000_000_000_000_000, 100])

      result = Timeout.timeout(1) { money(1_000_000_000_000_000_000).cash_change(available) }

      expect(result.total_count).to eq(10_000_000_000_000_000)
      expect(result.quantities[money(1)]).to eq(0)
    end

    it "rejects a different currency in the inventory" do
      available = {money(5) => 1, Money.new(5, "EUR") => 1}

      expect { money(10).cash_change(available) }
        .to raise_error(ArgumentError, "cannot mix currencies in cash change inventory")
    end

    it "rejects negative stock" do
      expect { money(5).cash_change({ money(5) => -1 }) }
        .to raise_error(ArgumentError, "inventory stock must be a non-negative integer")
    end

    it "rejects zero and negative denominations" do
      expect { money(5).cash_change({ money(0) => 1 }) }
        .to raise_error(ArgumentError, "denominations must be positive integer fractional units")
      expect { money(5).cash_change({ money(-1) => 1 }) }
        .to raise_error(ArgumentError, "denominations must be positive integer fractional units")
    end

    it "rejects non-integer fractional amounts", :default_infinite_precision_true do
      expect { Money.new(BigDecimal("5.5"), "USD").cash_change({ money(1) => 6 }) }
        .to raise_error(ArgumentError, "change amount must be a non-negative integer in fractional units")
    end

    it "accepts mathematically integral BigDecimal amounts as integer subunits",
       :default_infinite_precision_true do
      result = Money.new(BigDecimal("6"), "USD").cash_change({ money(4) => 1, money(3) => 2 })

      expect(result.total_count).to eq(2)
      expect(result.quantities[money(3)]).to eq(2)
    end

    it "rejects a negative change amount" do
      expect { money(-1).cash_change({ money(1) => 1 }) }
        .to raise_error(ArgumentError, "change amount must be a non-negative integer in fractional units")
    end

    it "rejects priority lists that do not match the inventory" do
      available = inventory([6, 4], [1, 2])

      expect { money(8).cash_change(available, priority: [money(6)]) }
        .to raise_error(ArgumentError, "priority must list every inventory denomination exactly once")
      expect { money(8).cash_change(available, priority: [money(6), money(5)]) }
        .to raise_error(ArgumentError, "priority must list every inventory denomination exactly once")
    end
  end
end
