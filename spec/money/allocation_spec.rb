# frozen_string_literal: true

RSpec.describe Money::Allocation do
  context "when given number as argument" do
    it "raises an error when invalid argument is given" do
      expect { described_class.generate(100, 0) }.to raise_error(ArgumentError)
      expect { described_class.generate(100, -1) }.to raise_error(ArgumentError)
    end

    context "with whole amounts" do
      it "returns the amount when 1 is given" do
        expect(described_class.generate(100, 1)).to eq([100])
      end

      it "splits the amount into equal parts" do
        expect(described_class.generate(100, 2)).to eq([50, 50])
        expect(described_class.generate(100, 4)).to eq([25, 25, 25, 25])
        expect(described_class.generate(100, 5)).to eq([20, 20, 20, 20, 20])
      end

      it "does not lose pennies" do
        expect(described_class.generate(5, 2)).to eq([3, 2])
        expect(described_class.generate(2, 3)).to eq([1, 1, 0])
        expect(described_class.generate(100, 3)).to eq([34, 33, 33])
        expect(described_class.generate(100, 6)).to eq([17, 17, 17, 17, 16, 16])
      end
    end

    context "with fractional amounts" do
      it "returns the amount when 1 is given" do
        expect(described_class.generate(BigDecimal(100), 1, false)).to eq([BigDecimal(100)])
      end

      it "splits the amount into equal parts" do
        expect(described_class.generate(BigDecimal(100), 2, false)).to eq([50, 50])
        expect(described_class.generate(BigDecimal(100), 4, false)).to eq([25, 25, 25, 25])
        expect(described_class.generate(BigDecimal(100), 5, false)).to eq([20, 20, 20, 20, 20])
      end

      it "splits the amount into equal fractions" do
        expect(described_class.generate(BigDecimal(5), 2, false)).to eq([2.5, 2.5])
        expect(described_class.generate(BigDecimal(5), 4, false)).to eq([1.25, 1.25, 1.25, 1.25])
      end

      it "converts a rational with Money.conversion_precision instead of through a float" do
        expect(described_class.generate(Rational(2, 3), 1, false)).to eq([BigDecimal("0.6666666666666667")])
        expect(described_class.generate(Rational(10**400, 1), 1, false)).to eq([BigDecimal("1e400")])
        expect(described_class.generate(Rational(1, 10**400), 1, false)).to eq([BigDecimal("1e-400")])
      end

      it "handles splits into repeating decimals" do
        amount = BigDecimal(100)
        parts = described_class.generate(amount, 3, false)

        # Rounding due to inconsistent BigDecimal size in ruby compared to jruby. In reality the
        # first 2 elements will look like the last one with a '5' at the end, compensating for a
        # missing fraction
        expect(parts.map { |x| x.round(10) }).to eq(
          [
            BigDecimal("33.3333333333"),
            BigDecimal("33.3333333333"),
            BigDecimal("33.3333333333"),
          ],
        )
        expect(parts.sum).to eq(amount)
      end
    end
  end

  context "when given array as argument" do
    it "raises an error when invalid argument is given" do
      expect { described_class.generate(100, []) }.to raise_error(ArgumentError)
    end

    context "with whole amounts" do
      it "returns the amount when array contains only one element" do
        expect(described_class.generate(100, [1])).to eq([100])
        expect(described_class.generate(100, [5])).to eq([100])
      end

      it "splits the amount into whole parts respecting the order" do
        expect(described_class.generate(100, [1, 1])).to eq([50, 50])
        expect(described_class.generate(100, [1, 1, 2])).to eq([25, 25, 50])
        expect(described_class.generate(100, [7, 3])).to eq([70, 30])
      end

      it "accepts floats as arguments" do
        expect(described_class.generate(100, [1.0, 1.0])).to eq([50, 50])
        expect(described_class.generate(100, [0.1, 0.1, 0.2])).to eq([25, 25, 50])
        expect(described_class.generate(100, [0.07, 0.03])).to eq([70, 30])
        expect(described_class.generate(10, [0.1, 0.2, 0.1])).to eq([3, 5, 2])
      end

      it "does not lose pennies" do
        expect(described_class.generate(10, [1, 1, 2])).to eq([3, 2, 5])
        expect(described_class.generate(100, [1, 1, 1])).to eq([34, 33, 33])
      end

      it "handles zero arguments" do
        expect(described_class.generate(100, [1, 1, 0])).to eq([50, 50, 0])
        expect(described_class.generate(100, [0, 1, 1])).to eq([0, 50, 50])
      end
    end

    context "with fractional amounts" do
      it "returns the amount when array contains only one element" do
        expect(described_class.generate(BigDecimal(100), [1], false)).to eq([100])
        expect(described_class.generate(BigDecimal(100), [5], false)).to eq([100])
      end

      it "splits the amount into whole parts respecting the order" do
        expect(described_class.generate(BigDecimal(100), [1, 1], false)).to eq([50, 50])
        expect(described_class.generate(BigDecimal(100), [1, 1, 2], false)).to eq([25, 25, 50])
        expect(described_class.generate(BigDecimal(100), [7, 3], false)).to eq([70, 30])
      end

      it "splits the amount proportionally to the given parts" do
        expect(described_class.generate(BigDecimal(10), [1, 1, 2], false)).to eq([2.5, 2.5, 5])
        expect(described_class.generate(BigDecimal(7), [1, 1], false)).to eq([3.5, 3.5])
      end

      it "keeps the class of the splits the same as given amount" do
        # Note that whole_amount is false but result is whole values
        expect(described_class.generate(10, [1, 1, 2], false)).to eq([3, 2, 5])
      end

      it "handles splits into repeating decimals" do
        amount = BigDecimal(100)
        parts = described_class.generate(amount, [1, 1, 1], false)

        # Rounding due to inconsistent BigDecimal size in ruby compared to jruby. In reality the
        # first 2 elements will look like the last one with a '5' at the end, compensating for a
        # missing fraction
        expect(parts.map { |x| x.round(10) }).to eq(
          [
            BigDecimal("33.3333333333"),
            BigDecimal("33.3333333333"),
            BigDecimal("33.3333333333"),
          ],
        )
        expect(parts.sum).to eq(amount)
      end
    end
  end

  context "with an allocation seen in the wild" do
    it "allocates the full amount" do
      amount = 700273
      allocations = [
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.170126087450276,
        1.0,
        1.0,
        1.0,
        1.0,
      ]

      result = described_class.generate(amount, allocations)
      expect(result.sum).to eq(amount)
      expect(result).to eq(
        [
          61566,
          61565,
          61565,
          61565,
          61565,
          61565,
          61565,
          60953,
          52091,
          52091,
          52091,
          52091,
        ],
      )
    end

    it "allocates the full -amount" do
      amount = -700273
      allocations = [
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.1818583143661,
        1.170126087450276,
        1.0,
        1.0,
        1.0,
        1.0,
      ]

      result = described_class.generate(amount, allocations)
      expect(result.sum).to eq(amount)
      expect(result).to eq(
        [
          -61566,
          -61565,
          -61565,
          -61565,
          -61565,
          -61565,
          -61565,
          -60953,
          -52091,
          -52091,
          -52091,
          -52091,
        ],
      )
    end

    context "when specified precision" do
      let(:amount) { 246.4 }
      let(:allocations) do
        [
          81.29, 81.29, 81.29, 81.29,
          234.8, 234.8, 234.8, 234.8,
          90.36, 90.36, 90.36, 90.36,
          90.36, 90.36, 90.36, 90.36,
          90.36, 90.36, 90.36, 90.36,
          90.36, 90.36, 90.36, 90.36,
          90.36, 90.36, 90.36, 90.36,
          90.36,
        ]
      end

      it "allocates with required precision" do
        result = described_class.generate(amount, allocations, 16)
        expect(result.sum).to eq(amount)

        expected = %w[
          6.3347130857200688 6.3347130857200689 6.3347130857200688 6.3347130857200688
          18.2973383260803562 18.2973383260803563 18.2973383260803563 18.2973383260803563
          7.0415140167999191 7.041514016799919 7.0415140167999191 7.041514016799919
          7.0415140167999191 7.041514016799919 7.0415140167999191 7.041514016799919
          7.0415140167999191 7.041514016799919 7.0415140167999191 7.041514016799919
          7.041514016799919  7.041514016799919 7.041514016799919  7.041514016799919
          7.041514016799919  7.041514016799919 7.041514016799919  7.041514016799919
          7.041514016799919
        ].map { |element| BigDecimal(element) }

        expect(result).to eq(expected)
      end
    end
  end

  describe ".allocate_with_constraints" do
    it "allocates by weight while honoring minimum and maximum amounts" do
      parts = [
        { id: :a, weight: 9, max: 30 },
        { id: :b, weight: 9, max: 30 },
        { id: :c, weight: 2 },
        { id: :d, weight: 0, min: 10 },
      ]

      result = described_class.allocate_with_constraints(101, parts)

      expect(result).to eq(
        [
          { id: :a, amount: 30 },
          { id: :b, amount: 30 },
          { id: :c, amount: 31 },
          { id: :d, amount: 10 },
        ],
      )
      expect(result.sum { |part| part[:amount] }).to eq(101)
    end

    it "uses IDs for remainder tie-breaking regardless of input order" do
      parts = [
        { id: :a, weight: 0, min: 10, max: 30 },
        { id: :b, weight: 0, min: 10, max: 30 },
        { id: :c, weight: 0, min: 10, max: 30 },
        { id: :d, weight: 0, min: 10, max: 30 },
      ]

      result = described_class.allocate_with_constraints(101, parts)
      reversed_result = described_class.allocate_with_constraints(101, parts.reverse)
      result_by_id = result.to_h { |part| [part[:id], part[:amount]] }
      reversed_result_by_id = reversed_result.to_h { |part| [part[:id], part[:amount]] }

      expect(result_by_id).to eq(a: 26, b: 25, c: 25, d: 25)
      expect(reversed_result).to eq(
        [
          { id: :d, amount: 25 },
          { id: :c, amount: 25 },
          { id: :b, amount: 25 },
          { id: :a, amount: 26 },
        ],
      )
      expect(reversed_result_by_id).to eq(result_by_id)
      expect(result.sum { |part| part[:amount] }).to eq(101)
    end

    it "reports why one fractional unit cannot meet the minimum allocation" do
      expect { described_class.allocate_with_constraints(1, [{ id: :a, min: 10 }]) }
        .to raise_error(described_class::ConstraintError, "cannot allocate 1: minimum allocation is 10")
    end

    it "reports when the total cannot fit under the maximum allocations" do
      parts = [
        { id: :a, weight: 1, max: 30 },
        { id: :b, weight: 1, max: 30 },
        { id: :c, weight: 1, max: 30 },
      ]

      expect { described_class.allocate_with_constraints(101, parts) }
        .to raise_error(described_class::ConstraintError, "cannot allocate 101: maximum allocation is 90")
    end

    it "applies the same constraints to refunds and negates every allocation" do
      parts = [
        { id: :a, weight: 9, max: 30 },
        { id: :b, weight: 9, max: 30 },
        { id: :c, weight: 2 },
        { id: :d, weight: 0, min: 10 },
      ]

      result = described_class.allocate_with_constraints(-101, parts)

      expect(result).to eq(
        [
          { id: :a, amount: -30 },
          { id: :b, amount: -30 },
          { id: :c, amount: -31 },
          { id: :d, amount: -10 },
        ],
      )
      expect(result.sum { |part| part[:amount] }).to eq(-101)

      expect { described_class.allocate_with_constraints(-1, [{ id: :a, min: 10 }]) }
        .to raise_error(described_class::ConstraintError, "cannot allocate 1: minimum allocation is 10")
    end

    it "requires stable, unique, comparable IDs and integer bounds" do
      expect { described_class.allocate_with_constraints(10, [{ weight: 1 }]) }
        .to raise_error(ArgumentError, /stable :id/)
      expect { described_class.allocate_with_constraints(10, [{ id: :a }, { id: :a }]) }
        .to raise_error(ArgumentError, /unique/)
      expect { described_class.allocate_with_constraints(10, [{ id: :a }, { id: 1 }]) }
        .to raise_error(ArgumentError, /mutually comparable/)
      expect { described_class.allocate_with_constraints(10, [{ id: :a, min: -1 }]) }
        .to raise_error(ArgumentError, /non-negative integer/)
      expect { described_class.allocate_with_constraints(10, [{ id: :a, max: 1.5 }]) }
        .to raise_error(ArgumentError, /non-negative integer or nil/)
    end

    it "does not return fractional allocations for fractional-unit input" do
      expect { described_class.allocate_with_constraints(BigDecimal("10.5"), [{ id: :a }]) }
        .to raise_error(ArgumentError, /integer amount/)
    end

    it "accepts an integer-valued BigDecimal in fractional units" do
      result = described_class.allocate_with_constraints(
        BigDecimal("101"),
        [{ id: :a, weight: 1 }, { id: :b, weight: 1 }],
      )

      expect(result).to eq([{ id: :a, amount: 51 }, { id: :b, amount: 50 }])
    end

    it "works through generate" do
      result = described_class.generate(
        101,
        [
          { id: :a, weight: 1, min: 10, max: 30 },
          { id: :b, weight: 2, min: 10, max: 30 },
          { id: :c, weight: 1, min: 10, max: 30 },
          { id: :d, weight: 0, min: 10, max: 30 },
        ],
      )

      expect(result).to eq(
        [
          { id: :a, amount: 30 },
          { id: :b, amount: 30 },
          { id: :c, amount: 30 },
          { id: :d, amount: 11 },
        ],
      )
    end
  end
end
