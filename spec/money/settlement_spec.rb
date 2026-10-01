# frozen_string_literal: true

RSpec.describe Money::Settlement do
  let(:counterexample) { { "a" => 5, "b" => 4, "c" => -4, "d" => -3, "e" => -2 } }

  def net_changes(transfers)
    net = Hash.new(0)
    transfers.each do |transfer|
      net[transfer.from] -= transfer.amount
      net[transfer.to] += transfer.amount
    end
    net
  end

  def expect_settles(balances, result)
    net = net_changes(result.transfers)
    balances.each do |name, amount|
      next if amount == 0

      expect(net[name]).to eq(amount), "participant #{name.inspect} does not net to zero"
    end
    result.transfers.each do |transfer|
      expect(transfer.amount).to be_a(Integer)
      expect(transfer.amount).to be_positive
    end
  end

  # Reference greedy strategy: always match the largest remaining creditor
  # with the largest remaining debtor. Returns the number of transfers.
  def greedy_magnitude_count(balances)
    debtors = balances.reject { |_, amount| amount >= 0 }.sort_by { |_, amount| amount }
    creditors = balances.reject { |_, amount| amount <= 0 }.sort_by { |_, amount| -amount }
    count = 0
    until debtors.empty?
      debtors.sort_by! { |_, amount| amount }
      creditors.sort_by! { |_, amount| -amount }
      amount = [creditors.first[1], -debtors.first[1]].min
      creditors[0] = [creditors.first[0], creditors.first[1] - amount]
      debtors[0] = [debtors.first[0], debtors.first[1] + amount]
      creditors.shift if creditors.first[1] == 0
      debtors.shift if debtors.first[1] == 0
      count += 1
    end
    count
  end

  # Independent brute force: enumerate every set partition (restricted growth
  # strings) and find the maximum number of zero-sum groups; the minimum
  # transfer count is participants - groups.
  def brute_force_min_transfers(amounts)
    amounts = amounts.reject(&:zero?)
    return 0 if amounts.size < 2

    best = 1
    assignment = Array.new(amounts.size, 0)
    walk = lambda do |index, group_count|
      if index == amounts.size
        sums = Array.new(group_count, 0)
        amounts.each_with_index { |amount, member| sums[assignment[member]] += amount }
        zero_groups = sums.count(&:zero?)
        best = [best, zero_groups == group_count ? group_count : zero_groups + 1].max
      else
        (0..group_count).each do |group|
          assignment[index] = group
          walk.call(index + 1, [group_count, group + 1].max)
        end
      end
    end
    walk.call(0, 0)
    amounts.size - best
  end

  describe "input validation" do
    it "rejects duplicate participant names" do
      expect { described_class.solve([["a", 1], ["a", -1]]) }
        .to raise_error(ArgumentError, /duplicate participant/)
    end

    it "rejects non-integer amounts" do
      expect { described_class.solve({ "a" => 1.5, "b" => -1.5 }) }
        .to raise_error(ArgumentError, /Integers/)
      expect { described_class.solve({ "a" => BigDecimal("1"), "b" => -1 }) }
        .to raise_error(ArgumentError, /Integers/)
    end

    it "rejects balances that do not sum to zero" do
      expect { described_class.solve({ "a" => 1, "b" => 0 }) }
        .to raise_error(ArgumentError, /sum to zero/)
    end

    it "rejects malformed containers and entries" do
      expect { described_class.solve(42) }.to raise_error(ArgumentError, /Hash/)
      expect { described_class.solve([["a", 1, 2], ["b", -1]]) }.to raise_error(ArgumentError, /pair/)
    end

    it "rejects an invalid search budget" do
      expect { described_class.solve({ "a" => 1, "b" => -1 }, max_nodes: -1) }
        .to raise_error(ArgumentError, /max_nodes/)
    end
  end

  describe "normalization" do
    it "drops zero balances" do
      result = described_class.solve({ "a" => 100, "b" => -100, "c" => 0 })
      expect(result).to be_optimal
      expect(result.transfers).to eq([described_class::Transfer.new(from: "b", to: "a", amount: 100)])
      expect(result.groups).to contain_exactly(contain_exactly("a", "b"))
    end

    it "handles empty and all-zero inputs" do
      expect(described_class.solve({})).to be_optimal
      expect(described_class.solve({}).transfers).to be_empty
      expect(described_class.solve({ "a" => 0, "b" => 0 }).transfers).to be_empty
    end

    it "accepts both hashes and arrays of pairs" do
      hash_result = described_class.solve({ "a" => 5, "b" => -5 })
      array_result = described_class.solve([["a", 5], ["b", -5]])
      expect(array_result.transfers).to eq(hash_result.transfers)
    end
  end

  describe "greedy counterexample" do
    it "finds fewer transfers than magnitude-based greedy pairing" do
      expect(greedy_magnitude_count(counterexample)).to eq(4)

      result = described_class.solve(counterexample)
      expect(result).to be_optimal
      expect(result.transfer_count).to eq(3)
      expect(result.lower_bound).to eq(3)
      expect(result.upper_bound).to eq(3)
      expect_settles(counterexample, result)
    end
  end

  describe "determinism" do
    it "returns the same solution regardless of input order" do
      first = described_class.solve(counterexample)
      shuffled = counterexample.to_a.shuffle(random: Random.new(7)).to_h
      second = described_class.solve(shuffled)
      expect(second.transfers).to eq(first.transfers)
      expect(second.groups).to eq(first.groups)
      expect(described_class.solve(counterexample).transfers).to eq(first.transfers)
    end
  end

  describe "optimality basis" do
    it "attaches a reviewable proof" do
      result = described_class.solve(counterexample)
      proof = result.proof
      expect(proof[:status]).to eq(:optimal)
      expect(proof[:transfer_count]).to eq(proof[:lower_bound])
      expect(proof[:zero_sum_groups].map { |group| group.sum { |name| counterexample.fetch(name) } })
        .to all(eq(0))
      expect(proof[:zero_sum_groups].flatten).to contain_exactly(*counterexample.keys)
      expect(proof[:argument]).to include("5 - 2 = 3")
    end
  end

  describe "search budget" do
    it "returns the feasible solution, bounds, and a non-optimal status when exhausted" do
      result = described_class.solve(counterexample, max_nodes: 0)
      expect(result).not_to be_optimal
      expect(result.status).to eq(:budget_exhausted)
      expect(result.upper_bound).to eq(result.transfer_count)
      expect(result.lower_bound).to be < result.upper_bound
      expect(result.lower_bound).to be <= 3
      expect(result.proof[:argument]).to include("budget")
      expect_settles(counterexample, result)
    end

    it "proves optimality when the budget suffices" do
      result = described_class.solve(counterexample, max_nodes: 10_000)
      expect(result).to be_optimal
      expect(result.transfer_count).to eq(3)
      expect(result.nodes_explored).to be_positive
    end
  end

  describe ".verify" do
    it "accepts correct optimal and budget-exhausted results" do
      optimal = described_class.solve(counterexample)
      expect(described_class.verify(counterexample, optimal)).to be true

      exhausted = described_class.solve(counterexample, max_nodes: 0)
      expect(described_class.verify(counterexample, exhausted)).to be true
    end

    it "rejects transfers that do not net to the input balances" do
      result = described_class.solve(counterexample)
      tampered = described_class::Result.new(
        transfers: [described_class::Transfer.new(from: "a", to: "b", amount: 1)],
        groups: result.groups,
        lower_bound: 1,
        upper_bound: 1,
        nodes_explored: 0,
        status: :budget_exhausted,
      )
      expect { described_class.verify(counterexample, tampered) }
        .to raise_error(Money::Settlement::VerificationError, /net change/)
    end

    it "rejects a false optimality claim" do
      feasible = described_class.solve(counterexample, max_nodes: 0)
      fake = described_class::Result.new(
        transfers: feasible.transfers,
        groups: feasible.groups,
        lower_bound: feasible.lower_bound,
        upper_bound: feasible.upper_bound,
        nodes_explored: 0,
        status: :optimal,
      )
      expect { described_class.verify(counterexample, fake) }
        .to raise_error(Money::Settlement::VerificationError, /optimality claim is false/)
    end

    it "rejects groups that are not zero-sum" do
      result = described_class.solve(counterexample)
      forged = described_class::Result.new(
        transfers: result.transfers,
        groups: [%w[a b], %w[c d e]],
        lower_bound: result.lower_bound,
        upper_bound: result.upper_bound,
        nodes_explored: 0,
        status: :budget_exhausted,
      )
      expect { described_class.verify(counterexample, forged) }
        .to raise_error(Money::Settlement::VerificationError, /does not sum to zero/)
    end
  end

  describe "exhaustive small-scale verification" do
    it "matches brute force for every balance vector of up to 4 participants in -3..3" do
      checked = 0
      (2..4).each do |size|
        [-3, -2, -1, 0, 1, 2, 3].repeated_permutation(size) do |amounts|
          next unless amounts.sum == 0

          balances = amounts.each_with_index.to_h { |amount, index| ["p#{index}", amount] }
          result = described_class.solve(balances)
          expect(result).to be_optimal
          expect(result.transfer_count).to eq(brute_force_min_transfers(amounts)),
                                          "wrong count for #{amounts.inspect}"
          expect(result.lower_bound).to eq(result.transfer_count)
          expect_settles(balances, result)
          checked += 1
        end
      end
      expect(checked).to be_positive
    end

    it "matches brute force on random 6-participant instances" do
      rng = Random.new(20_261_001)
      100.times do
        amounts = Array.new(6) { rng.rand(-6..6) }
        amounts[5] = -amounts[0..4].sum
        balances = amounts.each_with_index.to_h { |amount, index| ["p#{index}", amount] }
        result = described_class.solve(balances)
        expect(result).to be_optimal
        expect(result.transfer_count).to eq(brute_force_min_transfers(amounts)),
                                        "wrong count for #{amounts.inspect}"
        expect_settles(balances, result)
        expect(described_class.verify(balances, result)).to be true
      end
    end
  end

  describe "Money.settle" do
    it "is an exact-solving entry point on Money" do
      result = Money.settle(counterexample)
      expect(result).to be_a(Money::Settlement::Result)
      expect(result).to be_optimal
      expect(result.transfer_count).to eq(3)
    end
  end
end

