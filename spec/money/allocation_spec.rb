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

  context "with bounded parts" do
    let(:channels) do
      [
        {id: :fixed, weight: 0, min: 10},
        {id: :second, weight: 1, max: 30},
        {id: :third, weight: 1, max: 30},
        {id: :open, weight: 1},
      ]
    end

    it "honors minimums, maximums and weight" do
      result = described_class.generate(101, channels)

      expect(result).to eq(
        [
          {id: :fixed, amount: 10},
          {id: :second, amount: 30},
          {id: :third, amount: 30},
          {id: :open, amount: 31},
        ],
      )
      expect(result.sum { |allocation| allocation.fetch(:amount) }).to eq(101)
    end

    it "caps multiple channels in the same allocation round" do
      parts = [
        {id: 1, weight: 3, max: 30},
        {id: 2, weight: 3, max: 30},
        {id: 3, weight: 3, max: 30},
        {id: 4, weight: 1},
      ]

      expect(described_class.generate(101, parts)).to eq(
        [
          {id: 1, amount: 30},
          {id: 2, amount: 30},
          {id: 3, amount: 30},
          {id: 4, amount: 11},
        ],
      )
    end

    it "splits all-zero weights evenly with stable remainder order" do
      parts = [
        {id: 3, weight: 0},
        {id: 2, weight: 0},
        {id: 1, weight: 0},
      ]

      expect(described_class.generate(100, parts)).to eq(
        [
          {id: 3, amount: 33},
          {id: 2, amount: 33},
          {id: 1, amount: 34},
        ],
      )
    end

    it "keeps zero-weight channels at their minimum until positive weights are capped" do
      parts = [
        {id: 3, weight: 0},
        {id: 2, weight: 1},
        {id: 1, weight: 1},
      ]

      expect(described_class.generate(101, parts)).to eq(
        [
          {id: 3, amount: 0},
          {id: 2, amount: 50},
          {id: 1, amount: 51},
        ],
      )
    end

    it "is independent of input array order" do
      result = described_class.generate(101, channels.reverse).to_h { |allocation| allocation.values_at(:id, :amount) }

      expect(result).to eq(fixed: 10, second: 30, third: 30, open: 31)
    end

    it "returns a hash keyed by stable id" do
      parts = channels.each_with_object({}) { |channel, result| result[channel.fetch(:id)] = channel }

      expect(described_class.generate(101, parts)).to eq(
        fixed: 10,
        second: 30,
        third: 30,
        open: 31,
      )
    end

    it "allocates refunds by magnitude and negates every result" do
      result = described_class.generate(-101, channels)

      expect(result).to eq(
        [
          {id: :fixed, amount: -10},
          {id: :second, amount: -30},
          {id: :third, amount: -30},
          {id: :open, amount: -31},
        ],
      )
      expect(result.sum { |allocation| allocation.fetch(:amount) }).to eq(-101)
    end

    it "rejects one cent when two channels each require one unit" do
      expect { described_class.generate(1, [{id: 1, min: 1}, {id: 2, min: 1}]) }
        .to raise_error(ArgumentError, "amount is less than the total minimum (2)")
    end

    it "reports when the total maximum is too small" do
      parts = [{id: 1, max: 30}, {id: 2, max: 30}, {id: 3, max: 30}]

      expect { described_class.generate(101, parts) }
        .to raise_error(ArgumentError, "amount exceeds the total maximum (90)")
    end

    it "does not return a half smallest-unit allocation" do
      expect { described_class.generate(1.5, channels) }
        .to raise_error(ArgumentError, "amount must be a whole number of smallest currency units")
    end

    it "rejects duplicate stable ids" do
      expect { described_class.generate(101, [{id: 1, min: 1}, {id: 1}]) }
        .to raise_error(ArgumentError, "allocation ids must be unique")
    end

    it "rejects numeric and hash parts mixed in the same array" do
      expect { described_class.generate(101, [1, {max: 30}]) }
        .to raise_error(ArgumentError, "allocation parts must be numeric or hashes, not both")
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
