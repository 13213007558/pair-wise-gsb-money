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

  context "when given bounded shares" do
    it "requires an integer amount in the smallest currency unit" do
      shares = [{ key: "a", weight: 1 }]

      expect { described_class.generate_with_bounds(BigDecimal(100), shares) }
        .to raise_error(ArgumentError, /Integer/)
    end

    it "satisfies minimums before distributing the remainder by weight" do
      shares = [
        { key: "a", weight: 1, min: 10 },
        { key: "b", weight: 1, min: 20 },
        { key: "c", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(100, shares)).to eq([34, 43, 23])
    end

    it "redistributes the surplus of capped shares among the rest" do
      shares = [
        { key: "a", weight: 1, max: 10 },
        { key: "b", weight: 1 },
        { key: "c", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(90, shares)).to eq([10, 40, 40])
    end

    it "keeps redistributing when capping happens in successive rounds" do
      shares = [
        { key: "a", weight: 3, max: 30 },
        { key: "b", weight: 1, max: 25 },
        { key: "c", weight: 1 },
      ]

      # Round 1 caps "a" at 30 (quota 60), the redistribution then pushes
      # "b" over its cap of 25 (quota 35), and only the remainder lands on "c".
      result = described_class.generate_with_bounds(100, shares)

      expect(result).to eq([30, 25, 45])
      expect(result.sum).to eq(100)
    end

    it "counts minimums towards the caps" do
      shares = [
        { key: "a", weight: 1, min: 10, max: 15 },
        { key: "b", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(100, shares)).to eq([15, 85])
    end

    it "accepts Rational weights and splits them exactly" do
      shares = [
        { key: "a", weight: Rational(1, 2) },
        { key: "b", weight: Rational(1, 3) },
        { key: "c", weight: Rational(1, 6) },
      ]

      result = described_class.generate_with_bounds(100, shares)

      expect(result).to eq([50, 33, 17])
      expect(result.sum).to eq(100)
    end

    it "breaks ties by the explicit key, not by input order" do
      shares = [
        { key: "b", weight: 1 },
        { key: "a", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(5, shares)).to eq([2, 3])
    end

    it "gives shares with zero weight only their minimum" do
      shares = [
        { key: "a", weight: 0, min: 5 },
        { key: "b", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(100, shares)).to eq([5, 95])
    end

    it "handles a zero amount when all minimums are zero" do
      shares = [
        { key: "a", weight: 1 },
        { key: "b", weight: 1 },
      ]

      expect(described_class.generate_with_bounds(0, shares)).to eq([0, 0])
    end

    context "with infeasible totals" do
      it "reports the shortfall when minimums exceed the amount" do
        shares = [
          { key: "a", weight: 1, min: 30 },
          { key: "b", weight: 1, min: 30 },
        ]

        expect { described_class.generate_with_bounds(50, shares) }
          .to raise_error(ArgumentError, /shortfall of 10/)
      end

      it "reports the undistributable remainder when caps are below the amount" do
        shares = [
          { key: "a", weight: 1, max: 40 },
          { key: "b", weight: 1, max: 50 },
        ]

        expect { described_class.generate_with_bounds(100, shares) }
          .to raise_error(ArgumentError, /10 cannot be allocated/)
      end

      it "reports the undistributable remainder when no share can take more" do
        shares = [{ key: "a", weight: 0, min: 10 }]

        expect { described_class.generate_with_bounds(100, shares) }
          .to raise_error(ArgumentError, /90 of 100 cannot be allocated/)
      end
    end

    context "with invalid shares" do
      it "requires at least one share" do
        expect { described_class.generate_with_bounds(100, []) }
          .to raise_error(ArgumentError, /at least one share/)
      end

      it "requires an explicit key on every share" do
        expect { described_class.generate_with_bounds(100, [{ weight: 1 }]) }
          .to raise_error(ArgumentError, /explicit :key/)
      end

      it "requires unique keys" do
        shares = [
          { key: "a", weight: 1 },
          { key: "a", weight: 1 },
        ]

        expect { described_class.generate_with_bounds(100, shares) }
          .to raise_error(ArgumentError, /unique/)
      end

      it "rejects negative weights" do
        expect { described_class.generate_with_bounds(100, [{ key: "a", weight: -1 }]) }
          .to raise_error(ArgumentError, /non-negative numeric :weight/)
      end

      it "rejects caps below the minimum" do
        expect { described_class.generate_with_bounds(100, [{ key: "a", weight: 1, min: 10, max: 5 }]) }
          .to raise_error(ArgumentError, />= :min/)
      end
    end

    context "with a negative amount" do
      let(:shares) do
        [
          { key: "a", weight: 1 },
          { key: "b", weight: 1 },
          { key: "c", weight: 1 },
        ]
      end

      it "requires the explicit refund mode" do
        expect { described_class.generate_with_bounds(-100, shares) }
          .to raise_error(ArgumentError, /refund/)
      end

      it "refunds the mirrored allocation in refund mode" do
        expect(described_class.generate_with_bounds(-100, shares, refund: true))
          .to eq([-34, -33, -33])
      end

      it "applies minimums and caps to the refunded magnitudes" do
        shares = [
          { key: "a", weight: 1, min: 10 },
          { key: "b", weight: 1, max: 20 },
        ]

        expect(described_class.generate_with_bounds(-100, shares, refund: true))
          .to eq([-80, -20])
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
end
