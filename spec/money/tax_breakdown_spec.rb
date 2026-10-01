# frozen_string_literal: true

RSpec.describe Money::TaxBreakdown do
  describe ".find" do
    it "reconstructs nested taxes in their dependency order" do
      taxes = [
        {
          name: :primary,
          rate: Rational(1, 10),
          base: :net,
        },
        {
          name: :secondary,
          rate: BigDecimal("0.1"),
          base: [:net, :primary],
        },
      ]

      result = described_class.find(121, taxes)

      expect(result).to have_attributes(
        net_amount: 100,
        tax_amounts: { primary: 10, secondary: 11 },
        total: 121,
      )
      expect(result.to_h).to eq(
        net_amount: 100,
        tax_amounts: { primary: 10, secondary: 11 },
        total: 121,
      )
    end

    it "keeps taxes in declaration order regardless of dependency declaration order" do
      taxes = [
        {
          name: :secondary,
          rate: Rational(1, 10),
          base: [:net, :primary],
        },
        {
          name: :primary,
          rate: Rational(1, 10),
          base: :net,
        },
      ]

      result = described_class.find(121, taxes)

      expect(result.tax_amounts.keys).to eq(%i[secondary primary])
      expect(result.tax_amounts).to eq(secondary: 11, primary: 10)
    end

    it "accepts a zero total and zero rates" do
      taxes = [
        { name: :a, rate: 0, base: :net },
        { name: :b, rate: BigDecimal("0"), base: [:net, :a] },
      ]

      result = described_class.find(0, taxes)

      expect(result.to_h).to eq(
        net_amount: 0,
        tax_amounts: { a: 0, b: 0 },
        total: 0,
      )
    end

    it "supports taxes that do not depend on net" do
      taxes = [
        { name: :a, rate: Rational(1, 2), base: :net },
        { name: :b, rate: Rational(1, 2), base: :a },
      ]

      result = described_class.find(21, taxes)

      expect(result.to_h).to eq(
        net_amount: 12,
        tax_amounts: { a: 6, b: 3 },
        total: 21,
      )
    end

    it "applies each configured per-tax rounding mode" do
      taxes = [
        { name: :down, rate: Rational(1, 3), base: :net, rounding: :down },
        { name: :up, rate: Rational(1, 3), base: :net, rounding: :up },
        { name: :half_down, rate: Rational(1, 2), base: :net, rounding: :half_down },
        { name: :half_even, rate: Rational(3, 2), base: :net, rounding: :half_even },
      ]

      result = described_class.calculate(3, taxes)

      expect(result.tax_amounts).to eq(
        down: 1,
        up: 1,
        half_down: 1,
        half_even: 4,
      )
    end

    it "accepts BigDecimal rounding constants" do
      tax = { name: :tax, rate: Rational(1, 3), rounding: BigDecimal::ROUND_CEILING }

      result = described_class.calculate(1, [tax])

      expect(result.tax_amounts).to eq(tax: 1)
    end

    it "returns nil when item-by-item rounding leaves no integer net amount" do
      taxes = [
        { name: :primary, rate: Rational(1, 10), base: :net },
        { name: :secondary, rate: Rational(1, 10), base: [:net, :primary] },
      ]

      expect(described_class.calculate(4, taxes).total).to eq(4)
      expect(described_class.calculate(5, taxes).total).to eq(7)
      expect(described_class.find(5, taxes)).to be_nil
      expect(described_class.find(6, taxes)).to be_nil
    end

    it "matches every reachable small total and rejects every skipped total" do
      taxes = [
        { name: :primary, rate: Rational(1, 10), base: :net },
        { name: :secondary, rate: Rational(1, 10), base: [:net, :primary] },
      ]
      forward_totals = (0..99).map { |net_amount| described_class.calculate(net_amount, taxes).total }

      (0..forward_totals.max).each do |total|
        result = described_class.find(total, taxes)
        net_amounts = forward_totals.each_index.select { |index| forward_totals[index] == total }

        if net_amounts.empty?
          expect(result).to be_nil
        else
          expect(net_amounts).to contain_exactly(result.net_amount)
          expect(result.total).to eq(total)
          expect(described_class.calculate(result.net_amount, taxes)).to eq(result)
        end
      end
    end

    it "rejects Float rates" do
      taxes = [{ name: :tax, rate: 0.1 }]

      expect { described_class.find(101, taxes) }.to raise_error(
        ArgumentError,
        "Float rates are not exact; use Rational or BigDecimal",
      )
    end

    it "rejects negative amounts and rates" do
      expect { described_class.find(-1, []) }.to raise_error(ArgumentError)
      expect { described_class.calculate(-1, []) }.to raise_error(ArgumentError)
      expect do
        described_class.find(1, [{ name: :tax, rate: Rational(-1, 10) }])
      end.to raise_error(ArgumentError, "rate must be finite and non-negative")
    end

    it "rejects cyclic dependencies" do
      taxes = [
        { name: :a, rate: 0, base: :b },
        { name: :b, rate: 0, base: :a },
      ]

      expect { described_class.find(1, taxes) }.to raise_error(
        ArgumentError,
        "tax dependencies must be acyclic",
      )
    end

    it "rejects unknown, reserved, duplicate, and duplicated tax-base dependencies" do
      expect do
        described_class.find(1, [{ name: :tax, rate: 0, base: :missing }])
      end.to raise_error(ArgumentError, "unknown tax-base dependency: :missing")

      expect do
        described_class.find(1, [{ name: :net, rate: 0 }])
      end.to raise_error(ArgumentError, 'duplicate tax name: :net')

      expect do
        described_class.find(1, [
          { name: :tax, rate: 0 },
          { name: :tax, rate: 0 },
        ])
      end.to raise_error(ArgumentError, "duplicate tax name: :tax")

      expect do
        described_class.find(1, [
          { name: :tax, rate: 0, base: [:net, :net] },
        ])
      end.to raise_error(ArgumentError, "tax-base dependencies cannot be duplicated")
    end

    it "rejects unsupported rounding modes" do
      expect do
        described_class.find(1, [], rounding: :mystery)
      end.to raise_error(ArgumentError, "unsupported rounding mode: :mystery")
    end
  end
end
