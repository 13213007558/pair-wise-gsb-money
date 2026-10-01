# frozen_string_literal: true

RSpec.describe Money::TaxDecomposition do
  let(:gst) { { name: :gst, rate: Rational(5, 100), base: [:net], rounding: :half_up } }
  let(:qst) { { name: :qst, rate: Rational(9975, 100_000), base: [:net, :gst], rounding: :half_up } }

  describe ".decompose" do
    it "decomposes a total with a single tax on the net amount" do
      result = described_class.decompose(105, [gst])

      expect(result.net).to eq(100)
      expect(result.taxes).to eq(gst: 5)
      expect(result.total).to eq(105)
    end

    it "decomposes a total where one tax applies to net + a previous tax" do
      result = described_class.decompose(11_547, [gst, qst])

      expect(result.net).to eq(10_000)
      expect(result.taxes).to eq(gst: 500, qst: 1047)
      expect(result.total).to eq(11_547)
    end

    it "resolves dependencies regardless of the order taxes are given in" do
      result = described_class.decompose(11_547, [qst, gst])

      expect(result.net).to eq(10_000)
      expect(result.taxes).to eq(gst: 500, qst: 1047)
    end

    it "returns the net amount itself when no taxes are given" do
      result = described_class.decompose(42, [])

      expect(result.net).to eq(42)
      expect(result.taxes).to eq({})
    end

    it "handles a zero tax rate" do
      result = described_class.decompose(100, [{ name: :nop, rate: 0, base: [:net] }])

      expect(result.net).to eq(100)
      expect(result.taxes).to eq(nop: 0)
    end

    it "decomposes a zero total" do
      result = described_class.decompose(0, [gst, qst])

      expect(result.net).to eq(0)
      expect(result.taxes).to eq(gst: 0, qst: 0)
    end

    it "never adds a penny adjustment when the total is unreachable" do
      # 10% rounded half_up: net 4 -> 4 + round(0.4) = 4, net 5 -> 5 + round(0.5) = 6.
      # The gross amount 5 is skipped, so there is no exact decomposition.
      tax = [{ name: :vat, rate: Rational(1, 10), base: [:net], rounding: :half_up }]

      expect(described_class.gross_for(4, tax)).to eq(4)
      expect(described_class.gross_for(5, tax)).to eq(6)
      expect(described_class.decompose(5, tax)).to be_nil
    end

    it "raises ArgumentError for a negative total" do
      expect { described_class.decompose(-1, [gst]) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for a non-integer total" do
      expect { described_class.decompose(10.5, [gst]) }.to raise_error(ArgumentError)
    end
  end

  describe "uniqueness and monotonicity" do
    it "round-trips every net amount through its gross total" do
      taxes = [gst, qst]

      (0..1_000).each do |net|
        result = described_class.decompose(described_class.gross_for(net, taxes), taxes)

        expect(result).not_to be_nil
        expect(result.net).to eq(net)
      end
    end

    it "produces strictly increasing gross totals, so solutions are unique" do
      taxes = [gst, qst]
      grosses = (0..500).map { |net| described_class.gross_for(net, taxes) }

      expect(grosses.each_cons(2).all? { |a, b| b > a }).to be(true)
    end
  end

  describe "exhaustive verification against brute force" do
    configurations = {
      "single tax half_up" => [{ name: :a, rate: Rational(1, 10), base: [:net], rounding: :half_up }],
      "single tax down" => [{ name: :a, rate: Rational(7, 100), base: [:net], rounding: :down }],
      "single tax up" => [{ name: :a, rate: Rational(3, 100), base: [:net], rounding: :up }],
      "stacked taxes mixed rounding" => [
        { name: :a, rate: Rational(5, 100), base: [:net], rounding: :half_even },
        { name: :b, rate: Rational(9975, 100_000), base: [:net, :a], rounding: :half_up },
      ],
      "independent taxes on net" => [
        { name: :a, rate: Rational(5, 100), base: [:net], rounding: :half_up },
        { name: :b, rate: Rational(8, 100), base: [:net], rounding: :down },
      ],
    }

    # Reference implementation: scan every candidate net amount.
    def brute_force_decompose(total, taxes)
      (0..total).each do |net|
        return net if described_class.gross_for(net, taxes) == total
      end
      nil
    end

    configurations.each do |label, taxes|
      it "matches brute force for #{label} on all totals in 0..300" do
        (0..300).each do |total|
          result = described_class.decompose(total, taxes)
          expected_net = brute_force_decompose(total, taxes)

          if expected_net.nil?
            expect(result).to be_nil, "expected no solution for total #{total}, got #{result.inspect}"
          else
            expect(result).not_to be_nil, "expected a solution for total #{total}"
            expect(result.net).to eq(expected_net)
            expect(result.net + result.taxes.values.sum).to eq(total)
          end
        end
      end
    end
  end

  describe "tax definitions" do
    it "accepts Tax objects as well as hashes" do
      tax = Money::TaxDecomposition::Tax.new(name: :gst, rate: "0.05", base: [:net], rounding: :half_up)
      result = described_class.decompose(105, [tax])

      expect(result.net).to eq(100)
      expect(result.taxes).to eq(gst: 5)
    end

    it "accepts exact rates as Integer, Rational, String, and BigDecimal" do
      [5, Rational(5, 1), "5", BigDecimal("5")].each do |rate|
        result = described_class.decompose(600, [{ name: :t, rate: rate, base: [:net], rounding: :half_up }])

        expect(result.net).to eq(100)
        expect(result.taxes).to eq(t: 500)
      end
    end

    it "rejects inexact Float rates" do
      expect { described_class.decompose(100, [{ name: :t, rate: 0.05 }]) }.to raise_error(ArgumentError)
    end

    it "rejects negative rates" do
      expect do
        described_class.decompose(100, [{ name: :t, rate: Rational(-1, 10) }])
      end.to raise_error(ArgumentError, /non-negative/)
    end

    it "rejects unknown rounding rules" do
      expect do
        described_class.decompose(100, [{ name: :t, rate: 0, rounding: :bankersish }])
      end.to raise_error(ArgumentError, /rounding/)
    end

    it "rejects duplicate tax names" do
      expect do
        described_class.decompose(100, [gst, gst])
      end.to raise_error(ArgumentError, /duplicate/)
    end

    it "rejects unknown base components" do
      expect do
        described_class.decompose(100, [{ name: :t, rate: 0, base: [:net, :mystery] }])
      end.to raise_error(ArgumentError, /unknown base/)
    end

    it "rejects taxes without any base component" do
      expect do
        described_class.decompose(100, [{ name: :t, rate: 0, base: [] }])
      end.to raise_error(ArgumentError, /base/)
    end
  end

  describe "dependency cycles" do
    it "raises CyclicTaxBaseError for a direct cycle" do
      taxes = [
        { name: :a, rate: 0, base: [:b] },
        { name: :b, rate: 0, base: [:a] },
      ]

      expect { described_class.decompose(100, taxes) }.to raise_error(Money::TaxDecomposition::CyclicTaxBaseError)
    end

    it "raises CyclicTaxBaseError for a self dependency" do
      expect do
        described_class.decompose(100, [{ name: :a, rate: 0, base: [:net, :a] }])
      end.to raise_error(Money::TaxDecomposition::CyclicTaxBaseError)
    end

    it "raises CyclicTaxBaseError for an indirect cycle" do
      taxes = [
        { name: :a, rate: 0, base: [:b] },
        { name: :b, rate: 0, base: [:c] },
        { name: :c, rate: 0, base: [:a] },
      ]

      expect { described_class.decompose(100, taxes) }.to raise_error(Money::TaxDecomposition::CyclicTaxBaseError)
    end
  end

  describe "rounding rules" do
    def gross_for(net, rate, rounding)
      described_class.gross_for(net, [{ name: :t, rate: rate, base: [:net], rounding: rounding }])
    end

    it "rounds half away from zero with :half_up" do
      expect(gross_for(5, Rational(1, 10), :half_up)).to eq(6) # 0.5 -> 1
    end

    it "rounds half towards zero with :half_down" do
      expect(gross_for(5, Rational(1, 10), :half_down)).to eq(5) # 0.5 -> 0
    end

    it "rounds half to even with :half_even" do
      expect(gross_for(1, Rational(1, 2), :half_even)).to eq(1) # 0.5 -> 0
      expect(gross_for(3, Rational(1, 2), :half_even)).to eq(5) # 1.5 -> 2
    end

    it "rounds towards zero with :down" do
      expect(gross_for(9, Rational(1, 10), :down)).to eq(9) # 0.9 -> 0
    end

    it "rounds away from zero with :up" do
      expect(gross_for(1, Rational(1, 100), :up)).to eq(2) # 0.01 -> 1
    end

    it "applies each tax's own rounding rule independently" do
      taxes = [
        { name: :a, rate: Rational(1, 10), base: [:net], rounding: :half_up },
        { name: :b, rate: Rational(1, 10), base: [:net], rounding: :down },
      ]
      result = described_class.decompose(6, taxes)

      expect(result.net).to eq(5)
      expect(result.taxes).to eq(a: 1, b: 0) # 0.5 rounds up for :a, down for :b
    end
  end
end
