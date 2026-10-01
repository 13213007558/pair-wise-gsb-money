# frozen_string_literal: true

RSpec.describe Money::Redenomination do
  # Fictional currencies: Old Alpha (XOA) is redenominated into New Alpha
  # (XNA) at 1000:1 on 2000-01-01, and XNA into New Beta (XNB) at 100:1 on
  # 2010-01-01, where cash is rounded to 5 cents.
  def register_currency(iso_code, subunit_to_unit)
    Money::Currency.register(
      iso_code: iso_code,
      name: "Fictional #{iso_code}",
      symbol: iso_code[0],
      subunit: "cent",
      subunit_to_unit: subunit_to_unit,
      separator: ".",
      delimiter: ",",
      priority: 1
    )
  end

  before do
    register_currency("XOA", 100)
    register_currency("XNA", 100)
    register_currency("XNB", 100)
  end

  after do
    described_class.reset!
    %w[XOA XNA XNB].each { |iso| Money::Currency.unregister(iso) }
  end

  let(:table) { described_class::Table.new }

  def register_chain(target)
    target.register(
      from: "XOA", to: "XNA", ratio: Rational(1, 1000),
      valid_from: Date.new(2000, 1, 1), valid_to: Date.new(2010, 1, 1)
    )
    target.register(
      from: "XNA", to: "XNB", ratio: Rational(1, 100),
      valid_from: Date.new(2010, 1, 1), cash_step: 5
    )
  end

  describe "rule registration" do
    it "rejects rules whose intervals overlap for the same currency" do
      table.register(from: "XOA", to: "XNA", ratio: Rational(1, 1000),
                     valid_from: Date.new(2000, 1, 1), valid_to: Date.new(2010, 1, 1))

      expect do
        table.register(from: "XOA", to: "XNB", ratio: Rational(1, 100),
                       valid_from: Date.new(2005, 1, 1), valid_to: Date.new(2015, 1, 1))
      end.to raise_error(described_class::OverlappingRuleError)
    end

    it "allows adjacent intervals that share a boundary day" do
      table.register(from: "XOA", to: "XNA", ratio: Rational(1, 1000),
                     valid_from: Date.new(2000, 1, 1), valid_to: Date.new(2010, 1, 1))

      expect do
        table.register(from: "XOA", to: "XNB", ratio: Rational(1, 100),
                       valid_from: Date.new(2010, 1, 1))
      end.not_to raise_error
    end

    it "rejects rules that would close a cycle" do
      table.register(from: "XOA", to: "XNA", ratio: Rational(1, 1000),
                     valid_from: Date.new(2000, 1, 1))
      table.register(from: "XNA", to: "XNB", ratio: Rational(1, 100),
                     valid_from: Date.new(2010, 1, 1))

      expect do
        table.register(from: "XNB", to: "XOA", ratio: 1,
                       valid_from: Date.new(2020, 1, 1))
      end.to raise_error(described_class::CyclicChainError)
    end

    it "rejects a second conversion path with an inconsistent ratio" do
      register_chain(table)

      expect do
        table.register(from: "XOA", to: "XNB", ratio: Rational(1, 50_000),
                       valid_from: Date.new(2020, 1, 1))
      end.to raise_error(described_class::InconsistentPathError)
    end

    it "accepts a redundant path whose composed ratio agrees" do
      register_chain(table)

      expect do
        table.register(from: "XOA", to: "XNB", ratio: Rational(1, 100_000),
                       valid_from: Date.new(2020, 1, 1))
      end.not_to raise_error
    end

    it "rejects Float ratios because they are inexact" do
      expect do
        table.register(from: "XOA", to: "XNA", ratio: 0.001,
                       valid_from: Date.new(2000, 1, 1))
      end.to raise_error(described_class::InvalidRuleError)
    end

    it "rejects inverted or empty intervals" do
      expect do
        table.register(from: "XOA", to: "XNA", ratio: Rational(1, 1000),
                       valid_from: Date.new(2010, 1, 1), valid_to: Date.new(2000, 1, 1))
      end.to raise_error(described_class::InvalidRuleError)
    end
  end

  describe "conversion" do
    before { register_chain(table) }

    it "converts across consecutive redenominations in one pass" do
      result = table.convert(Money.new(12_345_678, "XOA"), Date.new(2005, 6, 1))

      expect(result.converted?).to be(true)
      expect(result.rules.size).to eq(2)
      expect(result.currency).to eq(Money::Currency.new("XNB"))
      expect(result.exact_fractional).to eq(Rational(12_345_678, 100_000))
      # 123.45678 XNB cents rounded to the 5-cent cash step (half up)
      expect(result.money).to eq(Money.new(125, "XNB"))
      expect(result.remainder).to eq(Rational(12_345_678, 100_000) - 125)
    end

    it "keeps the exact remainder when the smallest unit cannot absorb it" do
      result = table.convert(Money.new(1, "XOA"), Date.new(2005, 6, 1))

      expect(result.money).to eq(Money.new(0, "XNB"))
      expect(result.exact_fractional).to eq(Rational(1, 100_000))
      expect(result.remainder).to eq(Rational(1, 100_000))
    end

    it "handles negative amounts symmetrically" do
      result = table.convert(Money.new(-12_345_678, "XOA"), Date.new(2005, 6, 1))

      expect(result.money).to eq(Money.new(-125, "XNB"))
      expect(result.remainder).to eq(125 - Rational(12_345_678, 100_000))
      expect(result.remainder).to be_positive
    end

    it "applies only the rules in effect on the given date" do
      result = table.convert(Money.new(12_345_678, "XOA"), Date.new(2005, 6, 1))
      expect(result.money.currency).to eq(Money::Currency.new("XNB"))

      early = table.convert(Money.new(12_345_678, "XOA"), Date.new(1999, 12, 31))
      expect(early.converted?).to be(false)
      expect(early.money).to eq(Money.new(12_345_678, "XOA"))
      expect(early.remainder).to eq(0)
    end

    it "uses the outgoing rule up to but not including its valid_to day" do
      # 2009-12-31: the XOA -> XNA rule is still in effect, so the amount
      # enters the chain there and follows it to the final currency
      result = table.convert(Money.new(1000, "XOA"), Date.new(2009, 12, 31))
      expect(result.rules.size).to eq(2)
      expect(result.money).to eq(Money.new(0, "XNB"))
      expect(result.remainder).to eq(Rational(1, 100))

      # 2010-01-01: the XOA rule has expired, XOA amounts stay untouched
      boundary = table.convert(Money.new(1000, "XOA"), Date.new(2010, 1, 1))
      expect(boundary.converted?).to be(false)
      expect(boundary.money).to eq(Money.new(1000, "XOA"))

      # 2010-01-01: the XNA -> XNB rule is in effect from its first day
      incoming = table.convert(Money.new(100, "XNA"), Date.new(2010, 1, 1))
      expect(incoming.money).to eq(Money.new(0, "XNB"))
      expect(incoming.remainder).to eq(1)
    end

    it "rounds to the cash step of the final era" do
      # 1 XNA unit = 100 XNA cents -> 1 XNB cent, snapped to the 5-cent step
      result = table.convert(Money.new(299, "XNA"), Date.new(2010, 1, 1))
      expect(result.exact_fractional).to eq(Rational(299, 100))
      expect(result.money).to eq(Money.new(5, "XNB"))
      expect(result.remainder).to eq(Rational(299, 100) - 5)
    end

    it "accepts string dates" do
      result = table.convert(Money.new(1000, "XOA"), "2005-06-01")
      expect(result.money).to eq(Money.new(0, "XNB"))
      expect(result.remainder).to eq(Rational(1, 100))
    end
  end

  describe "default table and Money#redenominate" do
    it "converts through the shared default table" do
      register_chain(described_class)

      result = Money.new(12_345_678, "XOA").redenominate(Date.new(2005, 6, 1))

      expect(result).to be_a(described_class::Result)
      expect(result.money).to eq(Money.new(125, "XNB"))
      expect(result.remainder).to eq(Rational(12_345_678, 100_000) - 125)
    end
  end

  describe "Money::Currency static registration" do
    it "keeps working alongside the redenomination table" do
      expect(Money::Currency.find("XOA")).to eq(Money::Currency.new("XOA"))
      expect(Money::Currency.find("XOA").subunit_to_unit).to eq(100)

      Money::Currency.register(iso_code: "XOC", name: "Other", subunit_to_unit: 5, priority: 1)
      expect(Money::Currency.find("XOC").subunit_to_unit).to eq(5)
      Money::Currency.unregister("XOC")
      expect(Money::Currency.find("XOC")).to be_nil
    end
  end
end
