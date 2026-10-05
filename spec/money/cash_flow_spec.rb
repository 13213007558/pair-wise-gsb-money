# frozen_string_literal: true

RSpec.describe Money::CashFlow do
  let(:dates) { [Date.new(2025, 1, 1), Date.new(2026, 1, 1)] }
  let(:amounts) { [Money.new(-10_000, "USD"), Money.new(11_000, "USD")] }
  let(:flows_hash) { dates.zip(amounts).to_h }
  let(:flows_array) { dates.zip(amounts) }

  describe "#initialize" do
    it "accepts a hash of dates to amounts" do
      cash_flow = described_class.new(flows_hash)

      expect(cash_flow.dates).to eq(dates)
      expect(cash_flow.amounts).to eq(amounts)
      expect(cash_flow.currency.id).to eq(:usd)
    end

    it "accepts an array of date/amount pairs" do
      cash_flow = described_class.new(flows_array)

      expect(cash_flow.flows.map(&:first)).to eq(dates)
    end

    it "accepts a single date/amount pair via Money::CashFlow[]" do
      cash_flow = described_class[dates.first, amounts.first]

      expect(cash_flow.flows).to contain_exactly([dates.first, amounts.first])
    end

    it "sums amounts occurring on the same date" do
      cash_flow = described_class.new([
        [dates.first, Money.new(-6_000, "USD")],
        [dates.first, Money.new(-4_000, "USD")],
        [dates.last, Money.new(11_000, "USD")]
      ])

      expect(cash_flow.flows.map(&:first)).to eq(dates)
      expect(cash_flow.amounts.map(&:fractional)).to eq([-10_000, 11_000])
    end

    it "accepts DateTime values by converting them to dates" do
      cash_flow = described_class.new({
        DateTime.new(2025, 1, 1, 12) => Money.new(-100, "USD"),
        DateTime.new(2026, 1, 1, 12) => Money.new(110, "USD")
      })

      expect(cash_flow.dates).to eq(dates)
    end

    it "rejects mixed currencies without performing any exchange" do
      flows = {
        dates.first => Money.new(-100, "USD"),
        dates.last => Money.new(110, "EUR")
      }

      Money.with_bank(Money::Bank::SingleCurrency.instance) do
        expect { described_class.new(flows) }
          .to raise_error(described_class::InvalidCashFlow, /share one currency/)
      end
    end

    it "rejects non-Money amounts, non-dates and empty input" do
      expect { described_class.new([[dates.first, 5]]) }
        .to raise_error(described_class::InvalidCashFlow, /must be Money/)
      expect { described_class.new([["2025-01-01", amounts.first]]) }
        .to raise_error(described_class::InvalidCashFlow, /must be Dates/)
      expect { described_class.new({}) }
        .to raise_error(described_class::InvalidCashFlow, /at least one/)
    end

    it "rejects a valuation date later than the first cash flow" do
      expect { described_class.new(flows_hash, valuation_date: dates.last) }
        .to raise_error(described_class::InvalidCashFlow, /valuation date/)
    end
  end

  describe "#npv" do
    subject(:cash_flow) { described_class.new(flows_hash) }

    it "discounts at the selected constant annual rate" do
      expect(cash_flow.npv(0.1).fractional).to eq(0)
    end

    it "evaluates to zero at each internal rate of return" do
      result = cash_flow.xirr(-0.5...5.0)

      result.rates.each do |rate|
        expect(cash_flow.npv(rate).fractional.to_f.abs).to be < 1
      end
    end

    it "requires rates strictly above -1" do
      expect { cash_flow.npv(-1) }.to raise_error(ArgumentError, /greater than -1/)
      expect { cash_flow.npv(-1.5) }.to raise_error(ArgumentError, /greater than -1/)
    end
  end

  describe "day-count selection" do
    it "uses the caller-selected built-in convention" do
      cash_flow = described_class.new(flows_hash, :act_360)

      expect(cash_flow.year_fraction(dates.last)).to be_within(1e-15).of(365 / 360.0)
      expect(cash_flow.day_count_convention).to eq(:act_360)
    end

    it "accepts a custom callable convention" do
      cash_flow = described_class.new(
        flows_hash, ->(start_date, end_date) { (end_date - start_date) / 730.0 }
      )

      expect(cash_flow.year_fraction(dates.last)).to eq(0.5)
    end

    it "measures from an explicit earlier valuation date" do
      cash_flow = described_class.new(
        { Date.new(2026, 1, 1) => Money.new(-100, "USD"),
          Date.new(2027, 1, 1) => Money.new(110, "USD") },
        :act_365_fixed,
        valuation_date: Date.new(2025, 1, 1)
      )

      expect(cash_flow.year_fraction(Date.new(2026, 1, 1))).to eq(1.0)
      expect(cash_flow.year_fraction(Date.new(2027, 1, 1))).to eq(2.0)
    end
  end

  describe ".npv and .xirr" do
    it "exposes the valuation interface directly on Money" do
      expect(Money.npv(0.1, flows_hash).fractional).to eq(0)

      result = Money.xirr(flows_hash, -0.5...5.0)
      expect(result).to be_a(Money::CashFlow::Xirr::Result)
      expect(result.rates.first).to be_within(1e-7).of(0.1)
    end
  end
end
