# frozen_string_literal: true

RSpec.describe Money::AmortizationSchedule do
  def schedule(principal, rate, payment, extra = {}, **options)
    extra_payments = extra.transform_values { |value| Money.usd(value) }
    described_class.new(Money.usd(principal), rate, Money.usd(payment), extra_payments, **options)
  end

  def rows(result, *fields)
    result.payments.map { |payment| fields.map { |field| payment.public_send(field) } }
  end

  def cents(rows)
    rows.map { |row| row.map(&:cents) }
  end

  def expect_conservation(result, principal)
    expect(result.total_payments).to eq(Money.usd(principal) + result.total_interest)
    expect(result.total_principal).to eq(Money.usd(principal))
    expect(result.ending_balance).to eq(Money.usd(0))
  end

  describe "manual schedules" do
    it "handles zero interest with a payment that does not divide the principal" do
      result = schedule(500, 0, 300)

      expect(result.status).to eq(:paid_off)
      expect(cents(rows(result, :interest, :principal, :ending_balance))).to eq(
        [[0, 300, 200], [0, 200, 0]],
      )
      expect(result.payoff_amount).to eq(Money.usd(200))
      expect_conservation(result, 500)
    end

    it "charges rounded interest and caps the final payment without a negative balance" do
      result = schedule(500, "0.015", 300)

      expect(result.status).to eq(:paid_off)
      expect(cents(rows(result, :interest, :principal, :ending_balance))).to eq(
        [[8, 292, 208], [3, 208, 0]],
      )
      remainders = rows(result, :interest_remainder_before, :interest_remainder_after)
      expect(remainders.map { |pair| pair.map { |value| format("%.2f", value) } }).to eq(
        [["0.00", "-0.50"], ["0.00", "0.12"]],
      )
      expect(rows(result, :payment).flatten.map(&:cents)).to eq([300, 211])
      expect(result.payoff_amount).to eq(Money.usd(211))
      expect(result.ending_balance).not_to be_negative
      expect_conservation(result, 500)
    end

    it "keeps the uncharged fractional interest remainder when requested" do
      result = schedule(500, "0.015", 300, carry_interest_remainder: true)

      expect(result.status).to eq(:paid_off)
      expect(
        rows(result, :interest, :interest_remainder_after).map do |interest, remainder|
          [interest.cents, format("%.2f", remainder)]
        end,
      ).to eq([[8, "-0.50"], [3, "-0.38"]])
      expect(result.interest_remainder).to eq(BigDecimal("-0.38"))
      expect_conservation(result, 500)
    end

    it "keeps fractional cents without rounding when infinite precision is enabled",
       :default_infinite_precision_true do
      result = schedule(BigDecimal("500"), "0.015", BigDecimal("300"))

      expect(result.status).to eq(:paid_off)
      expect(rows(result, :interest, :principal, :ending_balance).map { |row| row.map(&:to_d) }).to eq(
        [
          [BigDecimal("0.075"), BigDecimal("2.925"), BigDecimal("2.075")],
          [BigDecimal("0.031125"), BigDecimal("2.075"), BigDecimal("0")],
        ],
      )
      expect(result.payoff_amount.to_d).to eq(BigDecimal("2.106125"))
      expect(result.total_payments.to_d).to eq(BigDecimal("5.106125"))
    end

    it "applies a mid-term extra payment to shorten the term" do
      result = schedule(1000, "0.01", 300, { 2 => 300 })

      expect(result.status).to eq(:paid_off)
      expect(cents(rows(result, :interest, :extra_payment, :principal, :ending_balance))).to eq(
        [[10, 0, 290, 710], [7, 300, 593, 117], [1, 0, 117, 0]],
      )
      expect(result.payments.last.scheduled_regular_payment).to eq(Money.usd(300))
      expect(result.payoff_amount).to eq(Money.usd(118))
      expect_conservation(result, 1000)
    end

    it "recasts the remaining fixed payment while preserving the original term" do
      result = schedule(1000, "0.01", 300, { 2 => 300 }, extra_payment_strategy: :recast_payment)

      expect(result.status).to eq(:paid_off)
      expect(result.payments.size).to eq(4)
      fields = [:interest, :regular_payment, :extra_payment, :principal, :ending_balance]
      expect(cents(rows(result, *fields))).to eq(
        [
          [10, 300, 0, 290, 710],
          [7, 300, 300, 593, 117],
          [1, 60, 0, 59, 58],
          [1, 59, 0, 58, 0],
        ],
      )
      expect(result.payoff_amount).to eq(Money.usd(59))
      expect_conservation(result, 1000)
    end
  end

  describe "insufficient payments" do
    it "returns negative amortization instead of looping forever" do
      result = schedule(1000, "0.02", 10)

      expect(result.status).to eq(:negative_amortization)
      expect(result).to be_negative_amortization
      expect(result).not_to be_paid_off
      expect(result.payments.size).to eq(1)
      expect(result.payments.first.interest).to eq(Money.usd(20))
      expect(result.payments.first.principal).to eq(Money.usd(-10))
      expect(result.payments.first.ending_balance).to eq(Money.usd(1010))
    end

    it "stops an interest-only schedule when no future extra payment can reduce principal" do
      result = schedule(500, "0.02", 10)

      expect(result.status).to eq(:interest_only)
      expect(result.payments.size).to eq(1)
      expect(result.payments.first.principal).to eq(Money.usd(0))
      expect(result.payments.first.ending_balance).to eq(Money.usd(500))
    end

    it "continues through interest-only periods toward a scheduled extra payment" do
      result = schedule(500, "0.02", 10, { 2 => 600 })

      expect(result.status).to eq(:paid_off)
      expect(result.payments.size).to eq(2)
      expect(result.payments.first.principal).to eq(Money.usd(0))
      expect(result.payments.last.principal).to eq(Money.usd(500))
    end
  end

  describe "validation" do
    it "rejects non-Money amounts" do
      expect { described_class.new(500, "0.01", Money.usd(100)) }.to raise_error(
        ArgumentError, /must be a Money/
      )
      expect { described_class.new(Money.usd(500), "0.01", 100) }.to raise_error(
        ArgumentError, /must be a Money/
      )
    end

    it "rejects negative rates, non-positive amounts, and mismatched currencies" do
      expect { schedule(0, "0.01", 100) }.to raise_error(ArgumentError, /principal/)
      expect { schedule(500, BigDecimal("-0.01"), 100) }.to raise_error(ArgumentError, /periodic_rate/)
      expect { schedule(500, "0.01", 0) }.to raise_error(ArgumentError, /regular_payment/)
      expect { described_class.new(Money.usd(500), "0.01", Money.eur(100)) }.to raise_error(
        ArgumentError, /currency/
      )
    end

    it "rejects invalid extra payment periods" do
      expect do
        described_class.new(Money.usd(500), 0, Money.usd(100), { 0 => Money.usd(10) })
      end.to raise_error(ArgumentError, /positive integers/)
    end
  end
end
