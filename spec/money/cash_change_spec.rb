# frozen_string_literal: true

RSpec.describe Money::CashChange do
  # Exhaustive reference solver used only inside specs: enumerates every
  # quantity vector within inventory and returns the unique optimum selected
  # by the same lexical rule the production code defaults to.
  def brute_force_optimal(amount, stock)
    denominations = stock.keys.sort.reverse
    best = nil

    enumerate = lambda do |index, remaining, chosen|
      if index == denominations.length
        if remaining.zero?
          pieces = denominations.sum { |value| chosen[value].to_i }
          best_pieces = best.nil? ? nil : denominations.sum { |value| best[value].to_i }
          best = chosen.dup if best.nil? || pieces < best_pieces
        end
        return
      end

      value = denominations[index]
      max = [stock[value], remaining / value].min
      max.downto(0) do |count|
        chosen[value] = count
        enumerate.call(index + 1, remaining - count * value, chosen)
      end
      chosen.delete(value)
    end

    chosen = {}
    enumerate.call(0, amount, chosen)
    best
  end

  def verify_exact!(amount, stock)
    result = Money.new(amount, "USD").cash_change(stock, budget: nil)

    if (optimal = brute_force_optimal(amount, stock)).nil?
      expect(result.found?).to eq(false)
      return
    end

    expect(result.found?).to eq(true)
    optimal_counts = denominations_present(stock).to_h { |value| [value, optimal[value].to_i] }
    expect(result.counts).to eq(optimal_counts)
    expect(result.total_pieces).to eq(optimal_counts.values.sum)
    expect(result.counts.sum { |value, count| value * count }).to eq(amount)
  end

  def denominations_present(stock)
    stock.keys.sort.reverse
  end

  describe "#cash_change on Money" do
    it "is exposed as a standalone entry point returning a result" do
      result = Money.new(6, "USD").cash_change({ 4 => 1, 3 => 2 })

      expect(result).to be_a(described_class::Result)
      expect(result).to be_found
      expect(result.solution?).to eq(true)
      expect(result.counts).to eq(4 => 0, 3 => 2)
      expect(result.total_pieces).to eq(2)
    end

    it "is also available through Money::CashChange.generate" do
      result = described_class.generate(Money.new(6, "USD"), { 4 => 1, 3 => 2 })

      expect(result.counts).to eq(4 => 0, 3 => 2)
      expect(result.total_pieces).to eq(2)
    end

    it "reports every requested denomination, including unused zeroes" do
      result = Money.new(6, "USD").cash_change({ 4 => 1, 3 => 2, 1 => 5 })

      expect(result.counts).to eq(4 => 0, 3 => 2, 1 => 0)
    end

    it "returns an empty combination for zero change" do
      result = Money.new(0, "USD").cash_change({ 4 => 1, 3 => 2 })

      expect(result).to be_found
      expect(result.counts).to eq(4 => 0, 3 => 0)
      expect(result.total_pieces).to eq(0)
    end

    it "never mutates the caller's stock" do
      stock = { 4 => 1, 3 => 2 }
      original = stock.dup

      Money.new(6, "USD").cash_change(stock)

      expect(stock).to eq(original)
    end
  end

  describe "optimality against exhaustive search" do
    it "matches brute force for non-standard denominations and tight inventory" do
      # Deliberately non-canonical denominations and tiny stocks, where greedy
      # choices are frequently suboptimal or infeasible.
      stock = { 4 => 1, 3 => 2, 2 => 1, 1 => 3 }

      (0..14).each { |amount| verify_exact!(amount, stock) }
    end

    it "matches brute force across many random small inventory problems" do
      rng = Random.new(20261006)

      50.times do
        values = Array.new(rng.rand(1..5)) { rng.rand(1..9) }.uniq
        stock = values.to_h { |value| [value, rng.rand(0..4)] }
        amount = rng.rand(0..15)

        verify_exact!(amount, stock)
      end
    end

    it "matches brute force for each tie-break policy" do
      stock = { 8 => 1, 7 => 1, 3 => 1, 2 => 1 }
      amount = 10
      # Two genuine two-piece solutions: 8+2 and 7+3.
      largest = Money.new(amount, "USD").cash_change(stock)
      smallest = Money.new(amount, "USD").cash_change(stock, tie_break: :smallest_first)

      expect(largest.counts.values.sum).to eq(2)
      expect(smallest.counts.values.sum).to eq(2)
      expect(largest.counts).to eq(8 => 1, 7 => 0, 3 => 0, 2 => 1)
      expect(smallest.counts).to eq(8 => 0, 7 => 1, 3 => 1, 2 => 0)
    end
  end

  describe "greedy counterexample" do
    it "rejects taking as many of the largest denomination as possible" do
      # Amount 6 with denominations 4, 3, 1. A largest-first greedy strategy
      # takes one 4 and then needs two 1s (3 pieces), but 3+3 uses 2 pieces.
      stock = { 4 => 1, 3 => 2, 1 => 5 }
      greedy = [4, 1, 1]
      optimal = [3, 3]

      expect(greedy.sum).to eq(6)
      expect(optimal.sum).to eq(6)
      expect(optimal.length).to be < greedy.length

      result = Money.new(6, "USD").cash_change(stock)

      expect(result.counts).to eq(4 => 0, 3 => 2, 1 => 0)
      expect(result.total_pieces).to eq(2)
    end

    it "recovers even when largest-first greedy cannot finish with inventory" do
      # Taking a 10 leaves 1, which cannot be made; 6+5 is feasible.
      result = Money.new(11, "USD").cash_change({ 10 => 1, 6 => 2, 5 => 1 })

      expect(result.counts).to eq(10 => 0, 6 => 1, 5 => 1)
      expect(result.total_pieces).to eq(2)
    end
  end

  describe "unreachable amounts" do
    it "returns a found?=false result instead of raising" do
      result = Money.new(7, "USD").cash_change({ 4 => 1, 6 => 1 })

      expect(result).not_to be_found
      expect(result.solution?).to eq(false)
      expect(result.counts).to be_nil
      expect(result.total_pieces).to be_nil
    end

    it "is unreachable when inventory value is insufficient" do
      result = Money.new(100, "USD").cash_change({ 4 => 2, 6 => 1 })

      expect(result).not_to be_found
    end

    it "is unreachable when the gcd of denominations does not divide the amount" do
      result = Money.new(5, "USD").cash_change({ 4 => 10, 6 => 10 })

      expect(result).not_to be_found
    end
  end

  describe "tie-breaking" do
    it "defaults to a stable largest-denomination-first choice" do
      stock = { 6 => 1, 5 => 1, 3 => 1, 2 => 1 }

      result = Money.new(8, "USD").cash_change(stock)

      expect(result.counts).to eq(6 => 1, 5 => 0, 3 => 0, 2 => 1)
    end

    it "supports an explicit priority array" do
      stock = { 6 => 1, 5 => 1, 3 => 1, 2 => 1 }

      result = Money.new(8, "USD").cash_change(stock, tie_break: [5, 3, 6, 2])

      expect(result.counts).to eq(6 => 0, 5 => 1, 3 => 1, 2 => 0)
    end

    it "supports a caller supplied comparator over count hashes" do
      stock = { 6 => 1, 5 => 1, 3 => 1, 2 => 1 }
      prefer_fives = ->(candidate, best) { candidate[5].to_i > best[5].to_i }

      result = Money.new(8, "USD").cash_change(stock, tie_break: prefer_fives)

      expect(result.counts).to eq(6 => 0, 5 => 1, 3 => 1, 2 => 0)
    end

    it "is deterministic across repeated calls" do
      stock = { 8 => 2, 7 => 2, 3 => 2, 2 => 2 }
      results = Array.new(5) do
        Money.new(10, "USD").cash_change(stock).counts
      end

      expect(results.uniq.size).to eq(1)
    end
  end

  describe "Money-denominated stock" do
    it "accepts Money keys of the same currency in subunit terms" do
      stock = {
        Money.new(4, "USD") => 1,
        Money.new(3, "USD") => 2,
      }

      result = Money.new(6, "USD").cash_change(stock)

      expect(result.counts).to eq(Money.new(4, "USD") => 0, Money.new(3, "USD") => 2)
      expect(result.total_pieces).to eq(2)
    end

    it "accepts whole-valued BigDecimal amounts under infinite precision" do
      Money.default_infinite_precision = true
      result =
        begin
          Money.new(BigDecimal("6"), "USD").cash_change({ 4 => 1, 3 => 2 })
        ensure
          Money.default_infinite_precision = false
        end

      expect(result.total_pieces).to eq(2)
    end
  end

  describe "validation" do
    it "rejects a negative change amount" do
      expect { Money.new(-1, "USD").cash_change({ 4 => 1 }) }
        .to raise_error(ArgumentError, /cannot be negative/)
    end

    it "rejects a non-integer subunit amount" do
      Money.default_infinite_precision = true
      begin
        expect { Money.new(BigDecimal("6.5"), "USD").cash_change({ 4 => 1 }) }
          .to raise_error(ArgumentError, /whole number of subunits/)
      ensure
        Money.default_infinite_precision = false
      end
    end

    it "rejects mixed currencies" do
      stock = { Money.new(4, "EUR") => 1 }

      expect { Money.new(4, "USD").cash_change(stock) }
        .to raise_error(ArgumentError, /does not match/)
    end

    it "rejects negative inventory" do
      expect { Money.new(4, "USD").cash_change({ 4 => -1 }) }
        .to raise_error(ArgumentError, /non-negative/)
    end

    it "rejects non-integer inventory" do
      expect { Money.new(4, "USD").cash_change({ 4 => 1.5 }) }
        .to raise_error(ArgumentError, /non-negative Integer/)
    end

    it "rejects non-positive or non-integer denominations" do
      expect { Money.new(4, "USD").cash_change({ 0 => 1 }) }
        .to raise_error(ArgumentError, /positive/)
      expect { Money.new(4, "USD").cash_change({ "4" => 1 }) }
        .to raise_error(ArgumentError, /Integer or a Money/)
    end

    it "rejects duplicate denominations expressed through different keys" do
      stock = { 4 => 1, Money.new(4, "USD") => 1 }

      expect { Money.new(4, "USD").cash_change(stock) }
        .to raise_error(ArgumentError, /duplicate/)
    end

    it "rejects an unknown tie-break symbol" do
      expect { Money.new(4, "USD").cash_change({ 4 => 1 }, tie_break: :nonsense_policy) }
        .to raise_error(ArgumentError, /tie_break/)
    end

    it "rejects a priority array missing denominations" do
      expect { Money.new(8, "USD").cash_change({ 6 => 1, 2 => 1 }, tie_break: [6]) }
        .to raise_error(ArgumentError, /every stock denomination/)
    end
  end

  describe "large amounts and bounded search" do
    it "handles huge subunit amounts without allocating an amount-sized array" do
      huge = 10**18
      stock = {
        500 => 10**18,
        200 => 10**18,
        100 => 10**18,
        25 => 10**18,
        10 => 10**18,
        5 => 10**18,
        1 => 10**18,
      }

      durations = Array.new(5) do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Money.new(huge, "USD").cash_change(stock)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      end
      result = Money.new(huge, "USD").cash_change(stock)

      expect(durations.max).to be < 1.0

      expect(result.total_pieces).to eq(2_000_000_000_000_000)
      expect(result.counts.sum { |value, count| value * count }).to eq(huge)
    end

    it "raises BudgetExceeded when the state budget is exhausted" do
      # A gcd-reachable amount the bounded branch-and-bound cannot prove
      # within an artificially tiny budget.
      expect do
        Money.new(97, "USD").cash_change(
          { 50 => 1, 30 => 1, 20 => 1, 6 => 20, 5 => 20, 2 => 20, 1 => 20 },
          budget: 3,
        )
      end.to raise_error(described_class::BudgetExceeded)
    end

    it "allows the budget to be disabled" do
      result = Money.new(97, "USD").cash_change(
        { 50 => 1, 30 => 1, 20 => 1, 6 => 20, 5 => 20, 2 => 20, 1 => 20 },
        budget: nil,
      )

      expect(result).to be_found
      expect(result.counts.sum { |value, count| value * count }).to eq(97)
    end
  end
end
