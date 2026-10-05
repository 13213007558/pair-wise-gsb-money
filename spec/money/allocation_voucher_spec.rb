# frozen_string_literal: true

require "json"

RSpec.describe Money::Allocation::Voucher do
  subject(:voucher) { described_class.new(splits) }

  let(:splits) { [34, 33, 33] }

  describe ".new" do
    it "records the original allocation and defaults to the natural release order" do
      expect(voucher.splits).to eq([34, 33, 33])
      expect(voucher.release_order).to eq([0, 1, 2])
      expect(voucher.total).to eq(100)
      expect(voucher.refunded).to eq(0)
      expect(voucher.remaining).to eq(100)
      expect(voucher.refunded_splits).to eq([0, 0, 0])
      expect(voucher.remaining_splits).to eq([34, 33, 33])
    end

    it "accepts an explicit release order" do
      voucher = described_class.new(splits, release_order: [2, 0, 1])
      expect(voucher.release_order).to eq([2, 0, 1])
    end

    it "rejects invalid splits" do
      expect { described_class.new([]) }.to raise_error(ArgumentError)
      expect { described_class.new([10, -1]) }.to raise_error(ArgumentError)
      expect { described_class.new([10, 0.5]) }.to raise_error(ArgumentError)
      expect { described_class.new(nil) }.to raise_error(ArgumentError)
    end

    it "rejects a release order that is not a permutation of the party indexes" do
      expect { described_class.new(splits, release_order: [0, 1]) }.to raise_error(ArgumentError)
      expect { described_class.new(splits, release_order: [0, 1, 1]) }.to raise_error(ArgumentError)
      expect { described_class.new(splits, release_order: [0, 1, 3]) }.to raise_error(ArgumentError)
    end
  end

  describe "#refund" do
    it "returns the per-party amounts of this refund and tracks the cumulative ones" do
      expect(voucher.refund(50, id: "refund-1")).to eq([17, 16, 17])
      expect(voucher.refunded).to eq(50)
      expect(voucher.refunded_splits).to eq([17, 16, 17])
      expect(voucher.remaining_splits).to eq([17, 17, 16])

      expect(voucher.refund(50, id: "refund-2")).to eq([17, 17, 16])
      expect(voucher.refunded_splits).to eq([34, 33, 33])
      expect(voucher.remaining_splits).to eq([0, 0, 0])
    end

    it "never lets the last pennies land on a different party than the original split" do
      voucher.refund(99, id: "refund-1")
      expect(voucher.refund(1, id: "refund-2")).to eq([1, 0, 0])
      expect(voucher.refunded_splits).to eq(splits)
    end

    it "gives the same cumulative distribution for the same cumulative refund, regardless of call order" do
      sequences = [[100], [50, 50], [30, 70], [70, 30], [25, 25, 25, 25], [1] * 100]

      final_states = sequences.map do |amounts|
        splits_voucher = described_class.new(splits)
        amounts.each_with_index { |amount, index| splits_voucher.refund(amount, id: "refund-#{index}") }
        splits_voucher.refunded_splits
      end

      expect(final_states.uniq.size).to eq(1)
      expect(final_states.first).to eq(splits)
    end

    it "releases units according to the agreed release order" do
      natural = described_class.new([1, 1], release_order: [0, 1])
      reversed = described_class.new([1, 1], release_order: [1, 0])

      expect(natural.refund(1, id: "refund")).to eq([0, 1])
      expect(reversed.refund(1, id: "refund")).to eq([1, 0])

      natural.refund(1, id: "rest")
      reversed.refund(1, id: "rest")
      expect(natural.refunded_splits).to eq([1, 1])
      expect(reversed.refunded_splits).to eq([1, 1])
    end

    it "does not deduct a duplicate refund id twice" do
      voucher.refund(10, id: "refund-1")

      expect { voucher.refund(10, id: "refund-1") }
        .to raise_error(described_class::DuplicateRefundError)
      expect(voucher.refunded).to eq(10)
      expect(voucher.refund_ids).to eq(["refund-1"])
    end

    it "rejects an over-amount refund without leaving a partial modification" do
      voucher.refund(90, id: "refund-1")
      refunded_splits = voucher.refunded_splits

      expect { voucher.refund(11, id: "refund-2") }
        .to raise_error(described_class::RefundExceedsTotalError)
      expect(voucher.refunded).to eq(90)
      expect(voucher.refund_ids).to eq(["refund-1"])
      expect(voucher.refunded_splits).to eq(refunded_splits)
    end

    it "rejects non-integer or negative amounts" do
      expect { voucher.refund(1.5, id: "refund-1") }.to raise_error(ArgumentError)
      expect { voucher.refund(-1, id: "refund-1") }.to raise_error(ArgumentError)
      expect(voucher.refunded).to eq(0)
    end

    it "handles a zero total voucher" do
      voucher = described_class.new([0, 0])
      expect(voucher.refund(0, id: "refund-1")).to eq([0, 0])
      expect { voucher.refund(1, id: "refund-2") }
        .to raise_error(described_class::RefundExceedsTotalError)
    end
  end

  describe "serialization" do
    before { voucher.refund(40, id: "refund-1") }

    it "survives a Marshal round trip and keeps deducting consistently" do
      restored = Marshal.load(Marshal.dump(voucher))

      expect(restored).to eq(voucher)
      expect(restored.refund(60, id: "refund-2")).to eq(voucher.refund(60, id: "refund-2"))
      expect(restored.refunded_splits).to eq(splits)
    end

    it "round-trips through to_h/from_h including seen refund ids" do
      restored = described_class.from_h(voucher.to_h)

      expect(restored).to eq(voucher)
      expect { restored.refund(1, id: "refund-1") }
        .to raise_error(described_class::DuplicateRefundError)
    end

    it "round-trips through JSON" do
      restored = described_class.from_h(JSON.parse(JSON.generate(voucher.to_h)))

      expect(restored).to eq(voucher)
    end

    it "rejects a serialized state with an out-of-range refunded amount" do
      expect { described_class.from_h(voucher.to_h.merge(refunded: 101)) }
        .to raise_error(ArgumentError)
    end
  end

  describe "arbitrary refund sequences compared to a one-shot full refund" do
    def random_refund_sequence(total, random)
      amounts = []
      remaining = total
      until remaining.zero?
        amount = random.rand(1..remaining)
        amounts << amount
        remaining -= amount
      end
      amounts
    end

    it "matches the one-shot distribution at every cumulative total and ends on the original splits" do
      random = Random.new(2026)

      [[100, 3], [5, 2], [2, 3], [100, 6], [10_001, 4], [3, 5]].each do |total, part_count|
        splits = Money::Allocation.generate(total, part_count)

        one_shot = described_class.new(splits)
        expect(one_shot.refund(total, id: "all")).to eq(splits)

        5.times do
          voucher = described_class.new(splits)
          cumulative = 0

          random_refund_sequence(total, random).each_with_index do |amount, index|
            delta = voucher.refund(amount, id: "refund-#{index}")
            cumulative += amount

            expect(delta.sum).to eq(amount)
            expect(delta).to all(be >= 0)

            probe = described_class.new(splits)
            probe.refund(cumulative, id: "probe")
            expect(voucher.refunded_splits).to eq(probe.refunded_splits)
          end

          expect(voucher.refunded_splits).to eq(splits)
          expect(voucher.remaining_splits).to eq(Array.new(part_count, 0))
        end
      end
    end
  end

  describe "integration with Money#allocate" do
    it "refunds a Money allocation down to the exact original splits" do
      money = Money.new(100, "USD")
      voucher = described_class.new(money.allocate(3).map(&:fractional))

      voucher.refund(60, id: "refund-1")
      voucher.refund(40, id: "refund-2")

      expect(voucher.refunded_splits).to eq([34, 33, 33])
    end
  end
