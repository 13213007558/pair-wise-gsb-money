# frozen_string_literal: true

RSpec.describe Money::Amortization do
  def usd(cents)
    Money.new(cents, "USD")
  end

  def fractions(rows, field)
    rows.map { |row| row.public_send(field).fractional }
  end

  describe "hand-verifiable schedules" do
    context "with a zero rate" do
      # $1,000.00 at 0% with $250.00 payments: pure principal paydown.
      subject(:schedule) do
        described_class.new(
          principal: usd(100_000), rate: 0, payment: usd(25_000)
        ).schedule
      end

      it "pays off in 4 equal periods with no interest" do
        expect(schedule.status).to eq(:paid_off)
        expect(schedule.term).to eq(4)
        expect(fractions(schedule.rows, :interest)).to eq([0, 0, 0, 0])
        expect(fractions(schedule.rows, :principal)).to eq([25_000, 25_000, 25_000, 25_000])
        expect(fractions(schedule.rows, :balance)).to eq([75_000, 50_000, 25_000, 0])
        expect(schedule.rows.last.status).to eq(:payoff)
      end

      it "conserves funds" do
        expect(schedule.total_interest).to eq(usd(0))
        expect(schedule.total_principal).to eq(usd(100_000))
        expect(schedule.total_payment).to eq(usd(100_000))
        expect(schedule.payoff_amount).to eq(usd(25_000))
        expect(schedule).to be_balanced
      end
    end

    context "with a payment that does not divide evenly" do
      # $100.00 at 1% per period with $30.00 payments:
      #   P1: interest 1.00, principal 29.00, balance 71.00
      #   P2: interest 0.71, principal 29.29, balance 41.71
      #   P3: interest 0.4171 -> 0.42, principal 29.58, balance 12.13
      #   P4: interest 0.1184 -> 0.12, payoff 12.25, balance 0.00
      subject(:schedule) do
        described_class.new(
          principal: usd(10_000), rate: BigDecimal("0.01"), payment: usd(3_000),
          rounding_mode: BigDecimal::ROUND_HALF_UP
        ).schedule
      end

      it "matches the hand-computed rows" do
        expect(schedule.term).to eq(4)
        expect(fractions(schedule.rows, :interest)).to eq([100, 71, 42, 12])
        expect(fractions(schedule.rows, :principal)).to eq([2_900, 2_929, 2_958, 1_213])
        expect(fractions(schedule.rows, :balance)).to eq([7_100, 4_171, 1_213, 0])
      end

      it "caps the final payment at the exact payoff amount" do
        expect(schedule.payoff_amount).to eq(usd(1_225))
        expect(schedule.rows.last.payment).to eq(usd(1_225))
        expect(schedule.rows.last.balance).to eq(usd(0))
      end

      it "conserves funds: payments == principal + interest" do
        expect(schedule.total_interest).to eq(usd(225))
        expect(schedule.total_principal).to eq(usd(10_000))
        expect(schedule.total_payment).to eq(usd(10_225))
        expect(schedule).to be_balanced
      end
    end

    context "with a mid-term prepayment shortening the term" do
      # $500.00 at 1% per period, $100.00 payments, $200.00 extra in period 2:
      #   P1: interest 5.00, principal 95.00, balance 405.00
      #   P2: interest 4.05, principal 95.95 + 200.00 extra, balance 109.05
      #   P3: interest 1.0905 -> 1.09, principal 98.91, balance 10.14
      #   P4: interest 0.1019 -> 0.10, payoff 10.24, balance 0.00
      subject(:schedule) do
        described_class.new(
          principal: usd(50_000), rate: BigDecimal("0.01"), payment: usd(10_000),
          extra_payments: { 2 => usd(20_000) },
          rounding_mode: BigDecimal::ROUND_HALF_UP
        ).schedule
      end

      it "matches the hand-computed rows" do
        expect(schedule.term).to eq(4)
        expect(fractions(schedule.rows, :interest)).to eq([500, 405, 109, 10])
        expect(fractions(schedule.rows, :principal)).to eq([9_500, 29_595, 9_891, 1_014])
        expect(fractions(schedule.rows, :extra_payment)).to eq([0, 20_000, 0, 0])
        expect(fractions(schedule.rows, :payment)).to eq([10_000, 30_000, 10_000, 1_024])
        expect(fractions(schedule.rows, :balance)).to eq([40_500, 10_905, 1_014, 0])
      end

      it "conserves funds" do
        expect(schedule.total_interest).to eq(usd(1_024))
        expect(schedule.total_principal).to eq(usd(50_000))
        expect(schedule.total_payment).to eq(usd(51_024))
        expect(schedule.payoff_amount).to eq(usd(1_024))
        expect(schedule).to be_balanced
      end
    end
  end

  describe "sub-subunit interest residue" do
    # $1.00 at 0.4% per period with $0.10 payments. Each period's exact
    # interest is a fraction of a cent, so the residue policy decides whether
    # any interest is ever charged.
    let(:base_options) do
      {
        principal: usd(100), rate: BigDecimal("0.004"), payment: usd(10),
        rounding_mode: BigDecimal::ROUND_HALF_UP
      }
    end

    it "carries the residue into later periods by default" do
      schedule = described_class.new(**base_options).schedule

      expect(schedule.term).to eq(11)
      expect(fractions(schedule.rows, :interest)).to eq([0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
      expect(schedule.total_interest).to eq(usd(2))
      expect(schedule.total_payment).to eq(usd(102))
      expect(schedule.payoff_amount).to eq(usd(2))
      expect(schedule).to be_balanced
    end

    it "discards the residue when carry_remainder is false" do
      schedule = described_class.new(**base_options, carry_remainder: false).schedule

      expect(schedule.term).to eq(10)
      expect(fractions(schedule.rows, :interest)).to eq(Array.new(10, 0))
      expect(schedule.total_interest).to eq(usd(0))
      expect(schedule.total_payment).to eq(usd(100))
      expect(schedule).to be_balanced
    end

    it "exposes the residue carried out of each period" do
      schedule = described_class.new(**base_options).schedule

      expect(schedule.rows[0].interest_residue).to eq(BigDecimal("0.4"))
      expect(schedule.rows[1].interest_residue).to eq(BigDecimal("-0.24"))
    end
  end

  describe "extra payment modes" do
    context "with :recast at a zero rate" do
      # $1,000.00 at 0%, $100.00 payments (term 10), $500.00 extra in period 2.
      # After the extra payment the remaining $300.00 is spread over the
      # remaining 8 periods: $37.50 each.
      subject(:schedule) do
        described_class.new(
          principal: usd(100_000), rate: 0, payment: usd(10_000),
          extra_payments: { 2 => usd(50_000) },
          extra_payment_mode: :recast
        ).schedule
      end

      it "keeps the original term and recomputes the fixed payment" do
        expect(schedule.term).to eq(10)
        expect(fractions(schedule.rows, :payment)).to eq(
          [10_000, 60_000, *Array.new(8, 3_750)]
        )
        expect(fractions(schedule.rows, :balance).last).to eq(0)
      end

      it "conserves funds" do
        expect(schedule.total_principal).to eq(usd(100_000))
        expect(schedule.total_payment).to eq(usd(100_000))
        expect(schedule).to be_balanced
      end
    end

    context "with :recast at a positive rate" do
      # $1,000.00 at 1% per period, $100.00 payments (term 11),
      # $200.00 extra in period 3. The exact recast payment for the remaining
      # 8 periods is $68.9117, rounded up to $68.92 so the loan still matures
      # at period 11; the final payment adjusts down to $68.85.
      subject(:schedule) do
        described_class.new(
          principal: usd(100_000), rate: BigDecimal("0.01"), payment: usd(10_000),
          extra_payments: { 3 => usd(20_000) },
          extra_payment_mode: :recast,
          rounding_mode: BigDecimal::ROUND_HALF_UP
        ).schedule
      end

      it "recomputes the payment and keeps the original term" do
        expect(schedule.term).to eq(11)
        expect(fractions(schedule.rows, :payment)).to eq(
          [10_000, 10_000, 30_000, *Array.new(7, 6_892), 6_885]
        )
        expect(schedule.payoff_amount).to eq(usd(6_885))
      end

      it "conserves funds" do
        expect(schedule.total_interest).to eq(usd(5_129))
        expect(schedule.total_principal).to eq(usd(100_000))
        expect(schedule.total_payment).to eq(usd(105_129))
        expect(schedule).to be_balanced
      end
    end

    it "caps an extra payment at the payoff amount" do
      schedule = described_class.new(
        principal: usd(10_000), rate: 0, payment: usd(5_000),
        extra_payments: { 1 => usd(999_999) }
      ).schedule

      expect(schedule.term).to eq(1)
      expect(schedule.rows.first.extra_payment).to eq(usd(5_000))
      expect(schedule.rows.first.payment).to eq(usd(10_000))
      expect(schedule.total_payment).to eq(usd(10_000))
      expect(schedule).to be_balanced
    end
  end

  describe "negative amortization" do
    # $1,000.00 at 1% per period accrues $10.00 of interest, but the
    # payment is only $5.00.
    let(:base_options) do
      { principal: usd(100_000), rate: BigDecimal("0.01"), payment: usd(500) }
    end

    it "stops with a :negative_amortization status by default" do
      schedule = described_class.new(**base_options).schedule

      expect(schedule.status).to eq(:negative_amortization)
      expect(schedule).not_to be_paid_off
      expect(schedule).to be_negative_amortization
      expect(schedule.payoff_amount).to be_nil
      expect(schedule.term).to eq(1)

      row = schedule.rows.first
      expect(row.status).to eq(:negative_amortization)
      expect(row.interest).to eq(usd(1_000))
      expect(row.payment).to eq(usd(500))
      expect(row.balance).to eq(usd(100_000))
    end

    it "capitalizes unpaid interest when configured, bounded by max_periods" do
      schedule = described_class.new(
        **base_options, on_negative_amortization: :capitalize, max_periods: 3,
        rounding_mode: BigDecimal::ROUND_HALF_UP
      ).schedule

      expect(schedule.status).to eq(:max_periods_exceeded)
      expect(schedule).to be_negative_amortization
      expect(schedule.term).to eq(3)
      expect(fractions(schedule.rows, :interest)).to eq([1_000, 1_005, 1_010])
      expect(fractions(schedule.rows, :principal)).to eq([-500, -505, -510])
      expect(fractions(schedule.rows, :balance)).to eq([100_500, 101_005, 101_515])
    end

    it "never loops forever when the payment exactly covers interest" do
      schedule = described_class.new(
        principal: usd(100_000), rate: BigDecimal("0.01"), payment: usd(1_000),
        max_periods: 5
      ).schedule

      expect(schedule.status).to eq(:max_periods_exceeded)
      expect(schedule.term).to eq(5)
      expect(schedule.rows.last.balance).to eq(usd(100_000))
    end
  end

  describe "validation" do
    it "rejects a non-positive principal" do
      expect { described_class.new(principal: usd(0), rate: 0, payment: usd(1)) }
        .to raise_error(ArgumentError, /principal/)
    end

    it "rejects a non-positive payment" do
      expect { described_class.new(principal: usd(1), rate: 0, payment: usd(0)) }
        .to raise_error(ArgumentError, /payment/)
    end

    it "rejects a negative rate" do
      expect { described_class.new(principal: usd(1), rate: -0.01, payment: usd(1)) }
        .to raise_error(ArgumentError, /rate/)
    end

    it "rejects mismatched currencies" do
      expect do
        described_class.new(principal: usd(1), rate: 0, payment: Money.new(1, "EUR"))
      end.to raise_error(ArgumentError, /currency/)

      expect do
        described_class.new(
          principal: usd(100), rate: 0, payment: usd(1),
          extra_payments: { 1 => Money.new(1, "EUR") }
        )
      end.to raise_error(ArgumentError, /currency/)
    end

    it "rejects unknown modes" do
      expect do
        described_class.new(principal: usd(1), rate: 0, payment: usd(1), extra_payment_mode: :unknown_mode)
      end.to raise_error(ArgumentError, /extra payment mode/)

      expect do
        described_class.new(principal: usd(1), rate: 0, payment: usd(1), on_negative_amortization: :unknown_mode)
      end.to raise_error(ArgumentError, /negative amortization mode/)
    end

    it "rejects recast when the payment cannot amortize the loan" do
      expect do
        described_class.new(
          principal: usd(100_000), rate: BigDecimal("0.01"), payment: usd(500),
          extra_payment_mode: :recast
        ).schedule
      end.to raise_error(ArgumentError, /never amortizes/)
    end
  end
end
