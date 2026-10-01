# frozen_string_literal: true

RSpec.describe Money::ControlledRounding do
  let(:half_cent) { Rational(1, 200) } # 0.5 cents in USD
  let(:cent) { Rational(1, 100) }

  def round(matrix, row_totals:, column_totals:, **options)
    described_class.round(matrix, row_totals: row_totals, column_totals: column_totals, **options)
  end

  def brute_force(matrix, row_totals:, column_totals:, **options)
    described_class.brute_force(matrix, row_totals: row_totals, column_totals: column_totals, **options)
  end

  # Asserts every property a valid solution must have: integer cells in
  # subunits, each the floor or ceil of the exact value, exact row and
  # column totals, and locked cells fixed to their chosen value.
  def expect_valid_solution(result, matrix, row_totals, column_totals, currency, locked)
    subunit = Money::Currency.new(currency).subunit_to_unit
    expect(result).to be_feasible
    expect(result.message).to be_nil
    matrix.each_with_index do |row, i|
      row.each_with_index do |value, j|
        scaled = value * subunit
        expect([scaled.floor, scaled.ceil]).to include(result.matrix[i][j]),
                                              "cell (#{i}, #{j}) = #{result.matrix[i][j]} is not the floor or ceil of #{scaled}"
      end
      expect(result.matrix[i].sum).to eq((row_totals[i] * subunit).to_i)
    end
    column_totals.each_with_index do |total, j|
      expect(result.matrix.sum { |row| row[j] }).to eq((total * subunit).to_i)
    end
    (locked || {}).each do |(i, j), value|
      expect(result.matrix[i][j]).to eq((value * subunit).to_i)
    end
  end

  describe ".round" do
    it "rounds each cell down or up and meets the totals exactly" do
      matrix = [[half_cent, half_cent], [half_cent, half_cent]]
      totals = [cent, cent]
      result = round(matrix, row_totals: totals, column_totals: totals, currency: "USD")
      expect_valid_solution(result, matrix, totals, totals, "USD", nil)
      expect(result.matrix.flatten.sum).to eq(2)
      expect(result.error).to eq(2)
    end

    it "does not just round every cell to the nearest integer" do
      # Naively rounding 0.5 cents up everywhere would give row sums of 2.
      matrix = [[half_cent, half_cent], [half_cent, half_cent]]
      result = round(matrix, row_totals: [cent, cent], column_totals: [cent, cent], currency: "USD")
      expect(result.matrix.map(&:sum)).to eq([1, 1])
    end

    it "handles exactly integral cells" do
      result = round([[Rational(1, 10)]], row_totals: [Rational(1, 10)], column_totals: [Rational(1, 10)], currency: "USD")
      expect(result.matrix).to eq([[10]])
      expect(result.error).to eq(0)
    end

    it "handles an empty matrix" do
      result = round([], row_totals: [], column_totals: [], currency: "USD")
      expect(result).to be_feasible
      expect(result.matrix).to eq([])
      expect(result.error).to eq(0)
    end

    it "handles negative amounts" do
      matrix = [[-half_cent, half_cent]]
      result = round(matrix, row_totals: [0], column_totals: [-cent, cent], currency: "USD")
      expect(result.matrix).to eq([[-1, 1]])
      expect(result.error).to eq(1)
    end

    it "handles currencies without a decimal subunit" do
      # MRU has 5 khoums per ouguiya, so 1/10 unit is half a khoums.
      matrix = [[Rational(1, 10), Rational(1, 10)], [Rational(1, 10), Rational(1, 10)]]
      totals = [Rational(1, 5), Rational(1, 5)]
      result = round(matrix, row_totals: totals, column_totals: totals, currency: "MRU")
      expect_valid_solution(result, matrix, totals, totals, "MRU", nil)
      expect(result.error).to eq(2)
    end

    it "handles currencies with 1000 subunits" do
      half_fils = Rational(1, 2000)
      fils = Rational(1, 1000)
      matrix = [[half_fils, half_fils], [half_fils, half_fils]]
      totals = [fils, fils]
      result = round(matrix, row_totals: totals, column_totals: totals, currency: "KWD")
      expect_valid_solution(result, matrix, totals, totals, "KWD", nil)
    end

    it "handles currencies without a subunit" do
      matrix = [[Rational(1, 2), Rational(1, 2)], [Rational(1, 2), Rational(1, 2)]]
      result = round(matrix, row_totals: [1, 1], column_totals: [1, 1], currency: "JPY")
      expect_valid_solution(result, matrix, [1, 1], [1, 1], "JPY", nil)
    end

    it "uses Money.default_currency when no currency is given" do
      result = round([[half_cent]], row_totals: [0], column_totals: [0])
      expect(result.matrix).to eq([[0]])
    end

    it "accepts BigDecimal amounts" do
      result = round([[BigDecimal("0.005"), BigDecimal("0.005")]],
                     row_totals: [BigDecimal("0.01")], column_totals: [BigDecimal("0.01"), 0], currency: "USD")
      expect(result.matrix).to eq([[1, 0]])
    end

    context "with locked cells" do
      it "keeps locked cells at their chosen value" do
        matrix = [[half_cent, half_cent], [half_cent, half_cent]]
        locked = { [0, 0] => cent }
        result = round(matrix, row_totals: [cent, cent], column_totals: [cent, cent], currency: "USD", locked: locked)
        expect_valid_solution(result, matrix, [cent, cent], [cent, cent], "USD", locked)
        expect(result.matrix).to eq([[1, 0], [0, 1]])
      end

      it "reports a conflict when a lock makes a column total unreachable" do
        matrix = [[half_cent, half_cent]]
        locked = { [0, 1] => cent }
        result = round(matrix, row_totals: [cent], column_totals: [cent, 0], currency: "USD", locked: locked)
        expect(result).to be_infeasible
        expect(result.conflict_rows).to eq([])
        expect(result.conflict_columns).to eq([1])
        expect(result.message).to include("column 1")
      end

      it "raises when the locked value is not the floor or ceil of the cell" do
        expect { round([[half_cent]], row_totals: [0], column_totals: [0], currency: "USD", locked: { [0, 0] => 2 * cent }) }
          .to raise_error(ArgumentError, /floor or ceil/)
      end

      it "raises when the locked value is not a whole number of subunits" do
        expect { round([[half_cent]], row_totals: [0], column_totals: [0], currency: "USD", locked: { [0, 0] => Rational(3, 200) }) }
          .to raise_error(ArgumentError, /floor or ceil/)
      end

      it "raises when the locked cell is out of range" do
        expect { round([[half_cent]], row_totals: [0], column_totals: [0], currency: "USD", locked: { [0, 1] => 0 }) }
          .to raise_error(ArgumentError, /out of range/)
      end
    end

    context "when infeasible" do
      it "reports a totals mismatch between rows and columns" do
        matrix = [[half_cent, half_cent], [half_cent, half_cent]]
        result = round(matrix, row_totals: [cent, cent], column_totals: [cent, 0], currency: "USD")
        expect(result).to be_infeasible
        expect(result.matrix).to be_nil
        expect(result.conflict_rows).to eq([0, 1])
        expect(result.conflict_columns).to eq([0, 1])
        expect(result.message).to include("does not equal")
      end

      it "reports a row whose total is below its floored cells" do
        result = round([[half_cent]], row_totals: [-cent], column_totals: [-cent], currency: "USD")
        expect(result).to be_infeasible
        expect(result.conflict_rows).to eq([0])
        expect(result.conflict_columns).to eq([])
        expect(result.message).to include("row 0")
      end

      it "reports the rows and columns of a min-cut conflict" do
        # Row 0 must round up both cells, but column 1 may not receive any.
        matrix = [[half_cent, half_cent], [half_cent, half_cent]]
        result = round(matrix, row_totals: [2 * cent, 0], column_totals: [2 * cent, 0], currency: "USD")
        expect(result).to be_infeasible
        expect(result.conflict_rows).to eq([0])
        expect(result.conflict_columns).to eq([1])
        expect(result.message).to include("rows [0]")
      end
    end

    context "with invalid input" do
      it "rejects Float amounts as inexact" do
        expect { round([[0.1]], row_totals: [0], column_totals: [0], currency: "USD") }
          .to raise_error(ArgumentError, /not an exact amount/)
      end

      it "rejects Float totals" do
        expect { round([[half_cent]], row_totals: [0.0], column_totals: [0], currency: "USD") }
          .to raise_error(ArgumentError, /not an exact amount/)
      end

      it "rejects a ragged matrix" do
        expect { round([[half_cent], [half_cent, half_cent]], row_totals: [0, 0], column_totals: [0], currency: "USD") }
          .to raise_error(ArgumentError, /same length/)
      end

      it "rejects the wrong number of totals" do
        expect { round([[half_cent]], row_totals: [0, 0], column_totals: [0], currency: "USD") }
          .to raise_error(ArgumentError, /expected 1 row total/)
      end

      it "rejects totals that are not whole subunits" do
        expect { round([[half_cent]], row_totals: [Rational(1, 3)], column_totals: [Rational(1, 3)], currency: "USD") }
          .to raise_error(ArgumentError, /whole number of subunits/)
      end
    end
  end

  describe ".brute_force" do
    it "finds the same optimum as the flow-based solver" do
      matrix = [[half_cent, half_cent], [half_cent, half_cent]]
      totals = [cent, cent]
      result = brute_force(matrix, row_totals: totals, column_totals: totals, currency: "USD")
      expect(result).to be_feasible
      expect(result.error).to eq(2)
    end

    it "refuses to enumerate too many free cells" do
      matrix = Array.new(3) { Array.new(3, half_cent) }
      totals = [cent, cent, cent]
      expect { brute_force(matrix, row_totals: totals, column_totals: totals, currency: "USD", max_free_cells: 8) }
        .to raise_error(ArgumentError, /refusing to enumerate/)
    end
  end

  describe "optimality against exhaustive enumeration" do
    currencies = ["USD", "KWD", "MRU", "JPY"]

    def random_instance(rng, currency)
      subunit = Money::Currency.new(currency).subunit_to_unit
      rows = rng.rand(1..3)
      cols = rng.rand(1..4)
      matrix = Array.new(rows) { Array.new(cols) { Rational(rng.rand(-400..400), rng.rand(2..9) * subunit) } }
      locked = {}
      rounded = Array.new(rows) { Array.new(cols, 0) }
      matrix.each_with_index do |row, i|
        row.each_with_index do |value, j|
          scaled = value * subunit
          choice = scaled.denominator == 1 ? 0 : rng.rand(0..1)
          rounded[i][j] = scaled.floor + choice
          locked[[i, j]] = Rational(rounded[i][j], subunit) if rng.rand < 0.25
        end
      end
      row_totals = rounded.map { |row| Rational(row.sum, subunit) }
      column_totals = Array.new(cols) { |j| Rational(rounded.sum { |row| row[j] }, subunit) }
      [matrix, row_totals, column_totals, locked]
    end

    it "matches the exhaustive optimum on random feasible matrices" do
      rng = Random.new(1234)
      40.times do
        currency = currencies.sample(random: rng)
        matrix, row_totals, column_totals, locked = random_instance(rng, currency)
        options = { currency: currency, locked: locked }
        result = round(matrix, row_totals: row_totals, column_totals: column_totals, **options)
        optimal = brute_force(matrix, row_totals: row_totals, column_totals: column_totals, **options)
        expect(result).to be_feasible
        expect_valid_solution(result, matrix, row_totals, column_totals, currency, locked)
        expect(result.error).to eq(optimal.error),
                                "solver error #{result.error} != exhaustive optimum #{optimal.error} for #{matrix.inspect}"
      end
    end

    it "agrees with exhaustive enumeration on perturbed, possibly infeasible totals" do
      rng = Random.new(5678)
      40.times do
        currency = currencies.sample(random: rng)
        matrix, row_totals, column_totals, locked = random_instance(rng, currency)
        subunit = Money::Currency.new(currency).subunit_to_unit
        if row_totals.length > 1
          row_totals[0] += Rational(1, subunit)
          row_totals[1] -= Rational(1, subunit)
        end
        options = { currency: currency, locked: locked }
        result = round(matrix, row_totals: row_totals, column_totals: column_totals, **options)
        optimal = brute_force(matrix, row_totals: row_totals, column_totals: column_totals, **options)
        expect(result.feasible?).to eq(optimal.feasible?)
        if result.feasible?
          expect_valid_solution(result, matrix, row_totals, column_totals, currency, locked)
          expect(result.error).to eq(optimal.error)
        else
          expect(result.conflict_rows.empty? && result.conflict_columns.empty?).to be(false)
          expect(result.message).to be_a(String)
        end
      end
    end
  end
end
