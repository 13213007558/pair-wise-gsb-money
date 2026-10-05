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

  describe ".generate_with_bounds" do
    it "raises an error when no shares are given" do
      expect { described_class.generate_with_bounds(100, []) }.to raise_error(ArgumentError)
    end

    it "raises an error for inconsistent limits" do
      expect { described_class.generate_with_bounds(100, [{ min: 10, max: 5 }]) }
        .to raise_error(ArgumentError, /max must be greater than or equal to min/)
      expect { described_class.generate_with_bounds(100, [{ min: -1 }]) }
        .to raise_error(ArgumentError, /min must be non-negative/)
      expect { described_class.generate_with_bounds(100, [{ weight: -1 }]) }
        .to raise_error(ArgumentError, /weight must be non-negative/)
    end

    it "satisfies minimums before distributing the rest by weight" do
      shares = [{ weight: 1, min: 10 }, { weight: 1, min: 20 }]

      expect(described_class.generate_with_bounds(100, shares)).to eq([45, 55])
    end

    it "caps shares and redistributes the leftover" do
      shares = [{ weight: 1, max: 10 }, { weight: 1 }]

      expect(described_class.generate_with_bounds(100, shares)).to eq([10, 90])
    end

    it "keeps redistributing when a redistribution triggers another cap" do
      shares = [
        { weight: 1, max: 10 },
        { weight: 1, max: 40 },
        { weight: 1 },
      ]

      # First pass caps the first share at 10, the redistribution then
      # pushes the second share past its own cap of 40, and only the
      # second redistribution can settle on the uncapped share.
      expect(described_class.generate_with_bounds(100, shares)).to eq([10, 40, 50])
    end

    it "combines minimums and caps without losing pennies" do
      shares = [
        { weight: 2, min: 100, max: 500 },
        { weight: 3, min: 50 },
        { weight: 5, min: 200, max: 300 },
      ]

      result = described_class.generate_with_bounds(1000, shares)
      expect(result).to eq([320, 380, 300])
      expect(result.sum).to eq(1000)
    end

    it "accepts rational weights and compares them exactly" do
      shares = [{ weight: Rational(1, 3) }, { weight: Rational(2, 3) }]

      expect(described_class.generate_with_bounds(3, shares)).to eq([1, 2])
      expect(described_class.generate_with_bounds(1, shares)).to eq([0, 1])
    end

    it "breaks ties by the explicit stable key, not by input order" do
      shares = [{ weight: 1, key: :b }, { weight: 1, key: :a }]

      expect(described_class.generate_with_bounds(1, shares)).to eq([0, 1])
    end

    it "defaults the tie-break key to the share's position" do
      expect(described_class.generate_with_bounds(1, [{ weight: 1 }, { weight: 1 }])).to eq([1, 0])
    end

    it "gives nothing beyond the minimum to zero-weight shares" do
      shares = [{ weight: 0, min: 5 }, { weight: 1 }]

      expect(described_class.generate_with_bounds(15, shares)).to eq([5, 10])
    end

    it "splits evenly when every weight is zero" do
      expect(described_class.generate_with_bounds(10, [{ weight: 0 }, { weight: 0 }])).to eq([5, 5])
    end

    it "raises a shortfall error stating the missing amount" do
      shares = [{ min: 6 }, { min: 6 }]

      expect { described_class.generate_with_bounds(10, shares) }
        .to raise_error(Money::Allocation::ShortfallError, /shortfall of 2/)

      begin
        described_class.generate_with_bounds(10, shares)
      rescue Money::Allocation::ShortfallError => error
        expect(error.shortfall).to eq(2)
        expect(error.required).to eq(12)
      end
    end

    it "raises an undistributable error stating the balance that fits nowhere" do
      shares = [{ max: 30 }, { max: 30 }]

      expect { described_class.generate_with_bounds(100, shares) }
        .to raise_error(Money::Allocation::UndistributableError, /40 cannot be distributed/)

      begin
        described_class.generate_with_bounds(100, shares)
      rescue Money::Allocation::UndistributableError => error
        expect(error.undistributable).to eq(40)
        expect(error.distributable).to eq(60)
      end
    end

    context "with a negative amount" do
      it "requires the explicit refund mode" do
        expect { described_class.generate_with_bounds(-100, [{ weight: 1 }]) }
          .to raise_error(ArgumentError, /refund: true/)
      end

      it "refunds within the same bounds as a positive amount" do
        shares = [{ weight: 1, max: 10 }, { weight: 1 }]

        expect(described_class.generate_with_bounds(-100, shares, refund: true)).to eq([-10, -90])
      end

      it "checks feasibility against the refunded magnitude" do
        shares = [{ min: 6 }, { min: 6 }]

        expect { described_class.generate_with_bounds(-10, shares, refund: true) }
          .to raise_error(Money::Allocation::ShortfallError, /shortfall of 2/)
      end
    end
  end
end