end

RSpec.describe Money::Allocation::Voucher do
  describe "unit release schedule" do
    # Reference implementation: materialize every smallest unit with its
    # release priority (split/k, ties broken by the release order) and count
    # how many units of each party are released among the first R units.
    def brute_force_refunded_splits(splits, release_order, refunded)
      position = release_order.each_with_index.to_h
      units = []
      splits.each_with_index do |split, party|
        (1..split).each { |k| units << [party, Rational(split, k)] }
      end
      units.sort_by! { |party, priority| [-priority, -position[party]] }

      result = Array.new(splits.size, 0)
      units.first(refunded).each { |party, _| result[party] += 1 }
      result
    end

    it "matches the explicit unit release order at every cumulative total" do
      [[5, 2], [2, 3], [100, 6], [7, 4], [1, 1]].each do |total, part_count|
        splits = Money::Allocation.generate(total, part_count)
        release_orders = [(0...part_count).to_a, (0...part_count).to_a.reverse]

        release_orders.each do |release_order|
          voucher = described_class.new(splits, release_order: release_order)

          (0..total).each do |refunded|
            probe = described_class.new(splits, release_order: release_order)
            probe.refund(refunded, id: "probe")
            expect(probe.refunded_splits).to(
              eq(brute_force_refunded_splits(splits, release_order, refunded)),
              "splits=#{splits} release_order=#{release_order} refunded=#{refunded}",
            )
          end

          expect(voucher.refunded_splits).to eq(Array.new(part_count, 0))
        end
      end
    end

    it "never decreases a party's cumulative refund as the cumulative total grows" do
      [[100, 3], [100, 6], [50, 4], [10_001, 4]].each do |total, part_count|
        splits = Money::Allocation.generate(total, part_count)
        voucher = described_class.new(splits)
        previous = voucher.refunded_splits

        total.times do |index|
          voucher.refund(1, id: "unit-#{index}")
          current = voucher.refunded_splits
          current.zip(previous).each do |now, before|
            expect(now).to be >= before
          end
          previous = current
        end

        expect(voucher.refunded_splits).to eq(splits)
      end
    end
  end
end
