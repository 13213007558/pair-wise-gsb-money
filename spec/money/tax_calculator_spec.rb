# frozen_string_literal: true

RSpec.describe Money::TaxCalculator do
  def tax(name, rate:, base: :net, rounding_step: 1, rounding_mode: BigDecimal::ROUND_HALF_UP)
    {
      name: name,
      rate: BigDecimal(rate),
      base: base,
      rounding_step: rounding_step,
      rounding_mode: rounding_mode,
    }
  end

  def calculator(taxes, cash_rounding_step: 1, cash_rounding_mode: BigDecimal::ROUND_HALF_UP)
    described_class.new(
      taxes,
      cash_rounding_step: cash_rounding_step,
      cash_rounding_mode: cash_rounding_mode,
    )
  end

  describe "#calculate" do
    it "calculates taxes in dependency order while retaining configured result order" do
      vat = tax(:vat, rate: "0.1", base: [:net, :excise])
      excise = tax(:excise, rate: "0.05")
      result = calculator([vat, excise]).calculate(Money.new(1000, "USD"))

      expect(result.net).to eq(Money.new(1000, "USD"))
      expect(result.taxes.map(&:name)).to eq([:vat, :excise])
      expect(result.taxes.to_h { |item| [item.name, item] }).to match(
        vat: have_attributes(
          base: Money.new(1050, "USD"),
          unrounded_amount: Rational("105/100"),
          amount: Money.new(105, "USD"),
        ),
        excise: have_attributes(
          base: Money.new(1000, "USD"),
          unrounded_amount: Rational("50/100"),
          amount: Money.new(50, "USD"),
        ),
      )
      expect(result.tax_total).to eq(Money.new(155, "USD"))
      expect(result.gross).to eq(Money.new(1155, "USD"))
      expect(result.cash_total).to eq(Money.new(1155, "USD"))
    end

    it "rounds each tax before later taxes use it and retains the pre-round amount" do
      vat = tax(:vat, rate: "0.1", base: [:net, :excise])
      excise = tax(:excise, rate: "0.05")
      result = calculator([vat, excise]).calculate(Money.new(999, "USD"))

      excise_amount = result.taxes.find { |item| item.name == :excise }
      vat_amount = result.taxes.find { |item| item.name == :vat }

      expect(excise_amount.unrounded_amount).to eq(Rational("4995/10000"))
      expect(excise_amount.amount).to eq(Money.new(50, "USD"))
      expect(vat_amount.base).to eq(Money.new(1049, "USD"))
      expect(vat_amount.unrounded_amount).to eq(Rational("1049/1000"))
      expect(vat_amount.amount).to eq(Money.new(105, "USD"))
      expect(result.gross).to eq(Money.new(1154, "USD"))
    end

    it "applies the configured cash rounding step to the final total" do
      sales_tax = tax(:sales, rate: "0.07")
      result = calculator([sales_tax], cash_rounding_step: 5).calculate(Money.new(100, "USD"))

      expect(result.tax_total).to eq(Money.new(7, "USD"))
      expect(result.gross).to eq(Money.new(107, "USD"))
      expect(result.cash_total).to eq(Money.new(105, "USD"))
    end

    it "rounds an individual tax with its own monetary step" do
      sales_tax = tax(:sales, rate: "0.1", rounding_step: 2)
      result = calculator([sales_tax]).calculate(Money.new(101, "USD"))

      expect(result.taxes.first.unrounded_amount).to eq(Rational("101/1000"))
      expect(result.taxes.first.amount).to eq(Money.new(10, "USD"))
      expect(result.gross).to eq(Money.new(111, "USD"))
    end

    it "supports repeated base dependencies" do
      sales_tax = tax(:sales, rate: "0.05", base: [:net, :net])
      result = calculator([sales_tax]).calculate(Money.new(100, "USD"))

      expect(result.taxes.first.base).to eq(Money.new(200, "USD"))
      expect(result.taxes.first.amount).to eq(Money.new(10, "USD"))
    end

    it "supports a zero net amount" do
      result = calculator([tax(:sales, rate: "0.07")]).calculate(Money.new(0, "USD"))

      expect(result.net).to eq(Money.new(0, "USD"))
      expect(result.taxes.first.base).to eq(Money.new(0, "USD"))
      expect(result.taxes.first.unrounded_amount).to eq(0)
      expect(result.taxes.first.amount).to eq(Money.new(0, "USD"))
      expect(result.tax_total).to eq(Money.new(0, "USD"))
      expect(result.gross).to eq(Money.new(0, "USD"))
      expect(result.cash_total).to eq(Money.new(0, "USD"))
    end

    it "supports negative reversal amounts with the configured rounding modes" do
      sales_tax = tax(:sales, rate: "0.07")
      result = calculator([sales_tax], cash_rounding_step: 5).calculate(Money.new(-100, "USD"))

      expect(result.tax_total).to eq(Money.new(-7, "USD"))
      expect(result.gross).to eq(Money.new(-107, "USD"))
      expect(result.cash_total).to eq(Money.new(-105, "USD"))
    end
  end

  describe "#reverse" do
    it "returns every minimum-denomination net amount matching a cash total" do
      sales_tax = tax(:sales, rate: "0.07")
      results = calculator([sales_tax], cash_rounding_step: 5).reverse(Money.new(105, "USD"))

      expect(results.map { |result| result.net.fractional }).to eq([96, 97, 98, 99, 100])
      expect(results.map(&:cash_total).uniq).to eq([Money.new(105, "USD")])
      expect(results.first.taxes.first).to have_attributes(
        base: Money.new(96, "USD"),
        unrounded_amount: Rational("672/10000"),
        amount: Money.new(7, "USD"),
      )
    end

    it "returns an empty array when no minimum-denomination amount matches" do
      results = calculator(
        [tax(:sales, rate: "0.07")],
        cash_rounding_step: 5,
      ).reverse(Money.new(102, "USD"))

      expect(results).to eq([])
    end

    it "does not lose solutions when several zero-rated taxes round to zero" do
      results = calculator(
        [
          tax(:first, rate: "0"),
          tax(:second, rate: "0", base: [:net, :first]),
        ],
        cash_rounding_step: 1,
      ).reverse(Money.new(100, "USD"))

      expect(results.map { |result| result.net.fractional }).to eq([100])
    end

    it "reverses negative totals" do
      results = calculator(
        [tax(:sales, rate: "0.07")],
        cash_rounding_step: 5,
      ).reverse(Money.new(-105, "USD"))

      expect(results.map { |result| result.net.fractional }).to eq([-100, -99, -98, -97, -96])
      expect(results.map(&:cash_total).uniq).to eq([Money.new(-105, "USD")])
    end
  end

  describe "validation" do
    it "raises before calculation when tax dependencies form a cycle" do
      taxes = [
        tax(:first, rate: "0.1", base: :second),
        tax(:second, rate: "0.1", base: :first),
      ]

      expect { calculator(taxes) }.to raise_error(
        described_class::CircularTaxDependency,
        "circular tax dependency: first -> second -> first",
      )
    end

    it "rejects an unknown tax base dependency" do
      expect { calculator([tax(:sales, rate: "0.1", base: :missing)]) }.to raise_error(
        ArgumentError,
        /unknown/,
      )
    end

    it "rejects a negative tax rate" do
      expect { calculator([tax(:sales, rate: "-0.1")]) }.to raise_error(
        ArgumentError,
        "tax :sales must have a finite non-negative Numeric :rate",
      )
    end

    it "rejects a non-finite or non-comparable tax rate" do
      sales_tax = { name: :sales, rate: Complex(0, 1), rounding_mode: BigDecimal::ROUND_HALF_UP }

      expect { calculator([sales_tax]) }.to raise_error(
        ArgumentError,
        "tax :sales must have a finite non-negative Numeric :rate",
      )
    end

    it "rejects a non-cash-step total without accepting an unrounded Money amount" do
      expect do
        calculator([tax(:sales, rate: "0.1")]).reverse(100)
      end.to raise_error(ArgumentError, "total must be a Money object")
    end
  end
end
