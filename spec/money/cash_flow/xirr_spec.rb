# frozen_string_literal: true

RSpec.describe Money::CashFlow::Xirr do
  # Regression cash flow: with exactly 365-day gaps the NPV polynomial is
  # -10_000 + 25_000*x - 15_000*x^2 = -5_000(3x - 1)(x - 1), which has two
  # internal rates of return: 0% and 50%.
  let(:two_rates_flows) do
    {
      Date.new(2025, 1, 1) => Money.new(-10_000, "USD"),
      Date.new(2026, 1, 1) => Money.new(25_000, "USD"),
      Date.new(2027, 1, 1) => Money.new(-15_000, "USD")
    }
  end

  # NPV polynomial -100 + 200*x - 100*x^2 = -100*(x-1)^2: a double root at 0%
  # where NPV never changes sign. A sign-sampling solver cannot find it.
  let(:double_root_flows) do
    {
      Date.new(2025, 1, 1) => Money.new(-10_000, "USD"),
      Date.new(2026, 1, 1) => Money.new(20_000, "USD"),
      Date.new(2027, 1, 1) => Money.new(-10_000, "USD")
    }
  end

  let(:single_root_flows) do
    {
      Date.new(2025, 1, 1) => Money.new(-10_000, "USD"),
      Date.new(2026, 1, 1) => Money.new(11_000, "USD")
    }
  end

  describe "cash flows with several internal rates of return" do
    subject(:result) { Money::CashFlow.new(two_rates_flows).xirr(-0.5...5.0) }

    it "returns every rate in the range, not one arbitrary convergence" do
      expect(result).to be_complete
      expect(result.status).to eq(:ok)
      expect(result.rates.size).to eq(2)
      expect(result.rates).to contain_exactly(
        a_value_within(1e-7).of(0.0),
        a_value_within(1e-7).of(0.5)
      )
    end

    it "isolates each root in its own bracket" do
      result.all_roots.each do |root|
        expect(root.low).to be <= root.rate
        expect(root.rate).to be <= root.high
        expect(root.high - root.low).to be <= 1e-7
      end

      brackets = result.all_roots.map { |root| [root.low, root.high] }
      expect(brackets.uniq.size).to eq(2)
      expect(brackets.first.last).to be <= brackets.last.first
    end

    it "reports the NPV residual at each reported rate" do
      result.all_roots.each do |root|
        expect(root.residual).to be_a(Money)
        expect(root.residual.currency).to eq(Money::Currency.new("USD"))
        expect(root.residual.fractional.abs.to_f).to be < 1
      end
    end

    it "counts NPV evaluations against the budget" do
      expect(result.evaluations).to be < result.budget
      expect(result.evaluations).to be > 0
    end

    it "excludes an upper-bound root for a three-dot range" do
      open = Money::CashFlow.new(two_rates_flows).xirr(-0.5...0.5)
      closed = Money::CashFlow.new(two_rates_flows).xirr(-0.5..0.5)

      expect(open.rates).to contain_exactly(a_value_within(1e-7).of(0.0))
      expect(closed.rates).to contain_exactly(
        a_value_within(1e-7).of(0.0),
        a_value_within(1e-7).of(0.5)
      )
    end
  end

  describe "multiple (tangent) roots" do
    subject(:result) { Money::CashFlow.new(double_root_flows).xirr(-0.5...5.0) }

    it "reports the tangent root separately from sign-changing roots" do
      expect(result.roots).to be_empty
      expect(result.multiple_roots.size).to eq(1)
      expect(result.multiple_roots.first.rate).to be_within(1e-7).of(0.0)
      expect(result.multiple_roots.first).to be_multiple
      expect(result.status).to eq(:ok)
    end

    it "gives the multiple root its own interval and a near-zero residual" do
      root = result.multiple_roots.first

      expect(root.low..root.high).to cover(root.rate)
      expect(root.residual.fractional.abs.to_f).to be <= 1
    end

    it "does not misclassify an ordinary sign-changing root as multiple" do
      single = Money::CashFlow.new(single_root_flows).xirr(-0.5...5.0)

      expect(single.multiple_roots).to be_empty
      expect(single.roots.size).to eq(1)
      expect(single.roots.first.rate).to be_within(1e-7).of(0.1)
    end
  end

  describe "cash flows without roots" do
    it "reports :no_roots when all amounts have the same sign" do
      flows = {
        Date.new(2025, 1, 1) => Money.new(-100, "USD"),
        Date.new(2026, 1, 1) => Money.new(-100, "USD")
      }

      result = Money::CashFlow.new(flows).xirr(-0.5...5.0)

      expect(result.status).to eq(:no_roots)
      expect(result.all_roots).to be_empty
      expect(result.unresolved_intervals).to be_empty
      expect(result).to be_complete
    end

    it "reports :no_roots for a single non-zero cash flow" do
      result = Money::CashFlow.new(
        [[Date.new(2025, 1, 1), Money.new(100, "USD")]]
      ).xirr(-0.5...5.0)

      expect(result.status).to eq(:no_roots)
    end
  end

  describe "all-zero cash flows" do
    it "reports :all_zero for explicit zero amounts" do
      flows = {
        Date.new(2025, 1, 1) => Money.new(0, "USD"),
        Date.new(2026, 1, 1) => Money.new(0, "USD")
      }

      result = Money::CashFlow.new(flows).xirr(-0.5...5.0)

      expect(result.status).to eq(:all_zero)
      expect(result.all_roots).to be_empty
      expect(result).to be_complete
    end

    it "reports :all_zero when same-date amounts cancel" do
      flows = [
        [Date.new(2025, 1, 1), Money.new(100, "USD")],
        [Date.new(2025, 1, 1), Money.new(-100, "USD")]
      ]

      cash_flow = Money::CashFlow.new(flows)
      expect(cash_flow).to be_all_zero
      expect(cash_flow.xirr(-0.5...5.0).status).to eq(:all_zero)
    end

    it "reports :no_roots when same-date amounts leave a non-zero constant" do
      flows = [
        [Date.new(2025, 1, 1), Money.new(100, "USD")],
        [Date.new(2025, 1, 1), Money.new(-60, "USD")]
      ]

      result = Money::CashFlow.new(flows).xirr(-0.5...5.0)
      expect(result.status).to eq(:no_roots)
    end
  end

  describe "search domain and budget" do
    let(:cash_flow) { Money::CashFlow.new(single_root_flows) }

    it "requires bounds strictly above -1" do
      expect { cash_flow.xirr(-2.0...5.0) }.to raise_error(ArgumentError, /greater than -1/)
      expect { cash_flow.xirr(low: -1, high: 5) }.to raise_error(ArgumentError, /greater than -1/)
    end

    it "requires ordered bounds" do
      expect { cash_flow.xirr(5.0..-0.5) }.to raise_error(ArgumentError, /low < high/)
    end

    it "requires a positive integer budget" do
      expect { cash_flow.xirr(-0.5...5.0, budget: 3) }
        .to raise_error(ArgumentError, /budget/)
      expect { cash_flow.xirr(-0.5...5.0, budget: 100.0) }
        .to raise_error(ArgumentError, /budget/)
    end

    it "returns the intervals not yet excluded when the budget runs out" do
      result = cash_flow.xirr(-0.99...1_000_000.0, budget: 8)

      expect(result.status).to eq(:budget_exhausted)
      expect(result).not_to be_complete
      expect(result.evaluations).to be <= 9
      expect(result.unresolved_intervals).not_to be_empty
      result.unresolved_intervals.each do |interval|
        expect(interval.low).to be >= -0.99
        expect(interval.high).to be <= 1_000_000.0
        expect(interval.reason).to eq(:budget)
      end
    end

    it "still finds an ordinary root inside the default wide domain" do
      result = cash_flow.xirr(-0.99...1_000_000.0)

      expect(result.status).to eq(:ok)
      expect(result.unresolved_intervals).to be_empty
      expect(result.rates).to contain_exactly(a_value_within(1e-7).of(0.1))
    end

    it "accepts explicit keyword bounds" do
      result = cash_flow.xirr(low: -0.5, high: 5.0)

      expect(result.rates).to contain_exactly(a_value_within(1e-7).of(0.1))
    end

    it "uses a default r > -1 range when no bounds are supplied" do
      result = cash_flow.xirr

      expect(result.low).to eq(-0.9999)
      expect(result.high).to eq(10.0)
      expect(result.rates).to contain_exactly(a_value_within(1e-7).of(0.1))
    end

    it "requires both bounds when only one is given as a keyword" do
      expect { cash_flow.xirr(low: -0.5) }.to raise_error(ArgumentError, /both low: and high:/)
    end
  end
end
