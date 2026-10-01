# frozen_string_literal: true

RSpec.describe Money::Settlement do
  def net_changes(result)
    changes = result.participants.each_with_object({}) do |participant, net|
      net[participant] = 0
    end

    result.transfers.each do |transfer|
      expect(transfer.from).not_to eq(transfer.to)
      expect(transfer.amount.fractional).to be_positive
      changes[transfer.from] -= transfer.amount.fractional
      changes[transfer.to] += transfer.amount.fractional
    end
    changes
  end

  def assert_reproduces_input(result, balances)
    expected = balances.to_h.reject { |_participant, value| value.zero? }
    actual = net_changes(result).to_h

    expect(actual).to eq(expected)
    expect(result.participants).to match_array(expected.keys)
  end

  def largest_balance_greedy(balances)
    participants = balances.keys
    remaining = balances.transform_values(&:to_i)
    transfers = []

    until remaining.values.all?(&:zero?)
      creditor = participants.select { |participant| remaining[participant].positive? }
                           .max_by { |participant| [remaining[participant], -participants.index(participant)] }
      debtor = participants.select { |participant| remaining[participant].negative? }
                          .max_by { |participant| [-remaining[participant], -participants.index(participant)] }
      amount = [remaining[creditor], -remaining[debtor]].min

      remaining[creditor] -= amount
      remaining[debtor] += amount
      transfers << amount
    end
    transfers
  end

  def set_partitions(members)
    return [[]] if members.empty?

    first = members.first
    set_partitions(members.drop(1)).flat_map do |groups|
      alone = [[first], *groups]
      inserted = groups.each_index.map do |index|
        groups.map.with_index do |group, group_index|
          group_index == index ? [first, *group] : group
        end
      end
      [alone, *inserted]
    end
  end

  def brute_force_optimal_count(balances)
    maximum_zero_sum_groups = set_partitions(balances.keys)
      .select { |groups| groups.all? { |group| group.sum(&balances).zero? } }
      .map(&:size)
      .max

    balances.size - maximum_zero_sum_groups
  end

  describe ".generate" do
    it "removes zero balances and returns no transfers" do
      result = described_class.generate(
        { a: 0, b: Money.new(0, "USD") },
        currency: "USD",
      )

      expect(result).to be_optimal
      expect(result.transfers).to eq([])
      expect(result.participants).to eq([])
      expect(result.lower_bound).to eq(0)
      expect(result.upper_bound).to eq(0)
    end

    it "allows an all-zero integer balance set without a currency" do
      result = described_class.generate({ a: 0, b: 0 })

      expect(result).to be_optimal
      expect(result.currency).to be_nil
      expect(result.transfers).to eq([])
    end

    it "accepts Money values in one currency and integer minimum-unit values" do
      result = described_class.generate(
        [
          [:alice, Money.new(-3_00, "USD")],
          [:bob, 2_00],
          [:carol, Money.new(1_00, "USD")],
        ],
        currency: "USD",
      )

      expect(result).to be_optimal
      expect(result.transfers.map(&:amount)).to all(be_a(Money))
      assert_reproduces_input(result, { alice: -3_00, bob: 2_00, carol: 1_00 })
    end

    it "uses a deterministic canonical optimum for equal-cardinality solutions" do
      balances = {
        a: -2,
        b: -2,
        c: 2,
        d: 2,
      }

      first = described_class.generate(balances, currency: "USD")
      second = described_class.generate(balances, currency: "USD")

      expect(first.transfers).to eq(second.transfers)
      expect(first.transfers).to eq(
        [
          described_class::Transfer.new(:a, :c, Money.new(2, "USD")),
          described_class::Transfer.new(:b, :d, Money.new(2, "USD")),
        ],
      )
      expect(first.proof.grouping).to eq([[:a, :c], [:b, :d]])
    end

    it "finds fewer transfers than pairing the largest remaining balances" do
      balances = { a: -6, b: -5, c: 2, d: 4, e: 5 }

      result = described_class.generate(balances, currency: "USD")

      expect(largest_balance_greedy(balances).size).to eq(4)
      expect(result.transfers.size).to eq(3)
      expect(result).to be_optimal
      expect(result.lower_bound).to eq(3)
      expect(result.upper_bound).to eq(3)
      expect(result.proof.grouping).to eq([[:a, :c, :d], [:b, :e]])
      assert_reproduces_input(result, balances)
    end

    it "returns a feasible plan with separated bounds when the search budget is exhausted" do
      balances = { a: -6, b: -5, c: 2, d: 4, e: 5 }

      result = described_class.generate(
        balances,
        currency: "USD",
        search_budget: 0,
      )

      expect(result).to be_budget_exhausted
      expect(result).not_to be_optimal
      expect(result.transfers.size).to eq(4)
      expect(result.lower_bound).to eq(3)
      expect(result.upper_bound).to eq(4)
      expect(result.proof).to be_nil
      expect(result.budget_used).to eq(0)
      assert_reproduces_input(result, balances)
    end

    it "can prove optimality inside a finite search budget" do
      balances = { a: -6, b: -5, c: 2, d: 4, e: 5 }

      result = described_class.generate(
        balances,
        currency: "USD",
        search_budget: 13,
      )

      expect(result).to be_optimal
      expect(result.transfers.size).to eq(3)
      expect(result.budget_used).to eq(13)
      assert_reproduces_input(result, balances)
    end

    it "does not claim optimality merely because feasible bounds coincide" do
      balances = { a: -6, b: -5, c: 2, d: 4, e: 5 }

      result = described_class.generate(
        balances,
        currency: "USD",
        search_budget: 12,
      )

      expect(result).to be_budget_exhausted
      expect(result.lower_bound).to eq(3)
      expect(result.upper_bound).to eq(3)
      expect(result.proof).to be_nil
      assert_reproduces_input(result, balances)
    end

    it "rejects duplicate participant names" do
      expect do
        described_class.generate([[:a, 1], [:a, -1]], currency: "USD")
      end.to raise_error(ArgumentError, /duplicate participant/)
    end

    it "rejects balances in different currencies and non-zero totals" do
      expect do
        described_class.generate({ a: Money.new(1, "USD"), b: Money.new(-1, "EUR") })
      end.to raise_error(ArgumentError, /same currency/)

      expect do
        described_class.generate({ a: 1, b: -2 }, currency: "USD")
      end.to raise_error(ArgumentError, /sum to zero/)
    end

    it "exhaustively matches an independent minimum over small balance spaces" do
      value_space = [-2, -1, 0, 1, 2]

      (2..5).each do |size|
        value_space.repeated_permutation(size) do |values|
          next unless values.sum.zero?
          next unless values.any?(&:nonzero?)

          balances = Array.new(size) { |index| [:"p#{index}", values[index]] }.to_h
          result = described_class.generate(balances, currency: "USD")

          expect(result.transfers.size).to eq(brute_force_optimal_count(balances))
          expect(result).to be_optimal
          assert_reproduces_input(result, balances)
        end
      end
    end
  end

  describe "Money.settle_balances" do
    it "is the public exact settlement entry point" do
      result = Money.settle_balances(
        { a: -6, b: -5, c: 2, d: 4, e: 5 },
        currency: "USD",
      )

      expect(result).to be_a(described_class::Result)
      expect(result.transfers.size).to eq(3)
    end
  end
end
