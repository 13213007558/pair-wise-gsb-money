# frozen_string_literal: true

RSpec.describe Money::ArithmeticContext do
  describe ".with_arithmetic_context" do
    it "returns the block result and yields the context" do
      context = nil
      result = Money.with_arithmetic_context { |ctx| context = ctx; :done }

      expect(result).to eq :done
      expect(context).to be_a described_class
    end

    it "defaults to Money.rounding_mode, whole-unit precision and no traps" do
      Money.with_arithmetic_context do |context|
        expect(context.rounding_mode).to eq Money.rounding_mode
        expect(context.precision).to eq 0
        expect(context.traps).to be_empty
      end
    end

    it "accepts symbolic rounding modes" do
      Money.with_arithmetic_context(rounding_mode: :half_even) do |context|
        expect(context.rounding_mode).to eq BigDecimal::ROUND_HALF_EVEN
      end
    end

    it "exposes the context through Money.arithmetic_context while active" do
      expect(Money.arithmetic_context).to be_nil
      Money.with_arithmetic_context do |context|
        expect(Money.arithmetic_context).to equal context
      end
      expect(Money.arithmetic_context).to be_nil
    end

    it "rejects a negative precision" do
      expect { Money.with_arithmetic_context(precision: -1) {} }
        .to raise_error(ArgumentError)
    end

    it "rejects unknown trap signals" do
      expect { Money.with_arithmetic_context(traps: [:overflow]) {} }
        .to raise_error(ArgumentError, /unknown precision signal/)
    end
  end

  describe "division" do
    it "records rounded and inexact for 1 cent divided by 3" do
      Money.with_arithmetic_context(precision: 0) do |context|
        result = Money.new(1, "USD") / 3

        expect(result.fractional).to eq 0
        expect(context).to be_rounded
        expect(context).to be_inexact
        expect(context.signals).to eq [:rounded, :inexact]
      end
    end

    it "records nothing for exactly divisible amounts" do
      Money.with_arithmetic_context(precision: 0) do |context|
        expect((Money.new(100, "USD") / 4).fractional).to eq 25
        expect((Money.new(3, "USD") / 3).fractional).to eq 1
        expect(context.signals).to be_empty
      end
    end

    it "quantizes with the context precision and rounding mode" do
      Money.with_arithmetic_context(precision: 0, rounding_mode: :down) do
        expect((Money.new(1, "USD") / 2).fractional).to eq 0
      end
      Money.with_arithmetic_context(precision: 0, rounding_mode: :up) do
        expect((Money.new(1, "USD") / 2).fractional).to eq 1
      end
    end
  end

  describe "multiplication" do
    it "distinguishes representation rounding from value changes" do
      Money.with_arithmetic_context(precision: 0) do |context|
        result = Money.new(100, "USD") * BigDecimal("1.5")

        expect(result.fractional).to eq 150
        expect(context).to be_rounded
        expect(context).not_to be_inexact
      end
    end

    it "records inexact when the value actually changes" do
      Money.with_arithmetic_context(precision: 0) do |context|
        Money.new(1, "USD") * BigDecimal("0.5")

        expect(context).to be_rounded
        expect(context).to be_inexact
      end
    end

    it "records nothing for exact products" do
      Money.with_arithmetic_context(precision: 0) do |context|
        expect((Money.new(100, "USD") * 2).fractional).to eq 200
        expect(context.signals).to be_empty
      end
    end
  end

  describe "currency exchange" do
    let(:bank) do
      Money::Bank::VariableExchange.new.tap do |bank|
        bank.add_rate("USD", "EUR", 0.85)
        bank.add_rate("USD", "CAD", 2)
      end
    end

    it "records rounded and inexact when the rate drops decimals" do
      Money.with_arithmetic_context(precision: 0) do |context|
        Money.new(1, "USD", bank: bank).exchange_to("EUR")

        expect(context).to be_rounded
        expect(context).to be_inexact
      end
    end

    it "records nothing for exact conversions" do
      Money.with_arithmetic_context(precision: 0) do |context|
        result = Money.new(100, "USD", bank: bank).exchange_to("CAD")

        expect(result.fractional).to eq 200
        expect(context.signals).to be_empty
      end
    end

    it "records nothing when no conversion happens" do
      Money.with_arithmetic_context(precision: 0) do |context|
        Money.new(100, "USD", bank: bank).exchange_to("USD")
        expect(context.signals).to be_empty
      end
    end
  end

  describe "explicit quantization", :default_infinite_precision_true do
    it "records signals when Money#round drops decimals" do
      Money.with_arithmetic_context(precision: 2) do |context|
        result = Money.new(BigDecimal("1.005"), "USD").round

        expect(result.fractional).to eq BigDecimal("1.01")
        expect(context).to be_rounded
        expect(context).to be_inexact
      end
    end

    it "records nothing when the value already fits the precision" do
      Money.with_arithmetic_context(precision: 2) do |context|
        Money.new(BigDecimal("1.5"), "USD").round
        expect(context.signals).to be_empty
      end
    end

    it "honors explicit arguments over the context configuration" do
      Money.with_arithmetic_context(precision: 2, rounding_mode: :down) do |context|
        result = Money.new(BigDecimal("1.005"), "USD").round(BigDecimal::ROUND_HALF_UP, 1)

        expect(result.fractional).to eq BigDecimal("1.0")
        expect(context).to be_inexact
      end
    end
  end

  describe "traps" do
    it "raises Inexact only for operations that change the value" do
      expect do
        Money.with_arithmetic_context(precision: 0, traps: [:inexact]) do
          Money.new(1, "USD") / 3
        end
      end.to raise_error(Money::ArithmeticContext::Inexact)

      expect do
        Money.with_arithmetic_context(precision: 0, traps: [:inexact]) do
          Money.new(100, "USD") / 4
          Money.new(100, "USD") * BigDecimal("1.5")
        end
      end.not_to raise_error
    end

    it "raises Rounded only when digits were discarded" do
      expect do
        Money.with_arithmetic_context(precision: 0, traps: [:rounded]) do
          Money.new(1, "USD") / 3
        end
      end.to raise_error(Money::ArithmeticContext::Rounded)

      expect do
        Money.with_arithmetic_context(precision: 0, traps: [:rounded]) do
          Money.new(100, "USD") / 4
        end
      end.not_to raise_error
    end

    it "still records the signal on the context before raising" do
      Money.with_arithmetic_context(precision: 0, traps: [:inexact]) do |context|
        begin
          Money.new(1, "USD") / 3
        rescue Money::ArithmeticContext::Inexact
          nil
        end

        expect(context).to be_inexact
        expect(context).to be_rounded
      end
    end

    it "exposes the trapped signal and context on the error" do
      Money.with_arithmetic_context(precision: 0, traps: [:inexact]) do |context|
        Money.new(1, "USD") / 3
      end
    rescue Money::ArithmeticContext::SignalError => error
      expect(error.signal).to eq :inexact
      expect(error.context).to be_a described_class
      expect(error.message).to include("inexact")
    end
  end

  describe "nesting" do
    it "restores the outer context when the inner one exits" do
      Money.with_arithmetic_context(precision: 0) do |outer|
        Money.with_arithmetic_context(precision: 2, rounding_mode: :down) do |inner|
          expect(Money.arithmetic_context).to equal inner
          expect(inner.precision).to eq 2
        end

        expect(Money.arithmetic_context).to equal outer
        expect(outer.precision).to eq 0
        expect(outer.rounding_mode).to eq Money.rounding_mode
      end

      expect(Money.arithmetic_context).to be_nil
    end

    it "records signals on the context they occurred in" do
      Money.with_arithmetic_context(precision: 0) do |outer|
        Money.with_arithmetic_context(precision: 0) do |inner|
          Money.new(1, "USD") / 3
          expect(inner).to be_inexact
        end

        expect(outer).not_to be_inexact
      end
    end

    it "restores the previous context when the block raises" do
      expect do
        Money.with_arithmetic_context(precision: 3) { raise "boom" }
      end.to raise_error("boom")

      expect(Money.arithmetic_context).to be_nil
    end
  end

  describe "thread and fiber isolation" do
    it "is not visible inside other threads" do
      Money.with_arithmetic_context(precision: 0) do
        expect(Thread.new { Money.arithmetic_context }.value).to be_nil
      end
    end

    it "does not leak contexts entered in other threads" do
      thread = Thread.new do
        Money.with_arithmetic_context(precision: 5) do
          Thread.current[:inner] = Money.arithmetic_context.precision
        end
        Thread.current[:after] = Money.arithmetic_context
      end
      thread.join

      expect(thread[:inner]).to eq 5
      expect(thread[:after]).to be_nil
      expect(Money.arithmetic_context).to be_nil
    end

    it "is not visible inside nested fibers" do
      Money.with_arithmetic_context(precision: 0) do
        expect(Fiber.new { Money.arithmetic_context }.resume).to be_nil
      end
    end

    it "does not leak contexts entered in other fibers" do
      fiber = Fiber.new do
        Money.with_arithmetic_context(precision: 5) do
          Fiber.yield Money.arithmetic_context.precision
        end
      end

      expect(fiber.resume).to eq 5
      expect(Money.arithmetic_context).to be_nil
      fiber.resume
      expect(Money.arithmetic_context).to be_nil
    end
  end
end
