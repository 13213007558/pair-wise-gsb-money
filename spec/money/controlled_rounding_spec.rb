# frozen_string_literal: true

RSpec.describe Money::ControlledRounding do
  # Enumerates every floor/ceil combination of the unlocked cells and
  # returns the smallest total absolute error among the combinations that
  # satisfy all totals, or nil when no combination is feasible. Optimality
  # of the solver is verified against this exhaustive search, never against
  # totals that merely happen to add up.
  def brute_force_best_error(matrix, row_totals, column_totals, locked = {})
    rows = matrix.size
    columns = matrix.first.size
    free = []
    rows.times do |i|
      columns.times do |j|
        free << [i, j] unless locked.key?([i, j])
      end
    end
    best = nil
    (1 << free.length).times do |mask|
      candidate = Array.new(rows) { |i| Array.new(columns) { |j| locked[[i, j]] || matrix[i][j].floor } }
      free.each_with_index do |(i, j), bit|
        candidate[i][j] = matrix[i][j].ceil if mask[bit] == 1
      end
      next unless candidate.each_with_index.all? { |row, i| row.sum == row_totals[i] }
      next unless columns.times.all? { |j| candidate.sum { |row| row[j] } == column_totals[j] }

      error = total_absolute_error(matrix, candidate)
      best = error if best.nil? || error < best
    end
    best
  end

  def total_absolute_error(matrix, candidate)
    matrix.each_with_index.sum do |row, i|
      row.each_with_index.sum { |cell, j| (candidate[i][j] - cell).abs }
    end
  end

  def expect_valid_rounding(result, matrix, row_totals, column_totals, locked = {})
    expect(result).to be_feasible
    expect(result.conflict).to be_nil
    rounded = result.matrix
    matrix.each_with_index do |row, i|
      row.each_with_index do |cell, j|
        expect(rounded[i][j]).to be >= cell.floor
        expect(rounded[i][j]).to be <= cell.ceil
        expect(rounded[i][j]).to eq(locked[[i, j]]) if locked.key?([i, j])
      end
    end
    expect(rounded.map(&:sum)).to eq(row_totals)
    expect(rounded.transpose.map(&:sum)).to eq(column_totals)
    expect(result.error).to eq(total_absolute_error(matrix, rounded))
  end

  def random_instance(rng, rows, columns)
    matrix = Array.new(rows) do
      Array.new(columns) { Rational(rng.rand(-20..20), rng.rand(1..6)) }
    end
    locked = {}
    rows.times do |i|
      columns.times do |j|
        locked[[i, j]] = [matrix[i][j].floor, matrix[i][j].ceil].sample(random: rng) if rng.rand(4).zero?
      end
    end
    [matrix, locked]
  end

  def feasible_totals(matrix, locked, rng)
    assignment = matrix.each_with_index.map do |row, i|
      row.each_with_index.map do |cell, j|
        locked[[i, j]] || [cell.floor, cell.ceil].sample(random: rng)
      end
    end
    row_totals = assignment.map(&:sum)
    column_totals = assignment.first.each_index.map { |j| assignment.sum { |row| row[j] } }
    [row_totals, column_totals]
  end

  context "with a feasible problem" do
    it "rounds each cell to its floor or ceil, matches all totals and minimizes the error" do
      matrix = [
        [Rational(6, 5), Rational(13, 10), Rational(3, 2)],
        [Rational(7, 10), Rational(12, 5), Rational(9, 10)],
      ]
      result = described_class.round(matrix, row_totals: [4, 4], column_totals: [2, 4, 2])

      expect(result).to be_feasible
      expect(result.matrix).to eq([[1, 2, 1], [1, 2, 1]])
      expect(result.error).to eq(Rational(11, 5))
      expect(result.error).to eq(brute_force_best_error(matrix, [4, 4], [2, 4, 2]))
    end

    it "keeps already whole cells untouched" do
      matrix = [[1, 2], [3, 4]]
      result = described_class.round(matrix, row_totals: [3, 7], column_totals: [4, 6])

      expect(result).to be_feasible
      expect(result.matrix).to eq([[1, 2], [3, 4]])
      expect(result.error).to eq(0)
    end

    it "handles an empty matrix" do
      result = described_class.round([], row_totals: [], column_totals: [])

      expect(result).to be_feasible
      expect(result.matrix).to eq([])
      expect(result.error).to eq(0)
    end

    it "accepts BigDecimal amounts" do
      matrix = [[BigDecimal("1.5"), BigDecimal("0.25")], [BigDecimal("2.75"), BigDecimal("1.5")]]
      result = described_class.round(matrix, row_totals: [2, 4], column_totals: [4, 2])

      expect_valid_rounding(result, matrix.map { |row| row.map(&:to_r) }, [2, 4], [4, 2])
      expect(result.error).to eq(brute_force_best_error(matrix.map { |row| row.map(&:to_r) }, [2, 4], [4, 2]))
    end
  end

  context "with negative amounts" do
    it "rounds toward floor and ceil of the exact value" do
      matrix = [
        [Rational(-3, 2), Rational(1, 3)],
        [Rational(7, 4), Rational(-1, 6)],
      ]
      result = described_class.round(matrix, row_totals: [-1, 1], column_totals: [0, 0], locked: { [0, 1] => 1 })

      expect(result).to be_feasible
      expect(result.matrix).to eq([[-2, 1], [2, -1]])
      expect(result.error).to eq(Rational(9, 4))
      expect(result.error).to eq(brute_force_best_error(matrix, [-1, 1], [0, 0], { [0, 1] => 1 }))
    end
  end

  context "with locked cells" do
    it "respects the locked values and stays optimal" do
      matrix = [
        [Rational(6, 5), Rational(13, 10), Rational(3, 2)],
        [Rational(7, 10), Rational(12, 5), Rational(9, 10)],
      ]
      locked = { [0, 0] => 1, [1, 1] => 3 }
      result = described_class.round(matrix, row_totals: [4, 4], column_totals: [2, 4, 2], locked: locked)

      expect(result.matrix).to eq([[1, 1, 2], [1, 3, 0]])
      expect(result.error).to eq(Rational(14, 5))
      expect_valid_rounding(result, matrix, [4, 4], [2, 4, 2], locked)
      expect(result.error).to eq(brute_force_best_error(matrix, [4, 4], [2, 4, 2], locked))
    end

    it "reports a conflict when a lock makes the totals unreachable" do
      matrix = [[Rational(1, 2), Rational(1, 2)]]
      result = described_class.round(matrix, row_totals: [2], column_totals: [1, 1], locked: { [0, 0] => 0 })

      expect(result).not_to be_feasible
      expect(result.matrix).to be_nil
      expect(result.conflict.rows).to eq([0])
      expect(result.conflict.message).to include("rows [0]")
    end
  end

  context "with Money amounts", :default_infinite_precision_true do
    it "rounds in the smallest unit of a non-cent-based currency" do
      matrix = [
        [Money.new(BigDecimal("1.5"), "KWD"), Money.new(BigDecimal("2.5"), "KWD")],
        [Money.new(BigDecimal("3.5"), "KWD"), Money.new(BigDecimal("0.5"), "KWD")],
      ]
      row_totals = [Money.new(4, "KWD"), Money.new(4, "KWD")]
      column_totals = [Money.new(4, "KWD"), Money.new(4, "KWD")]
      result = described_class.round(matrix, row_totals: row_totals, column_totals: column_totals)

      expect(result).to be_feasible
      expect(result.matrix).to eq([[1, 3], [3, 1]])
      expect(result.error).to eq(2)
    end

    it "rejects mixed currencies" do
      expect do
        described_class.round([[Money.new(1, "USD")]], row_totals: [Money.new(1, "EUR")], column_totals: [1])
      end.to raise_error(ArgumentError, /same currency/)
    end
  end

  context "with an infeasible problem" do
    it "reports all rows and columns when the totals do not balance" do
      result = described_class.round([[Rational(1, 2)]], row_totals: [1], column_totals: [0])

      expect(result).not_to be_feasible
      expect(result.conflict.rows).to eq([0])
      expect(result.conflict.columns).to eq([0])
      expect(result.conflict.message).to include("differs")
    end

    it "reports the row whose total is below the reachable minimum" do
      matrix = [[Rational(3, 2), Rational(5, 2)]]
      result = described_class.round(matrix, row_totals: [2], column_totals: [1, 1])

      expect(result).not_to be_feasible
      expect(result.conflict.rows).to eq([0])
      expect(result.conflict.columns).to eq([0, 1])
      expect(result.conflict.message).to include("below the minimum")
    end

    it "reports the conflicting row and column sets of a subset violation" do
      matrix = [[Rational(1, 2), Rational(1, 2)], [Rational(1, 2), Rational(1, 2)]]
      result = described_class.round(matrix, row_totals: [2, 0], column_totals: [2, 0])

      expect(result).not_to be_feasible
      expect(result.matrix).to be_nil
      expect(result.error).to be_nil
      expect(result.conflict.rows).to eq([0])
      expect(result.conflict.columns).to eq([1])
      expect(result.conflict.to_s).to eq(result.conflict.message)
    end
  end

  context "with invalid input" do
    it "rejects Float amounts as inexact" do
      expect do
        described_class.round([[1.5]], row_totals: [2], column_totals: [2])
      end.to raise_error(ArgumentError, /Float/)
    end

    it "rejects a ragged matrix" do
      expect do
        described_class.round([[1], [2, 3]], row_totals: [1, 5], column_totals: [6])
      end.to raise_error(ArgumentError, /same number of columns/)
    end

    it "rejects totals of the wrong length" do
      expect do
        described_class.round([[1]], row_totals: [1, 2], column_totals: [1])
      end.to raise_error(ArgumentError, /expected 1 row total/)
    end

    it "rejects totals that are not whole smallest units" do
      expect do
        described_class.round([[1]], row_totals: [Rational(1, 2)], column_totals: [1])
      end.to raise_error(ArgumentError, /not a whole number/)
    end

    it "rejects locks outside the matrix" do
      expect do
        described_class.round([[1]], row_totals: [1], column_totals: [1], locked: { [1, 0] => 1 })
      end.to raise_error(ArgumentError, /out of bounds/)
    end

    it "rejects locks that are not whole smallest units" do
      expect do
        described_class.round([[1]], row_totals: [1], column_totals: [1], locked: { [0, 0] => Rational(1, 2) })
      end.to raise_error(ArgumentError, /whole number/)
    end

    it "rejects locks outside the floor and ceil of the cell" do
      expect do
        described_class.round([[Rational(1, 2)]], row_totals: [2], column_totals: [2], locked: { [0, 0] => 2 })
      end.to raise_error(ArgumentError, /between the floor/)
    end
  end

  context "when verified against exhaustive search" do
    it "finds an optimal solution for random feasible instances" do
      rng = Random.new(20260929)
      30.times do
        matrix, locked = random_instance(rng, rng.rand(2..3), rng.rand(2..3))
        row_totals, column_totals = feasible_totals(matrix, locked, rng)

        result = described_class.round(matrix, row_totals: row_totals, column_totals: column_totals, locked: locked)

        expect_valid_rounding(result, matrix, row_totals, column_totals, locked)
        expect(result.error).to eq(brute_force_best_error(matrix, row_totals, column_totals, locked))
      end
    end

    it "agrees with exhaustive search on arbitrary totals, feasible or not" do
      rng = Random.new(19890705)
      30.times do
        matrix, locked = random_instance(rng, 2, 3)
        row_totals = matrix.map { |row| row.sum.floor + rng.rand(-1..3) }
        column_totals = matrix.transpose.map { |column| column.sum.floor + rng.rand(-1..3) }

        result = described_class.round(matrix, row_totals: row_totals, column_totals: column_totals, locked: locked)
        best = brute_force_best_error(matrix, row_totals, column_totals, locked)

        if best.nil?
          expect(result).not_to be_feasible
          expect(result.conflict.rows).not_to be_empty
          expect(result.conflict.message).to be_a(String)
        else
          expect_valid_rounding(result, matrix, row_totals, column_totals, locked)
          expect(result.error).to eq(best)
        end
      end
    end

    it "solves a larger instance beyond exhaustive reach" do
      rng = Random.new(42)
      matrix, locked = random_instance(rng, 8, 8)
      row_totals, column_totals = feasible_totals(matrix, locked, rng)

      result = described_class.round(matrix, row_totals: row_totals, column_totals: column_totals, locked: locked)

      expect_valid_rounding(result, matrix, row_totals, column_totals, locked)
    end
  end

  describe "Money.controlled_round" do
    it "delegates to Money::ControlledRounding.round" do
      result = Money.controlled_round(
        [[Rational(6, 5), Rational(13, 10)], [Rational(7, 10), Rational(12, 5)]],
        row_totals: [3, 3],
        column_totals: [2, 4],
      )

      expect(result).to be_a(Money::ControlledRounding::Result)
      expect(result.matrix).to eq([[1, 2], [1, 2]])
    end
  end
end
