# frozen_string_literal: true

class Money
  class CashChange
    class Validator
      def self.validate(amount, inventory, priority)
        new(amount, inventory, priority).validate
      end

      def initialize(amount, inventory, priority)
        @amount = amount
        @inventory = inventory
        @priority = priority
      end

      def validate
        validate_amount
        validate_inventory_type

        inventory = @inventory.dup
        inventory.each { |denomination, stock| validate_denomination(denomination, stock) }
        validate_priority(inventory.keys)
        [integer_value(@amount.fractional), inventory]
      end

      private

      def validate_amount
        unless @amount.is_a?(Money)
          raise TypeError, "amount must be a Money"
        end

        amount = integer_value(@amount.fractional)
        return if amount && amount >= 0

        raise ArgumentError, "change amount must be a non-negative integer in fractional units"
      end

      def validate_inventory_type
        return if @inventory.is_a?(Hash)

        raise TypeError, "inventory must be a Hash keyed by Money denominations"
      end

      def validate_denomination(denomination, stock)
        unless denomination.is_a?(Money)
          raise TypeError, "inventory denominations must be Money"
        end
        if denomination.currency != @amount.currency
          raise ArgumentError, "cannot mix currencies in cash change inventory"
        end
        value = integer_value(denomination.fractional)
        unless value&.positive?
          raise ArgumentError, "denominations must be positive integer fractional units"
        end
        unless stock.is_a?(Integer) && stock >= 0
          raise ArgumentError, "inventory stock must be a non-negative integer"
        end
      end

      def validate_priority(denominations)
        ordered = @priority || denominations.dup.sort_by(&:fractional).reverse
        unless ordered.is_a?(Array) && ordered.all?(Money) && ordered.size == denominations.size
          raise ArgumentError, "priority must list every inventory denomination exactly once"
        end
        if ordered.map { |denomination| denomination_key(denomination) }.uniq.size != ordered.size
          raise ArgumentError, "priority must list every inventory denomination exactly once"
        end
        unless ordered.all? { |denomination| denominations.any? { |other| same_denomination?(denomination, other) } }
          raise ArgumentError, "priority must list every inventory denomination exactly once"
        end
      end

      def denomination_key(denomination)
        [denomination.currency, denomination.fractional]
      end

      def same_denomination?(left, right)
        denomination_key(left) == denomination_key(right)
      end

      def integer_value(value)
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(BigDecimal) && value.finite? && (value % 1).zero?

        nil
      end
    end
  end
end
