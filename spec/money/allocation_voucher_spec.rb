# frozen_string_literal: true

require "json"

RSpec.describe Money::AllocationVoucher do
  subject(:voucher) { described_class.new(Money.new(100, "USD"), [1, 1, 1]) }

  def cents(monies)
    monies.map { |money| money.fractional.to_i }
  end

  describe "#initialize" do
    it "records the original allocation like Money#allocate" do
      expect(voucher.allocations).to eq(Money.new(100, "USD").allocate([1, 1, 1]))
      expect(voucher.allocations).to eq([Money.new(34, "USD"), Money.new(33, "USD"), Money.new(33, "USD")])
    end

    it "accepts a number of parties" do
      expect(described_class.new(Money.new(100, "USD"), 2).allocations)
        .to eq([Money.new(50, "USD"), Money.new(50, "USD")])
    end

    it "starts with nothing refunded" do
      expect(voucher.refunded).to eq([Money.new(0, "USD")] * 3)
      expect(voucher.refunded_total).to eq(Money.new(0, "USD"))
      expect(voucher.outstanding).to eq(voucher.allocations)
      expect(voucher.outstanding_total).to eq(voucher.total)
      expect(voucher).not_to be_fully_refunded
    end

    it "rejects amounts that are not whole minimal units", :default_infinite_precision_true do
      expect { described_class.new(Money.new(BigDecimal("10.5"), "USD"), 2) }
        .to raise_error(ArgumentError, /whole number/)
    end

    it "rejects negative amounts" do
      expect { described_class.new(Money.new(-1, "USD"), 2) }
        .to raise_error(ArgumentError, /negative/)
    end

    it "rejects empty parts" do
      expect { described_class.new(Money.new(100, "USD"), []) }
        .to raise_error(ArgumentError)
    end
  end

  describe "#refund" do
    it "returns the per-party amounts of this refund and the cumulative refunds" do
      result = voucher.refund(Money.new(1, "USD"), id: "r-1")

      expect(result.id).to eq("r-1")
      expect(result).not_to be_duplicate
      expect(result.current).to eq([Money.new(1, "USD"), Money.new(0, "USD"), Money.new(0, "USD")])
      expect(result.cumulative).to eq(result.current)
      expect(voucher.refunded).to eq(result.cumulative)
      expect(voucher.refunded_total).to eq(Money.new(1, "USD"))
    end

    it "accumulates refunds so that the currents sum up to the cumulative refunds" do
      currents = []
      [30, 20, 50].each_with_index do |amount, index|
        currents << voucher.refund(Money.new(amount, "USD"), id: "r-#{index}").current
      end

      summed = currents.transpose.map { |parts| parts.sum }
      expect(summed).to eq(voucher.refunded)
      expect(voucher.refunded).to eq(voucher.allocations)
      expect(voucher).to be_fully_refunded
    end

    it "claws back the units that the allocation handed out last" do
      # 100 split [1, 1, 1] gives [34, 33, 33]; the extra penny of party 0 is
      # released first, then the round-robin order reverses.
      expect(voucher.refund(Money.new(1, "USD"), id: "r-1").current)
        .to eq([Money.new(1, "USD"), Money.new(0, "USD"), Money.new(0, "USD")])
      expect(voucher.refund(Money.new(1, "USD"), id: "r-2").current)
        .to eq([Money.new(0, "USD"), Money.new(0, "USD"), Money.new(1, "USD")])
      expect(voucher.refund(Money.new(1, "USD"), id: "r-3").current)
        .to eq([Money.new(0, "USD"), Money.new(1, "USD"), Money.new(0, "USD")])
    end

    it "does not deduct a repeated refund id a second time" do
      first = voucher.refund(Money.new(10, "USD"), id: "r-1")
      duplicate = voucher.refund(Money.new(10, "USD"), id: "r-1")

      expect(duplicate).to be_duplicate
      expect(duplicate.current).to eq([Money.new(0, "USD")] * 3)
      expect(duplicate.cumulative).to eq(first.cumulative)
      expect(voucher.refunded_total).to eq(Money.new(10, "USD"))
      expect(voucher.refund_ids).to eq(["r-1"])
    end

    it "treats ids of different types with the same string form as identical" do
      voucher.refund(Money.new(10, "USD"), id: :"r-1")
      expect(voucher.refund(Money.new(10, "USD"), id: "r-1")).to be_duplicate
    end

    it "rejects refunds exceeding the remaining total without changing any state" do
      voucher.refund(Money.new(60, "USD"), id: "r-1")

      expect { voucher.refund(Money.new(41, "USD"), id: "r-2") }
        .to raise_error(Money::AllocationVoucher::RefundExceedsTotalError)

      expect(voucher.refunded_total).to eq(Money.new(60, "USD"))
      expect(voucher.refund_ids).to eq(["r-1"])
      expect(voucher.refund(Money.new(40, "USD"), id: "r-2").cumulative)
        .to eq(voucher.allocations)
    end

    it "requires a refund id" do
      expect { voucher.refund(Money.new(1, "USD"), id: nil) }
        .to raise_error(ArgumentError, /id/)
    end

    it "rejects non-Money amounts" do
      expect { voucher.refund(10, id: "r-1") }.to raise_error(ArgumentError, /Money/)
    end

    it "rejects amounts in another currency" do
      expect { voucher.refund(Money.new(10, "EUR"), id: "r-1") }
        .to raise_error(ArgumentError, /currency/)
    end

    it "rejects non-positive refunds" do
      expect { voucher.refund(Money.new(0, "USD"), id: "r-1") }
        .to raise_error(ArgumentError, /positive/)
      expect { voucher.refund(Money.new(-5, "USD"), id: "r-1") }
        .to raise_error(ArgumentError, /positive/)
    end

    it "rejects fractional refunds", :default_infinite_precision_true do
      expect { voucher.refund(Money.new(BigDecimal("1.5"), "USD"), id: "r-1") }
        .to raise_error(ArgumentError, /whole number/)
    end
  end

  describe "cumulative consistency" do
    it "gives the same cumulative refunds regardless of refund order" do
      amounts = [10, 25, 5, 60]
      orders = [amounts, amounts.reverse, amounts.shuffle(random: Random.new(42))]

      results = orders.map do |sequence|
        other = described_class.new(Money.new(100, "USD"), [1, 1, 1])
        sequence.each_with_index { |amount, i| other.refund(Money.new(amount, "USD"), id: "r-#{i}") }
        other.refunded
      end

      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq([Money.new(34, "USD"), Money.new(33, "USD"), Money.new(33, "USD")])
    end

    it "matches a single refund of the same cumulative amount" do
      one_shot = described_class.new(Money.new(100, "USD"), [3, 7])
      one_shot.refund(Money.new(42, "USD"), id: "all")

      instalments = described_class.new(Money.new(100, "USD"), [3, 7])
      [1, 2, 3, 5, 8, 13, 10].each_with_index do |amount, i|
        instalments.refund(Money.new(amount, "USD"), id: "r-#{i}")
      end

      expect(instalments.refunded).to eq(one_shot.refunded)
    end

    it "matches a one-shot full refund for arbitrary split sequences" do
      rng = Random.new(20261005)

      [[1, 1, 1], [3, 7], [2, 3, 5], 4].each do |parts|
        total = 1_000
        reference = described_class.new(Money.new(total, "USD"), parts)
        reference.refund(Money.new(total, "USD"), id: "full")

        10.times do
          split = described_class.new(Money.new(total, "USD"), parts)
          remaining = total
          index = 0

          while remaining.positive?
            amount = rng.rand(1..remaining)
            split.refund(Money.new(amount, "USD"), id: "r-#{index}")
            remaining -= amount
            index += 1
          end

          expect(split.refunded).to eq(reference.refunded)
          expect(split.refunded).to eq(split.allocations)
          expect(split).to be_fully_refunded
        end
      end
    end

    it "matches a one-shot partial refund for arbitrary split sequences" do
      rng = Random.new(42)

      20.times do
        total = rng.rand(1..500)
        parts = Array.new(rng.rand(2..5)) { rng.rand(1..9) }
        refund_total = rng.rand(1..total)

        one_shot = described_class.new(Money.new(total, "USD"), parts)
        one_shot.refund(Money.new(refund_total, "USD"), id: "one")

        split = described_class.new(Money.new(total, "USD"), parts)
        remaining = refund_total
        index = 0
        while remaining.positive?
          amount = rng.rand(1..remaining)
          split.refund(Money.new(amount, "USD"), id: "r-#{index}")
          remaining -= amount
          index += 1
        end

        expect(split.refunded).to eq(one_shot.refunded)
        expect(split.outstanding).to eq(one_shot.outstanding)
      end
    end
  end

  describe "#release_order" do
    it "contains one party index per minimal unit of the total" do
      order = voucher.release_order
      expect(order.size).to eq(100)
      expect(order.tally).to eq(0 => 34, 1 => 33, 2 => 33)
    end

    it "matches the cumulative refunds of every prefix" do
      order = voucher.release_order
      other = described_class.new(Money.new(100, "USD"), [1, 1, 1])

      (1..100).each do |count|
        other.refund(Money.new(1, "USD"), id: "r-#{count}")
        expected = [0, 0, 0]
        order.first(count).each { |party| expected[party] += 1 }
        expect(cents(other.refunded)).to eq(expected)
      end
    end
  end

  describe "serialization" do
    it "round-trips through a hash and keeps deducting consistently" do
      voucher.refund(Money.new(30, "USD"), id: "r-1")
      restored = described_class.from_h(voucher.to_h)

      expect(restored.to_h).to eq(voucher.to_h)
      expect(restored.allocations).to eq(voucher.allocations)
      expect(restored.refunded).to eq(voucher.refunded)
      expect(restored.refund(Money.new(30, "USD"), id: "r-1")).to be_duplicate
      expect(restored.refund(Money.new(70, "USD"), id: "r-2").cumulative)
        .to eq(voucher.allocations)
    end

    it "round-trips through JSON" do
      voucher.refund(Money.new(30, "USD"), id: "r-1")
      restored = described_class.from_h(JSON.parse(JSON.generate(voucher.to_h)))

      expect(restored.to_h).to eq(voucher.to_h)
      expect(restored.refunded).to eq(voucher.refunded)
    end

    it "serializes proportional parts" do
      voucher = described_class.new(Money.new(101, "USD"), [3, 7])
      voucher.refund(Money.new(1, "USD"), id: "r-1")
      restored = described_class.from_h(JSON.parse(JSON.generate(voucher.to_h)))

      expect(restored.parts).to eq([3, 7])
      expect(restored.refund(Money.new(100, "USD"), id: "r-2").cumulative)
        .to eq(voucher.allocations)
    end

    it "serializes BigDecimal and Rational parts" do
      voucher = described_class.new(Money.new(100, "USD"), [BigDecimal("1.5"), Rational(1, 2)])
      voucher.refund(Money.new(25, "USD"), id: "r-1")
      restored = described_class.from_h(JSON.parse(JSON.generate(voucher.to_h)))

      expect(restored.parts).to eq([BigDecimal("1.5"), Rational(1, 2)])
      expect(restored.refund(Money.new(75, "USD"), id: "r-2").cumulative)
        .to eq(voucher.allocations)
    end

    it "rejects inconsistent serialized state" do
      expect { described_class.from_h(voucher.to_h.merge("refunded" => "101")) }
        .to raise_error(ArgumentError, /out of range/)
      expect { described_class.from_h(voucher.to_h.merge("refund_ids" => %w[a a])) }
        .to raise_error(ArgumentError, /unique/)
    end
  end

  describe "Money#allocation_voucher" do
    it "builds a voucher for the money amount" do
      voucher = Money.new(5, "USD").allocation_voucher([3, 7])
      expect(voucher).to be_a(described_class)
      expect(voucher.allocations).to eq([Money.new(2, "USD"), Money.new(3, "USD")])
    end
  end
end
