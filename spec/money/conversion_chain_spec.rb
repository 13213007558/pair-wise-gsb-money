# frozen_string_literal: true

require "bigdecimal"
require "benchmark"

RSpec.describe Money::ConversionChain do
  let(:steps) do
    [
      {
        from_currency: "USD",
        to_currency: "EUR",
        rate: Rational(3, 2),
        fixed_fee: Rational(1, 2),
        rounding_mode: BigDecimal::ROUND_HALF_EVEN,
      },
      {
        from_currency: "EUR",
        to_currency: "USD",
        rate: Rational(4, 5),
        fixed_fee: 1,
        rounding_mode: BigDecimal::ROUND_DOWN,
      },
    ]
  end

  let(:chain) { described_class.new("USD", steps) }

  def brute_force(chain, target, source_range)
    source_range.select do |amount|
      chain.convert(Money.new(amount, chain.source_currency)) ==
        Money.new(target, chain.target_currency)
    end
  end

  describe "#reverse" do
    it "matches an exhaustive forward calculation on a bounded range" do
      source_range = -20..120
      target = 0

      expected = brute_force(chain, target, source_range)
      ranges = chain.reverse(Money.new(target, "USD"), source_range)
      actual = ranges.flat_map(&:to_a)

      expect(ranges).to all(be_a(Range))
      expect(actual).to eq(expected)
    end

    it "returns disjoint integer ranges without scanning the original range" do
      step = {
        from_currency: "USD",
        to_currency: "EUR",
        rate: Rational(1, 1_000_000),
        fixed_fee: 0,
        rounding_mode: BigDecimal::ROUND_HALF_UP,
      }
      chain = described_class.new("USD", [step])
      source_range = -10**18...10**18

      ranges = nil
      elapsed = Benchmark.realtime do
        ranges = chain.reverse(Money.new(0, "EUR"), source_range)
      end

      expect(elapsed).to be <(0.05)
      expect(ranges).to eq([-499_999..499_999])
      expect(source_range.cover?(-500_000)).to be(true)
      expect(source_range.cover?(499_999)).to be(true)
    end

    it "preserves an excluded source-range endpoint" do
      step = {
        from_currency: "USD",
        to_currency: "EUR",
        rate: 1,
        fixed_fee: 0,
        rounding_mode: BigDecimal::ROUND_FLOOR,
      }
      chain = described_class.new("USD", [step])

      expect(chain.reverse(0, 0...1)).to eq([0..0])
      expect(chain.reverse(0, 1...2)).to eq([])
    end

    it "handles positive and negative rounding boundaries without floating-point epsilon" do
      modes = [
        BigDecimal::ROUND_UP,
        BigDecimal::ROUND_DOWN,
        BigDecimal::ROUND_CEILING,
        BigDecimal::ROUND_FLOOR,
        BigDecimal::ROUND_HALF_UP,
        BigDecimal::ROUND_HALF_DOWN,
        BigDecimal::ROUND_HALF_EVEN,
      ]

      modes.each do |mode|
        step = {
          from_currency: "USD",
          to_currency: "EUR",
          rate: 2,
          fixed_fee: 0,
          rounding_mode: mode,
        }
        chain = described_class.new("USD", [step])

        (-3..3).each do |target|
          source_range = -10...10
          expected = source_range.select do |amount|
            chain.convert(Money.new(amount, "USD")) == Money.new(target, "EUR")
          end
          actual = chain.reverse(target, source_range).flat_map(&:to_a)
          expect(actual).to eq(expected)
        end
      end
    end

    it "returns an empty result when no source amount can reach the target" do
      step = {
        from_currency: "USD",
        to_currency: "EUR",
        rate: 1,
        fixed_fee: 2,
        rounding_mode: BigDecimal::ROUND_UP,
      }
      chain = described_class.new("USD", [step])

      expect(chain.reverse(0, 5..10)).to eq([])
    end

    it "returns all feasible integer ranges after multiple conversions" do
      step = {
        from_currency: "USD",
        to_currency: "EUR",
        rate: Rational(3, 1),
        fixed_fee: 0,
        rounding_mode: BigDecimal::ROUND_HALF_UP,
      }
      chain = described_class.new("USD", [step])
      expected = brute_force(chain, 0, -5..5)
      expect(chain.reverse(0, -5..5).flat_map(&:to_a)).to eq(expected)
    end

    it "handles currencies with different subunit ratios" do
      step = {
        from_currency: "USD",
        to_currency: "JPY",
        rate: 5,
        fixed_fee: 0,
        rounding_mode: BigDecimal::ROUND_FLOOR,
      }
      chain = described_class.new("USD", [step])
      source_range = 0..1_100

      ranges = chain.reverse(Money.new(5, "JPY"), source_range)
      actual = ranges.flat_map(&:to_a)

      expect(actual).to eq(brute_force(chain, 5, source_range))
      expect(actual).to eq((100..119).to_a)
    end

    it "supports the class-level shortcut" do
      result = Money.reverse_convert(Money.new(0, "USD"), -20..120, steps, from_currency: "USD")
      expect(result).to eq(chain.reverse(Money.new(0, "USD"), -20..120))
    end

    it "rejects non-integer source range endpoints" do
      expect { chain.reverse(0, 0.5..10) }.to raise_error(
        ArgumentError, "source range endpoints must be Integers"
      )
    end

    it "rejects non-integer target amounts" do
      expect { chain.reverse(BigDecimal("0.5"), 0..10) }.to raise_error(
        ArgumentError, "target amount must be an integer number of subunits"
      )
    end

    it "rejects non-positive or non-rational rates" do
      invalid = steps.map(&:dup)
      invalid.first[:rate] = 0

      expect { described_class.new("USD", invalid) }.to raise_error(
        ArgumentError, "exchange rate must be positive"
      )
    end

    it "rejects Float values to avoid floating-point epsilon" do
      invalid = steps.map(&:dup)
      invalid.first[:rate] = 1.5

      expect { described_class.new("USD", invalid) }.to raise_error(ArgumentError, /exact numeric/)
    end
  end
end
