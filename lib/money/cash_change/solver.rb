# frozen_string_literal: true

require "money/cash_change/validator"

class Money
  class CashChange
    class Solver
      Item = Struct.new(:denomination, :value, :stock, keyword_init: true)

      def initialize(amount, inventory, priority)
        @amount = amount
        @inventory = inventory
        @priority = priority
      end

      def call
        target, inventory = Validator.validate(@amount, @inventory, @priority)
        return CashChange::NO_SOLUTION unless reachable?(target, inventory)

        items = build_items(target, inventory)
        @suffix_values = suffix_values(items)
        @suffix_gcds = suffix_gcds(items)
        @suffix_largest = suffix_largest(items)
        @counts = Array.new(items.size, 0)
        @best_counts = greedy_counts(items, target)
        @best_total = @best_counts&.sum

        explore(items, 0, target, 0)
        result(items, inventory, @best_counts)
      end

      private

      def reachable?(target, inventory)
        return true if target.zero?
        return false if inventory.empty?

        values = inventory.keys.map { |denomination| integer_value(denomination.fractional) }
        gcd = values.inject(0, :gcd)
        return false unless (target % gcd).zero?

        values.zip(inventory.values).sum { |value, stock| value * stock } >= target
      end

      def build_items(target, inventory)
        ordered = @priority || inventory.keys.sort_by(&:fractional).reverse
        ordered.filter_map do |denomination|
          value = integer_value(denomination.fractional)
          stock = [inventory.fetch(denomination), target / value].min
          next if stock.zero? && target.positive?

          Item.new(denomination: denomination, value: value, stock: stock)
        end
      end

      def greedy_counts(items, target)
        remaining = target
        counts = items.map do |item|
          quantity = [item.stock, remaining / item.value].min
          remaining -= quantity * item.value
          quantity
        end
        remaining.zero? ? counts : nil
      end

      def suffix_values(items)
        values = Array.new(items.size + 1, 0)
        items.each_with_index.reverse_each { |item, index| values[index] = values[index + 1] + item.value * item.stock }
        values
      end

      def suffix_gcds(items)
        gcds = Array.new(items.size + 1, 0)
        items.each_with_index.reverse_each { |item, index| gcds[index] = gcds[index + 1].gcd(item.value) }
        gcds
      end

      def suffix_largest(items)
        largest = Array.new(items.size + 1, 0)
        items.each_with_index.reverse_each { |item, index| largest[index] = [item.value, largest[index + 1]].max }
        largest
      end

      def explore(items, index, remaining, used)
        return unless branch_possible?(index, remaining, used)
        return complete(remaining, used) if index == items.size

        quantities_for(items, index, remaining).each do |quantity|
          @counts[index] = quantity
          explore(items, index + 1, remaining - quantity * items[index].value, used + quantity)
        end
      ensure
        @counts[index] = 0 if index < @counts.size
      end

      def branch_possible?(index, remaining, used)
        return false if @best_total && used > @best_total
        return false if remaining > @suffix_values[index]
        return false unless @suffix_gcds[index].zero? || (remaining % @suffix_gcds[index]).zero?
        return true if index == @suffix_largest.size - 1

        minimum = (remaining.to_r / @suffix_largest[index]).ceil
        return false if @best_total && used + minimum > @best_total
        return false if @best_total && used + minimum == @best_total && lexically_smaller?(index)

        true
      end

      def quantities_for(items, index, remaining)
        item = items[index]
        suffix_value = @suffix_values[index + 1]
        suffix_gcd = @suffix_gcds[index + 1]
        maximum = [item.stock, remaining / item.value].min
        minimum = [(remaining - suffix_value + item.value - 1) / item.value, 0].max
        return [] if minimum > maximum

        if suffix_gcd.zero?
          exact_quantities(item, remaining, minimum, maximum)
        else
          congruent_quantities(item, suffix_gcd, remaining, minimum, maximum)
        end
      end

      def exact_quantities(item, remaining, minimum, maximum)
        quantity = remaining / item.value
        return [] if remaining % item.value != 0 || quantity < minimum || quantity > maximum

        [quantity]
      end

      def congruent_quantities(item, suffix_gcd, remaining, minimum, maximum)
        divisor = item.value.gcd(suffix_gcd)
        return [] unless (remaining % divisor).zero?

        modulus = suffix_gcd / divisor
        return maximum.step(minimum, -1) if modulus == 1

        residue = ((remaining / divisor) * modular_inverse(item.value / divisor, modulus)) % modulus
        first = maximum - ((maximum % modulus - residue) % modulus)
        first < minimum ? [] : first.step(minimum, -modulus)
      end

      def modular_inverse(value, modulus)
        coefficient = 0
        previous_coefficient = 1
        remainder = modulus
        previous_remainder = value
        until remainder.zero?
          quotient = previous_remainder / remainder
          previous_remainder, remainder = remainder, previous_remainder - quotient * remainder
          previous_coefficient, coefficient = coefficient, previous_coefficient - quotient * coefficient
        end
        previous_coefficient % modulus
      end

      def lexically_smaller?(index)
        return false unless @best_counts

        index.times do |position|
          return @counts[position] < @best_counts[position] if @counts[position] != @best_counts[position]
        end
        false
      end

      def complete(remaining, used)
        return unless remaining.zero? && better?(used)

        @best_counts = @counts.dup
        @best_total = used
      end

      def better?(total)
        return true if @best_counts.nil?
        return total < @best_total if total != @best_total

        @counts.each_with_index do |count, index|
          return count > @best_counts[index] if count != @best_counts[index]
        end
        false
      end

      def result(items, inventory, counts)
        return CashChange::NO_SOLUTION unless counts

        quantities = inventory.each_key.with_object({}) do |denomination, values|
          item_index = items.index { |item| same_denomination?(item.denomination, denomination) }
          values[denomination] = item_index ? counts[item_index] : 0
        end
        CashChange::Result.new(quantities.freeze, counts.sum).freeze
      end

      def denomination_key(denomination)
        [denomination.currency, denomination.fractional]
      end

      def same_denomination?(left, right)
        denomination_key(left) == denomination_key(right)
      end

      def integer_value(value)
        value.is_a?(BigDecimal) ? value.to_i : value
      end
    end
  end
end
