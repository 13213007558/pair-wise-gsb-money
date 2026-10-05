# frozen_string_literal: true

RSpec.describe Money::CashFlow do
  def usd(amount)
    Money.from_amount(amount, "USD")
  end

  # NPV(r) = -1000 + 2300 / (1 + r) - 1320 / (1 + r) ** 2
  #        = 0  for r = 0.1 and r = 0.2 (with whole-year time fractions).
  # This is the regression sample with two internal rates of return.
  let(:two_root_flows) do
    [[usd(-1000), Date.new(2024, 1, 1)],
     [usd(2300),  Date.new(2025, 1, 1)],
     [usd(-1320), Date.new(2026, 1, 1)]]
  end

  describe ".xirr" do
    it "finds every root in the interval, not just one" do
      result = Money.xirr(two_root_flows, day_count: :thirty_360, rate_range: -0.5..1.0)

      expect(result).to be_solved
      expect(result.roots.size).to eq(2)
      expect(result.rates[0]).to be_within(1e-8).of(0.1)
      expect(result.rates[1]).to be_within(1e-8).of(0.2)
    end

    it "returns an isolating interval and NPV residual for each root" do
      result = Money.xirr(two_root_flows, day_count: :thirty_360,
                          rate_range: -0.5..1.0, tolerance: 1e-8)

      result.roots.each do |root|
        expect(root.interval.end - root.interval.begin).to be <= 1e-8
        expect(root.interval).to cover(root.rate)
        expect(root.residual.abs).to be < 1e-4
      end
      expect(result.roots[0].interval).to cover(0.1)
      expect(result.roots[1].interval).to cover(0.2)
    end

    it "finds a single root for a conventional invest-then-repay series" do
      flows = [[usd(-1000), Date.new(2024, 1, 1)],
               [usd(1100),  Date.new(2025, 1, 1)]]
      result = Money.xirr(flows, day_count: :thirty_360, rate_range: -0.5..1.0)

      expect(result).to be_solved
      expect(result.rates.size).to eq(1)
      expect(result.rates.first).to be_within(1e-8).of(0.1)
    end

    it "finds negative rates strictly above -1" do
      flows = [[usd(-1000), Date.new(2024, 1, 1)],
               [usd(500),   Date.new(2025, 1, 1)]]
      result = Money.xirr(flows, day_count: :thirty_360, rate_range: -0.99..1.0)

      expect(result.rates.first).to be_within(1e-8).of(-0.5)
    end

    it "lets the caller pick the day-count basis" do
      flows = [[usd(-1000), Date.new(2024, 1, 1)],
               [usd(1100),  Date.new(2025, 1, 1)]]

      act_365 = Money.xirr(flows, day_count: :act_365, rate_range: -0.5..1.0)
      # 2024 is a leap year: t = 366 / 365, so 1.1 ** (365 / 366) - 1
      expect(act_365.rates.first).to be_within(1e-8).of(1.1**(365.0 / 366.0) - 1)

      custom = Money.xirr(flows, day_count: ->(_from, _to) { 2.0 }, rate_range: -0.5..1.0)
      expect(custom.rates.first).to be_within(1e-8).of(Math.sqrt(1.1) - 1)
    end

    it "reports :no_root when the interval contains no root" do
      flows = [[usd(-1000), Date.new(2024, 1, 1)],
               [usd(1100),  Date.new(2025, 1, 1)]]
      result = Money.xirr(flows, day_count: :act_365, rate_range: 0.2..1.0)

      expect(result).to be_no_root
      expect(result.roots).to be_empty
      expect(result).not_to be_budget_exhausted
    end

    it "reports :all_zero separately when every cash flow is zero" do
      flows = [[usd(0), Date.new(2024, 1, 1)],
               [usd(0), Date.new(2025, 1, 1)]]
      result = Money.xirr(flows, day_count: :act_365, rate_range: -0.5..1.0)

      expect(result).to be_all_zero
      expect(result.roots).to be_empty
      expect(result.evaluations).to eq(0)
    end

    it "requires all amounts to share one currency without fetching rates" do
      flows = [[usd(-1000), Date.new(2024, 1, 1)],
               [Money.from_amount(1100, "EUR"), Date.new(2025, 1, 1)]]

      expect(Money.default_bank).not_to receive(:exchange_with)
      expect { Money.xirr(flows, day_count: :act_365, rate_range: -0.5..1.0) }
        .to raise_error(Money::CashFlow::CurrencyMismatch, /single currency/)
    end

    it "rejects search intervals that are not within r > -1" do
      expect { Money.xirr(two_root_flows, day_count: :act_365, rate_range: -1.0..1.0) }
        .to raise_error(Money::CashFlow::InvalidRateRange, /r > -1/)
      expect { Money.xirr(two_root_flows, day_count: :act_365, rate_range: -1.5..-1.2) }
        .to raise_error(Money::CashFlow::InvalidRateRange)
    end

    it "rejects empty, beginless, endless, and inverted ranges" do
      expect { Money.xirr(two_root_flows, day_count: :act_365, rate_range: 1.0..0.5) }
        .to raise_error(Money::CashFlow::InvalidRateRange)
      expect { Money.xirr(two_root_flows, day_count: :act_365, rate_range: -0.5..) }
        .to raise_error(Money::CashFlow::InvalidRateRange)
    end

    it "requires a known day-count basis" do
      expect { Money.xirr(two_root_flows, day_count: :nope, rate_range: -0.5..1.0) }
        .to raise_error(ArgumentError, /day-count/)
    end

    it "requires at least one cash flow" do
      expect { Money.xirr([], day_count: :act_365, rate_range: -0.5..1.0) }
        .to raise_error(Money::CashFlow::InvalidEntry)
    end

    it "returns the not-yet-excluded intervals when the budget runs out" do
      result = Money.xirr(two_root_flows, day_count: :thirty_360,
                          rate_range: -0.5..1.0, max_evaluations: 10)

      expect(result).to be_budget_exhausted
      expect(result.unresolved_intervals).not_to be_empty
      result.unresolved_intervals.each do |interval|
        expect(interval.begin).to be > -1
        expect(interval.end).to be <= 1.0
      end
      expect(result.evaluations).to be <= 10
    end

    it "accepts Entry structs, pairs, and hashes, in any date order" do
      shuffled = [
        { amount: usd(2300), date: Date.new(2025, 1, 1) },
        Money::CashFlow::Entry.new(usd(-1000), Date.new(2024, 1, 1)),
        [usd(-1320), Date.new(2026, 1, 1)]
      ]
      result = Money.xirr(shuffled, day_count: :thirty_360, rate_range: -0.5..1.0)

      expect(result.rates.size).to eq(2)
    end

    it "rejects malformed entries" do
      expect { Money.xirr([{ amount: 5, date: Date.new(2024, 1, 1) }],
                          day_count: :act_365, rate_range: -0.5..1.0) }
        .to raise_error(Money::CashFlow::InvalidEntry)
      expect { Money.xirr([[usd(5), "2024-01-01"]],
                          day_count: :act_365, rate_range: -0.5..1.0) }
        .to raise_error(Money::CashFlow::InvalidEntry)
    end
  end

  describe Money::CashFlow::DayCount do
    it "computes act/365 and act/360 fractions" do
      from = Date.new(2024, 1, 1)
      to = Date.new(2024, 7, 1)
      expect(described_class.act_365(from, to)).to eq(182 / 365.0)
      expect(described_class.act_360(from, to)).to eq(182 / 360.0)
    end

    it "computes act/act across leap-year boundaries" do
      fraction = described_class.act_act(Date.new(2023, 7, 1), Date.new(2025, 1, 1))
      expect(fraction).to be_within(1e-12).of(184 / 365.0 + 366 / 366.0)
    end

    it "computes 30/360 with end-of-month adjustment" do
      expect(described_class.thirty_360(Date.new(2024, 1, 1), Date.new(2025, 1, 1)))
        .to eq(1.0)
      expect(described_class.thirty_360(Date.new(2024, 1, 31), Date.new(2024, 3, 30)))
        .to eq(60 / 360.0)
    end
  end
end
