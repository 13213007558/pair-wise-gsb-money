# frozen_string_literal: true

RSpec.describe Money::TaxCalculator do
  subject(:calculator) do
    described_class.new(
      currency: "USD",
      taxes: [
        { name: :vat, rate: BigDecimal("0.10") },
        { name: :surtax, rate: Rational(1, 20), base_dependencies: [:vat] },
      ],
      cash_rounding_step: 5,
    )
  end

  describe "#calculate" do
    it "calculates layered taxes from a net amount" do
      result = calculator.calculate(100)

      expect(result.net).to eq Money.new(100, "USD")
      expect(result.tax).to eq Money.new(11, "USD")
      expect(result.subtotal).to eq Money.new(111, "USD")
      expect(result.gross_before_cash_rounding).to eq Money.new(111, "USD")
      expect(result.cash_rounding_adjustment).to eq Money.new(-1, "USD")
      expect(result.gross).to eq Money.new(110, "USD")
    end

    it "preserves every tax base, component, raw amount, and rounding choice" do
      result = calculator.calculate(100)
      vat, surtax = result.tax_lines

      expect(vat.name).to eq(:vat)
      expect(vat.rate).to eq(Rational(1, 10))
      expect(vat.base).to eq Money.new(100, "USD")
      expect(vat.base_components).to eq(net: Money.new(100, "USD"))
      expect(vat.amount_before_rounding).to eq(Rational(1, 10))
      expect(vat.amount).to eq Money.new(10, "USD")
      expect(vat.rounding_mode).to eq(BigDecimal::ROUND_HALF_UP)

      expect(surtax.name).to eq(:surtax)
      expect(surtax.rate).to eq(Rational(1, 20))
      expect(surtax.base).to eq Money.new(10, "USD")
      expect(surtax.base_components).to eq(vat: Money.new(10, "USD"))
      expect(surtax.amount_before_rounding).to eq(Rational(1, 200))
      expect(surtax.amount).to eq Money.new(1, "USD")
    end

    it "supports a tax base that combines net price with a previous tax" do
      compound = described_class.new(
        currency: "USD",
        taxes: [
          { name: :vat, rate: Rational(10, 100) },
          { name: :surtax, rate: Rational(5, 100), base_dependencies: [:net, :vat] },
        ],
      )
      result = compound.calculate(1000)

      expect(result.tax_lines.first.amount).to eq Money.new(100, "USD")
      expect(result.tax_lines.last.base).to eq Money.new(1100, "USD")
      expect(result.tax_lines.last.base_components).to eq(
        net: Money.new(1000, "USD"),
        vat: Money.new(100, "USD"),
      )
      expect(result.tax_lines.last.amount).to eq Money.new(55, "USD")
      expect(result.gross).to eq Money.new(1155, "USD")
    end

    it "allows each tax to declare its own rounding mode" do
      rounding = described_class.new(
        currency: "USD",
        taxes: [
          { name: :up, rate: Rational(2, 3), rounding_mode: :half_up },
          { name: :down, rate: Rational(1, 2), rounding_mode: :half_down },
        ],
      )

      result = rounding.calculate(1)

      expect(result.tax_lines.first.amount).to eq Money.new(1, "USD")
      expect(result.tax_lines.last.amount).to eq Money.new(0, "USD")
    end

    it "uses a separately declared cash rounding mode" do
      cash = described_class.new(
        currency: "USD",
        taxes: [{ name: :none, rate: 0 }],
        cash_rounding_step: 5,
        cash_rounding_mode: :ceiling,
      )
      result = cash.calculate(1)

      expect(result.gross_before_cash_rounding).to eq Money.new(1, "USD")
      expect(result.cash_rounding_adjustment).to eq Money.new(4, "USD")
      expect(result.gross).to eq Money.new(5, "USD")
    end

    it "keeps a zero net amount and zero-rate tax explicit" do
      zero = described_class.new(currency: "USD", taxes: [{ rate: 0 }])
      result = zero.calculate(0)

      expect(result.net).to eq Money.new(0, "USD")
      expect(result.tax_lines.first.base).to eq Money.new(0, "USD")
      expect(result.tax_lines.first.amount_before_rounding).to eq(0)
      expect(result.tax_lines.first.amount).to eq Money.new(0, "USD")
      expect(result.gross).to eq Money.new(0, "USD")
    end

    it "supports negative net amounts as reversals" do
      vat = described_class.new(currency: "USD", taxes: [{ rate: Rational(10, 100) }])
      result = vat.calculate(-100)

      expect(result.tax).to eq Money.new(-10, "USD")
      expect(result.gross).to eq Money.new(-110, "USD")
    end

    it "rounds a negative half-down tie toward zero" do
      half_down = described_class.new(
        currency: "USD",
        taxes: [{ rate: Rational(1, 2), rounding_mode: :half_down }],
      )

      expect(half_down.calculate(-1).tax).to eq Money.new(0, "USD")
    end

    it "rounds negative half-up and half-even ties according to their mode" do
      half_up = described_class.new(
        currency: "USD",
        taxes: [{ rate: Rational(1, 2), rounding_mode: :half_up }],
      )
      half_even = described_class.new(
        currency: "USD",
        taxes: [{ rate: Rational(1, 2), rounding_mode: :half_even }],
      )

      expect(half_up.calculate(-1).tax).to eq Money.new(-1, "USD")
      expect(half_even.calculate(-1).tax).to eq Money.new(0, "USD")
    end

    it "accepts Money in minor units" do
      result = calculator.calculate(Money.new(100, "USD"))

      expect(result.gross).to eq Money.new(110, "USD")
    end

    it "rejects fractional minor units instead of silently rounding them" do
      previous = Money.default_infinite_precision
      Money.default_infinite_precision = true
      fractional_money = Money.new(BigDecimal("1.5"), "USD")

      expect { calculator.calculate(fractional_money) }
        .to raise_error(ArgumentError, /whole USD minor unit/)
    ensure
      Money.default_infinite_precision = previous
    end

    it "rejects a mismatched currency" do
      expect { calculator.calculate(Money.new(100, "EUR")) }
        .to raise_error(ArgumentError, /does not match/)
    end
  end

  describe "#gross_from_net" do
    it "returns only the gross amount" do
      expect(calculator.gross_from_net(100)).to eq Money.new(110, "USD")
    end
  end

  describe "#nets_for_gross" do
    it "returns every net minor-unit amount that rounds to the gross amount" do
      results = calculator.nets_for_gross(115)

      expect(results.map { |result| result.net.fractional }).to eq([102, 103, 104, 105])
      expect(results.map { |result| result.gross }).to all(eq(Money.new(115, "USD")))
    end

    it "has an alias for reverse calculation" do
      expect(calculator.reverse(115).length).to eq(4)
    end

    it "returns an empty array when no integer net amount matches" do
      vat = described_class.new(currency: "USD", taxes: [{ rate: 1 }])

      expect(vat.nets_for_gross(1)).to eq([])
    end

    it "returns an empty array when gross is not on a cash step" do
      expect(calculator.nets_for_gross(112)).to eq([])
    end

    it "reverses a negative chargeback" do
      vat = described_class.new(currency: "USD", taxes: [{ rate: Rational(10, 100) }])
      results = vat.nets_for_gross(-110)

      expect(results.map { |result| result.net }).to eq([Money.new(-100, "USD")])
    end

    it "reverses zero without selecting a negative reversal" do
      vat = described_class.new(currency: "USD", taxes: [{ rate: Rational(10, 100) }])

      expect(vat.nets_for_gross(0).map { |result| result.net }).to eq([Money.new(0, "USD")])
    end
  end

  describe "initialization validation" do
    it "detects a dependency cycle before calculation" do
      expect do
        described_class.new(
          currency: "USD",
          taxes: [
            { name: :a, rate: 1, base_dependencies: :b },
            { name: :b, rate: 1, base_dependencies: :a },
          ],
        )
      end.to raise_error(
        described_class::CircularDependencyError,
        "circular tax dependencies: a -> b -> a",
      )
    end

    it "detects a self dependency" do
      expect do
        described_class.new(
          currency: "USD",
          taxes: [{ name: :a, rate: 1, base_dependencies: :a }],
        )
      end.to raise_error(described_class::CircularDependencyError, /depends on itself/)
    end

    it "detects an unknown dependency" do
      expect do
        described_class.new(
          currency: "USD",
          taxes: [{ name: :a, rate: 1, base_dependencies: :missing }],
        )
      end.to raise_error(described_class::InvalidTaxError, /unknown tax/)
    end

    it "rejects an empty tax list" do
      expect { described_class.new(currency: "USD", taxes: []) }
        .to raise_error(described_class::InvalidTaxError, /non-empty array/)
    end

    it "rejects duplicate tax names" do
      expect do
        described_class.new(
          currency: "USD",
          taxes: [{ name: :a, rate: 1 }, { name: :a, rate: 1 }],
        )
      end.to raise_error(described_class::InvalidTaxError, /duplicate tax names/)
    end

    it "rejects an empty base" do
      expect do
        described_class.new(currency: "USD", taxes: [{ rate: 1, base_dependencies: [] }])
      end.to raise_error(described_class::InvalidTaxError, /must not be empty/)
    end

    it "rejects duplicate base components" do
      expect do
        described_class.new(
          currency: "USD",
          taxes: [
            { name: :vat, rate: 1 },
            { name: :surtax, rate: 1, base_dependencies: [:vat, :vat] },
          ],
        )
      end.to raise_error(described_class::InvalidTaxError, /duplicate dependencies/)
    end

    it "rejects negative rates" do
      expect { described_class.new(currency: "USD", taxes: [{ rate: -1 }]) }
        .to raise_error(described_class::InvalidTaxError, /non-negative/)
    end

    it "rejects Float rates to avoid ambiguous precision" do
      expect { described_class.new(currency: "USD", taxes: [{ rate: 0.1 }]) }
        .to raise_error(described_class::InvalidTaxError, /not Float/)
    end

    it "rejects an unsupported rounding mode" do
      expect { described_class.new(currency: "USD", taxes: [{ rate: 1 }], rounding_mode: :bad) }
        .to raise_error(ArgumentError, /unsupported rounding mode/)
    end

    it "rejects a non-positive cash rounding step" do
      expect do
        described_class.new(currency: "USD", taxes: [{ rate: 1 }], cash_rounding_step: 0)
      end.to raise_error(ArgumentError, /positive integer/)
    end
  end
end
