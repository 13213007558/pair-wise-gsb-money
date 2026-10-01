# frozen_string_literal: true

RSpec.describe Money::ComputationContext do
  def enter_context(**options, &block)
    Money.with_computation_context(**options, &block)
  end

  describe "signal recording" do
    it "records :rounded and :inexact when one cent is divided by three" do
      enter_context do |context|
        result = Money.new(1, "USD") / 3

        expect(result.fractional).to eq(0)
        expect(context.signals).to eq([:rounded, :inexact])
        expect(context).to be_rounded
        expect(context).to be_inexact
      end
    end

    it "records no signals for an exactly divisible operation" do
      enter_context do |context|
        result = Money.new(6, "USD") / 3

        expect(result.fractional).to eq(2)
        expect(context.signals).to be_empty
        expect(context).not_to be_rounded
        expect(context).not_to be_inexact
      end
    end

    it "distinguishes representation rounding from an actual value change" do
      enter_context do |context|
        result = Money.new(100, "USD").quantize(-1)

        expect(result.fractional).to eq(100)
        expect(context.signals).to eq([:rounded])
        expect(context).to be_rounded
        expect(context).not_to be_inexact
      end
    end

    it "does not leak signals into code running without a context" do
      enter_context { Money.new(1, "USD") / 3 }

      expect(Money.computation_context).to be_nil
      expect { Money.new(1, "USD") / 3 }.not_to raise_error
    end
  end

  describe "covered operations" do
    it "covers multiplication" do
      enter_context do |context|
        expect((Money.new(100, "USD") * BigDecimal("0.029")).fractional).to eq(3)
        expect(context.signals).to eq([:rounded, :inexact])
      end

      enter_context do |context|
        expect((Money.new(100, "USD") * 2).fractional).to eq(200)
        expect(context.signals).to be_empty
      end
    end

    it "covers currency exchange" do
      bank = Money::Bank::VariableExchange.new
      bank.add_rate("USD", "CAD", 1.24515)
      bank.add_rate("USD", "EUR", 2)

      enter_context do |context|
        result = Money.new(100_00, "USD", bank: bank).exchange_to("CAD")

        expect(result.fractional).to eq(12_452)
        expect(context.signals).to eq([:rounded, :inexact])
      end

      enter_context do |context|
        result = Money.new(100_00, "USD", bank: bank).exchange_to("EUR")

        expect(result.fractional).to eq(200_00)
        expect(context.signals).to be_empty
      end
    end

    it "covers explicit quantization" do
      enter_context do |context|
        expect(Money.new(BigDecimal("10.005"), "USD").quantize(2).fractional).to eq(10)
        expect(context.signals).to eq([:rounded, :inexact])
      end

      enter_context do |context|
        expect(Money.new(10, "USD").quantize.fractional).to eq(10)
        expect(context.signals).to be_empty
      end
    end

    it "covers Money#round as explicit quantization" do
      enter_context do |context|
        Money.default_infinite_precision = true
        expect(Money.new(BigDecimal("10.1"), "USD").round.fractional).to eq(BigDecimal("10"))
        expect(context.signals).to eq([:rounded, :inexact])
      ensure
        Money.default_infinite_precision = false
      end
    end
  end

  describe "configuration" do
    it "applies the context rounding mode" do
      enter_context(rounding_mode: BigDecimal::ROUND_DOWN) do
        expect((Money.new(5, "USD") / 2).fractional).to eq(2)
      end

      enter_context(rounding_mode: BigDecimal::ROUND_UP) do
        expect((Money.new(5, "USD") / 2).fractional).to eq(3)
      end
    end

    it "falls back to Money.rounding_mode when none is configured" do
      Money.with_rounding_mode(BigDecimal::ROUND_DOWN) do
        enter_context do |context|
          expect(context.rounding_mode).to eq(BigDecimal::ROUND_DOWN)
          expect((Money.new(5, "USD") / 2).fractional).to eq(2)
        end
      end
    end

    it "quantizes to the context precision", :default_infinite_precision_true do
      enter_context(precision: 2) do |context|
        result = Money.new(1, "USD") / 3

        expect(result.fractional).to eq(BigDecimal("0.33"))
        expect(context.signals).to eq([:rounded, :inexact])
      end
    end

    it "rejects unknown trap signals" do
      expect { enter_context(traps: [:not_a_signal]) }.to raise_error(ArgumentError, /not_a_signal/)
    end
  end

  describe "traps" do
    it "raises InexactError only when the value actually changes" do
      expect { enter_context(traps: [:inexact]) { Money.new(1, "USD") / 3 } }
        .to raise_error(Money::ComputationContext::InexactError, /inexact/)

      expect { enter_context(traps: [:inexact]) { Money.new(6, "USD") / 3 } }
        .not_to raise_error

      expect { enter_context(traps: [:inexact]) { Money.new(100, "USD").quantize(-1) } }
        .not_to raise_error
    end

    it "raises RoundedError whenever digits are discarded, even without a value change" do
      expect { enter_context(traps: [:rounded]) { Money.new(100, "USD").quantize(-1) } }
        .to raise_error(Money::ComputationContext::RoundedError, /rounded/)

      expect { enter_context(traps: [:rounded]) { Money.new(6, "USD") / 3 } }
        .not_to raise_error
    end

    it "still records the trapped signal before raising" do
      enter_context(traps: [:inexact]) do |context|
        expect { Money.new(1, "USD") / 3 }.to raise_error(Money::ComputationContext::InexactError)
        expect(context.signals).to eq([:rounded, :inexact])
      end
    end
  end

  describe "nesting" do
    it "restores the outer context when the nested context exits" do
      enter_context(precision: 0) do |outer|
        enter_context(precision: 2, traps: [:inexact]) do |inner|
          expect(Money.computation_context).to equal(inner)
          expect { Money.new(1, "USD") / 3 }.to raise_error(Money::ComputationContext::InexactError)
        end

        expect(Money.computation_context).to equal(outer)
        expect(outer.signals).to be_empty

        Money.new(1, "USD") / 3
        expect(outer.signals).to eq([:rounded, :inexact])
      end

      expect(Money.computation_context).to be_nil
    end

    it "restores the previous context when the block raises" do
      enter_context do |outer|
        expect { enter_context { raise "boom" } }.to raise_error("boom")
        expect(Money.computation_context).to equal(outer)
      end

      expect(Money.computation_context).to be_nil
    end
  end

  describe "thread and fiber isolation" do
    it "is not visible inside other threads" do
      enter_context do
        expect(Thread.new { Money.computation_context }.value).to be_nil
      end
    end

    it "does not leak contexts entered in other threads" do
      thread = Thread.new do
        enter_context { Thread.current[:inside] = Money.computation_context }
        Money.computation_context
      end

      expect(thread.value).to be_nil
      expect(Money.computation_context).to be_nil
    end

    it "is not visible inside other fibers" do
      enter_context do
        expect(Fiber.new { Money.computation_context }.resume).to be_nil
      end
    end

    it "does not leak contexts entered in other fibers" do
      fiber = Fiber.new do
        enter_context { Fiber.yield Money.computation_context }
        Money.computation_context
      end

      expect(fiber.resume).to be_a(described_class)
      expect(Money.computation_context).to be_nil
      fiber.resume
      expect(Money.computation_context).to be_nil
    end
  end
end
