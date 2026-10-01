# frozen_string_literal: true

require "json"

class Money
  # An immutable collection of net Money amounts grouped by currency.
  class MultiCurrencyAmounts
    include Enumerable

    # @param amounts [Money, MultiCurrencyAmounts, Array, Hash] Amounts to net.
    # @param bank [Money::Bank::Base] Bank used when building Money values.
    # @return [Money::MultiCurrencyAmounts]
    def self.[](*amounts, bank: nil)
      new(*amounts, bank: bank)
    end

    # @param amounts [Money, MultiCurrencyAmounts, Array, Hash] Amounts to net.
    # @param bank [Money::Bank::Base] Bank used when building Money values.
    def initialize(*amounts, bank: nil)
      selected_bank = bank || detect_bank(amounts) || Money.default_bank
      totals = Hash.new { |hash, currency| hash[currency] = BigDecimal(0) }
      append(amounts, totals, selected_bank)

      @bank = selected_bank
      @amounts = build_amounts(totals)

      freeze
    end

    # @return [Money::Bank::Base]
    attr_reader :bank

    # @param currency [Money::Currency, String, Symbol] Currency to look up.
    # @return [Money] The net amount, or zero when the currency is absent.
    def [](currency)
      amount_for(currency)
    end

    # @param other [Money, MultiCurrencyAmounts, Array, Hash] Amounts to add.
    # @return [Money::MultiCurrencyAmounts]
    def +(other)
      combine(other, 1)
    end

    # @param other [Money, MultiCurrencyAmounts, Array, Hash] Amounts to subtract.
    # @return [Money::MultiCurrencyAmounts]
    def -(other)
      combine(other, -1)
    end

    # @return [Money::MultiCurrencyAmounts]
    def -@
      self.class.new(map(&:-@), bank: bank)
    end

    # @return [Money::MultiCurrencyAmounts]
    def +@
      self
    end

    # @param other [Money, MultiCurrencyAmounts, Array, Hash] Amounts to merge.
    # @return [Money::MultiCurrencyAmounts]
    alias merge +

    # @param other [Money, MultiCurrencyAmounts, Array, Hash] Amounts to subtract.
    # @return [Money::MultiCurrencyAmounts]
    alias subtract -

    # @param currency [Money::Currency, String, Symbol] Currency to look up.
    # @return [Money] The net amount, or zero when the currency is absent.
    def amount_for(currency)
      currency = Money::Currency.wrap(currency)
      @amounts[currency.iso_code] || Money.new(0, currency, bank: bank)
    end

    # @return [Array<Money::Currency>]
    def currencies
      @amounts.keys.map { |code| Money::Currency.wrap(code) }
    end

    # @yield [Money] Each nonzero amount in ISO currency order.
    # @return [Enumerator, Array<Money>]
    def each(&block)
      return to_enum(:each) unless block

      @amounts.values.each(&block)
    end

    # @return [Boolean]
    def empty?
      @amounts.empty?
    end

    # @return [Boolean]
    def zero?
      empty?
    end

    # @return [Integer]
    def size
      @amounts.size
    end
    alias length size

    # @return [Array<Money>]
    def to_a
      @amounts.values.dup
    end

    # @return [Hash{String => Integer, BigDecimal}]
    def to_h
      @amounts.transform_values(&:fractional).freeze
    end

    # @return [Hash{String => String}]
    def as_json(*)
      to_h.transform_values { |fractional| decimal_to_json(fractional) }
    end

    # @return [String]
    def to_json(*args)
      JSON.generate(as_json, *args)
    end

    # @param other [Object] Value to compare.
    # @return [Boolean]
    def ==(other)
      eql?(other)
    end

    # @param other [Object] Value to compare.
    # @return [Boolean]
    def eql?(other)
      other.is_a?(self.class) && to_h == other.to_h
    end

    # @return [Integer]
    def hash
      [self.class, to_h].hash
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{as_json.inspect}>"
    end

    # @param target_currency [Money::Currency, String, Symbol] Report currency.
    # @param bank [Money::Bank::Base] Bank used to read rates once.
    # @return [Money::ConversionQuote]
    def quote(target_currency, bank: nil)
      Money::ConversionQuote.new(
        self,
        target_currency,
        bank: bank || self.bank,
      )
    end
    alias quote_to quote
    alias conversion_quote quote
    alias exchange_quote_to quote

    # @param target_currency [Money::Currency, String, Symbol] Report currency.
    # @param bank [Money::Bank::Base] Bank used to read rates once.
    # @param rounding_mode [Integer] BigDecimal rounding mode.
    # @return [Money]
    def convert_to(target_currency, bank: nil,
                   rounding_mode: Money.rounding_mode)
      quote(target_currency, bank: bank).convert(rounding_mode: rounding_mode)
    end
    alias exchange_to convert_to

    private

    def append(values, totals, bank)
      values.each do |value|
        case value
        when self.class
          value.each { |amount| add_money(amount, totals) }
        when Money
          add_money(value, totals)
        when Array
          append(value, totals, bank)
        when Hash
          value.each do |currency, fractional|
            if fractional.is_a?(Money) || fractional.is_a?(self.class)
              append([fractional], totals, bank)
            else
              add_money(Money.new(fractional, currency, bank: bank), totals)
            end
          end
        else
          raise TypeError, "Unsupported multi-currency amount: #{value.class.name}"
        end
      end
    end

    def add_money(money, totals)
      totals[money.currency.iso_code] += BigDecimal(money.fractional.to_s)
    end

    def detect_bank(inputs)
      inputs.each do |value|
        case value
        when Money
          return value.bank
        when self.class
          return value.bank
        when Array
          bank = detect_bank(value)
          return bank if bank
        when Hash
          value.each_value do |fractional|
            return fractional.bank if fractional.is_a?(Money)
          end
        end
      end

      nil
    end

    def combine(other, sign)
      other = self.class.new(other, bank: bank) unless other.is_a?(self.class)
      amounts = to_a + other.map { |amount| amount(amount, sign) }
      self.class.new(amounts, bank: bank)
    end

    def amount(amount, sign)
      sign == 1 ? amount : -amount
    end

    def build_amounts(totals)
      totals.reject { |_currency, fractional| fractional.zero? }
            .sort
            .to_h do |currency, fractional|
              money = Money.new(fractional, currency, bank: bank).freeze
              [currency, money]
            end
            .freeze
    end

    def decimal_to_json(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
    end
  end

  MultiCurrencyAmount = MultiCurrencyAmounts
end
