# frozen_string_literal: true

RSpec.describe Money::Redenomination do
  before do
    {
      "HRA" => { subunit_to_unit: 1000, smallest_denomination: 10 },
      "HRB" => { subunit_to_unit: 100, smallest_denomination: 5 },
      "HRC" => { subunit_to_unit: 100, smallest_denomination: 10 },
      "HRD" => { subunit_to_unit: 10, smallest_denomination: 1 },
    }.each do |code, attributes|
      Money::Currency.register(
        priority: 10_000,
        iso_code: code,
        iso_numeric: "",
        name: code,
        symbol: code,
        alternate_symbols: [],
        subunit: "Minor unit",
        subunit_to_unit: attributes[:subunit_to_unit],
        symbol_first: false,
        html_entity: "",
        decimal_mark: ".",
        thousands_separator: ",",
        smallest_denomination: attributes[:smallest_denomination],
      )
    end
  end

  after do
    %w[HRA HRB HRC HRD].each do |code|
      Money::Currency.unregister(code) if Money::Currency.find(code)
    end
  end

  let(:rules) do
    [
      {
        from_currency: "HRA",
        to_currency: "HRB",
        ratio: Rational(1, 1000),
        effective_from: "2000-01-01",
        effective_to: nil,
      },
      {
        from_currency: "HRB",
        to_currency: "HRC",
        ratio: Rational(1, 10),
        effective_from: "2010-01-01",
        effective_to: nil,
      },
    ]
  end
  let(:table) { described_class::Table.new(rules) }

  describe "continuous redenomination" do
    it "chains exact ratios across multiple effective dates" do
      result = table.redenominate(Money.new(123_456_000, "HRA"), date: "2000-01-01")

      expect(result.money).to eq(Money.new(1234, "HRC"))
      expect(result.remainder).to eq(Rational(14, 25))
      expect(result.cash).to eq(Money.new(1230, "HRC"))
      expect(result.exact_amount).to eq(Rational(7716, 625))
      expect(result.applied_rules.map { |rule| rule.to_currency.upcase }).to eq(%w[HRB HRC])
    end

    it "preserves a signed truncation remainder for negative accounts" do
      result = table.redenominate(Money.new(-123_456_000, "HRA"), date: "2000-01-01")

      expect(result.money).to eq(Money.new(-1234, "HRC"))
      expect(result.remainder).to eq(-Rational(14, 25))
      expect(result.cash).to eq(Money.new(-1240, "HRC"))
    end

    it "uses a rule starting on a boundary date instead of a rule ending there" do
      bounded = rules.map(&:dup)
      bounded[0][:effective_to] = "2010-01-01"
      bounded_table = described_class::Table.new(bounded)

      result = bounded_table.redenominate(Money.new(1000, "HRB"), date: "2010-01-01")

      expect(result.money).to eq(Money.new(100, "HRC"))
      expect(result.applied_rules.map { |rule| [rule.from_currency.upcase, rule.effective_from.to_s] })
        .to eq([%w[HRB 2010-01-01]])

      expect do
        bounded_table.redenominate(Money.new(10_000_000, "HRA"), date: "2010-01-01")
      end.to raise_error(described_class::MissingPath)
    end

    it "can stop at an explicitly requested currency" do
      result = table.redenominate(Money.new(100_000, "HRA"), date: "2000-01-01", to_currency: "HRB")

      expect(result.money).to eq(Money.new(10, "HRB"))
      expect(result.remainder).to eq(0)
      expect(result.applied_rules.map { |rule| rule.to_currency.upcase }).to eq(["HRB"])
    end

    it "is also available from Money without consulting its bank" do
      Money.disallow_currency_conversion!
      result = Money.new(100_000, "HRA").redenominate(table, date: Date.new(2000, 1, 1))

      expect(result.money.currency).to eq(Money::Currency.new("HRC"))
    ensure
      Money.setup_defaults
    end
  end

  describe "rule validation" do
    it "rejects overlapping effective intervals" do
      invalid = rules + [
        {
          from_currency: "HRB",
          to_currency: "HRC",
          ratio: Rational(1, 20),
          effective_from: "2009-06-01",
          effective_to: nil,
        },
      ]

      expect { described_class::Table.new(invalid) }
        .to raise_error(described_class::OverlappingRules)
    end

    it "rejects cycles" do
      invalid = rules + [
        {
          from_currency: "HRC",
          to_currency: "HRA",
          ratio: 1,
          effective_from: "2020-01-01",
          effective_to: nil,
        },
      ]

      expect { described_class::Table.new(invalid) }
        .to raise_error(described_class::CircularChain)
    end

    it "rejects a rule whose source and destination are the same currency" do
      invalid = rules + [
        {
          from_currency: "HRC",
          to_currency: "HRC",
          ratio: 1,
          effective_from: "2020-01-01",
          effective_to: nil,
        },
      ]

      expect { described_class::Table.new(invalid) }
        .to raise_error(described_class::CircularChain)
    end

    it "rejects multiple paths with inconsistent exact products" do
      inconsistent = rules.map(&:dup)
      inconsistent[1][:effective_to] = "2010-01-02"
      invalid = inconsistent + [
        {
          from_currency: "HRB",
          to_currency: "HRD",
          ratio: 1,
          effective_from: "2010-01-02",
          effective_to: nil,
        },
        {
          from_currency: "HRD",
          to_currency: "HRC",
          ratio: Rational(1, 20),
          effective_from: "2010-01-02",
          effective_to: nil,
        },
      ]

      expect { described_class::Table.new(invalid) }
        .to raise_error(described_class::InconsistentPath)
    end

    it "accepts multiple paths with identical exact products" do
      consistent = rules.map(&:dup)
      consistent[1][:effective_to] = "2010-01-02"
      valid = consistent + [
        {
          from_currency: "HRB",
          to_currency: "HRD",
          ratio: 1,
          effective_from: "2010-01-02",
          effective_to: nil,
        },
        {
          from_currency: "HRD",
          to_currency: "HRC",
          ratio: Rational(1, 10),
          effective_from: "2010-01-02",
          effective_to: nil,
        },
      ]

      expect { described_class::Table.new(valid) }.not_to raise_error
    end

    it "can be built before its fictional currencies are statically registered" do
      %w[HRA HRB HRC HRD].each { |code| Money::Currency.unregister(code) }

      expect { described_class::Table.new(rules) }.not_to raise_error
    end

    it "accepts Rule objects and exact rational strings" do
      rule = described_class::Rule.new(
        from_currency: "HRA",
        to_currency: "HRB",
        ratio: Rational(1, 1000),
        effective_from: Date.new(2000, 1, 1),
      )

      stored_rule = described_class::Table.new([rule]).rules_for("HRA", Date.new(2000, 1, 1)).first

      expect([
        stored_rule.from_currency,
        stored_rule.to_currency,
        stored_rule.ratio,
      ]).to eq(["hra", "hrb", Rational(1, 1000)])
    end

    it "rejects Float ratios because they are not exact" do
      invalid = rules.map(&:dup)
      invalid[0][:ratio] = 0.001

      expect { described_class::Table.new(invalid) }
        .to raise_error(described_class::InvalidRule, /exact/)
    end
  end
end
