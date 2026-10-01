# frozen_string_literal: true

require "json"

class Money
  # Immutable exchange-rate snapshot used to convert a MultiCurrencyAmounts value.
  class ConversionQuote
    # @param source_amounts [Money::MultiCurrencyAmounts] Amounts to convert.
    # @param target_currency [Money::Currency, String, Symbol] Report currency.
    # @param bank [Money::Bank::Base] Bank used to read rates once.
    def initialize(source_amounts, target_currency, bank: nil)
      unless source_amounts.is_a?(Money::MultiCurrencyAmounts)
        raise TypeError, "source_amounts must be a Money::MultiCurrencyAmounts"
      end

      bank ||= source_amounts.bank
      target = Money::Currency.wrap(target_currency)
      totals = build_source_totals(source_amounts)
      rates, missing_rates = read_rates(source_amounts, target, bank)

      unless missing_rates.empty?
        currencies = missing_rates.join(", ")
        raise Money::Bank::UnknownRate,
              "No conversion rate known for #{currencies} -> #{target.iso_code}"
      end

      @source_amounts = source_amounts
      @target_currency = target
      @source_totals = totals.freeze
      @rates = rates.freeze
      @bank = bank

      freeze
    end

    # @return [Money::MultiCurrencyAmounts]
    attr_reader :source_amounts

    # @return [Money::Currency]
    attr_reader :target_currency

    # @return [Hash{String => Money}]
    attr_reader :source_totals

    # @return [Hash{String => BigDecimal}]
    attr_reader :rates
    alias exchange_rates rates

    # @param currency [Money::Currency, String, Symbol] Source currency.
    # @return [BigDecimal]
    def rate_for(currency)
      rates.fetch(Money::Currency.wrap(currency).iso_code)
    end
    alias [] rate_for

    # @return [BigDecimal] Unexchanged value in the target currency's subunit.
    def unrounded_fractional
      source_amounts.reduce(BigDecimal(0)) do |total, money|
        code = money.currency.iso_code
        converted = money.fractional.to_d *
                    BigDecimal(target_currency.subunit_to_unit.to_s) /
                    BigDecimal(money.currency.subunit_to_unit.to_s) *
                    rates.fetch(code)
        total + converted
      end
    end

    # @param rounding_mode [Integer] BigDecimal rounding mode.
    # @return [Money] Final amount rounded once in the target currency.
    def convert(rounding_mode: Money.rounding_mode)
      fractional = converted_fractional(rounding_mode)
      Money.new(fractional, target_currency, bank: @bank)
    end
    alias to_money convert
    alias call convert
    alias amount convert
    alias converted_amount convert

    # @return [Hash{String => Object}]
    def as_json(*)
      {
        "target_currency" => target_currency.iso_code,
        "source_totals" => source_totals.transform_values do |money|
          decimal_to_json(money.fractional)
        end,
        "rates" => rates.transform_values { |rate| rate.to_s("F") },
      }
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
      other.is_a?(self.class) &&
        target_currency == other.target_currency &&
        source_amounts == other.source_amounts &&
        rates == other.rates
    end

    # @return [Integer]
    def hash
      [self.class, source_amounts, target_currency, rates].hash
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{as_json.inspect}>"
    end

    private

    def build_source_totals(source_amounts)
      source_amounts.each_with_object({}) do |money, totals|
        totals[money.currency.iso_code] = money
      end
    end

    def read_rates(source_amounts, target_currency, bank)
      rates = {}
      missing_rates = []

      source_amounts.each do |money|
        code = money.currency.iso_code

        if money.currency == target_currency
          rates[code] = BigDecimal("1")
          next
        end

        rate = bank.get_rate(money.currency, target_currency)
        if rate.nil?
          missing_rates << code
        else
          rates[code] = BigDecimal(rate.to_s)
        end
      end

      [rates, missing_rates]
    end

    def converted_fractional(rounding_mode)
      return unrounded_fractional if Money.default_infinite_precision

      unrounded_fractional.round(0, rounding_mode).to_i
    end

    def decimal_to_json(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
    end
  end

  ExchangeQuote = ConversionQuote
end
