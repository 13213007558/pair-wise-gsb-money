# frozen_string_literal: true

require "money/cash_flow/day_count"

RSpec.describe Money::CashFlow::DayCount do
  describe ".fetch" do
    it "returns a callable for each built-in convention" do
      described_class::CONVENTIONS.each do |convention|
        expect(described_class.fetch(convention)).to respond_to(:call)
      end
    end

    it "accepts an arbitrary callable" do
      callable = ->(start_date, end_date) { (end_date - start_date) / 360.0 }

      expect(described_class.fetch(callable)).to be(callable)
    end

    it "rejects unknown conventions" do
      expect { described_class.fetch(:not_a_day_count) }
        .to raise_error(ArgumentError, /unknown day-count convention/)
    end
  end

  describe "year fractions" do
    let(:start_date) { Date.new(2025, 1, 1) }
    let(:end_date) { Date.new(2026, 1, 1) }

    it "computes act/365 fixed as exactly one year on a 365-day gap" do
      expect(described_class.act_365_fixed(start_date, end_date)).to eq(1.0)
    end

    it "computes act/360 as 365/360 on a 365-day gap" do
      expect(described_class.act_360(start_date, end_date)).to be_within(1e-15).of(365 / 360.0)
    end

    it "computes 30/360 US and 30E/360 as exactly one year" do
      expect(described_class.thirty_360_us(start_date, end_date)).to eq(1.0)
      expect(described_class.thirty_e_360(start_date, end_date)).to eq(1.0)
    end

    it "splits act/act ISDA on year boundaries using leap-year lengths" do
      fraction = described_class.act_act_isda(
        Date.new(2024, 1, 1), Date.new(2025, 3, 1)
      )

      expect(fraction).to be_within(1e-15).of(1.0 + 59 / 365.0)
    end

    it "applies the US February end-of-month rule on both sides" do
      fraction = described_class.thirty_360_us(
        Date.new(2024, 2, 29), Date.new(2025, 2, 28)
      )

      expect(fraction).to eq(1.0)
    end

    it "moves a 31st to the 30th under 30E/360" do
      fraction = described_class.thirty_e_360(
        Date.new(2025, 1, 31), Date.new(2025, 3, 31)
      )

      expect(fraction).to be_within(1e-15).of(60 / 360.0)
    end

    it "returns zero for identical dates" do
      expect(described_class.act_act_isda(start_date, start_date)).to eq(0.0)
    end
  end
end
