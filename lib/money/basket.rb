# frozen_string_literal: true

require "json"
require "money/quote"

class Money
  # An immutable collection of net {Money} amounts grouped by currency.
  #
  # A basket keeps multi-currency figures (for example a USD income, an EUR
  # refund and a JPY fee) separate until they are deliberately converted with
  # a single quote. Ordinary arithmetic ({#+}, {#-}, {#-@}) only nets amounts
  # inside the basket and never queries an exchange rate bank.
  #
  # Entries are always stored sorted by ISO code and amounts that net to zero
  # are removed, which makes serialization stable.
  #
  # @example
  #   basket = Money::Basket.new(Money.new(100_00, "USD"), Money.new(-20_00, "EUR"))
  #   basket += Money::Basket.new(Money.new(1_000, "JPY"))
  #   basket.convert_to("USD") #=> #<Money fractional:... currency:USD>
  class Basket
    include Enumerable

    # @!attribute [r] amounts
    #   @return [Hash{String => Money}] Net amount per ISO code, sorted by
    #     currency code.
    attr_reader :amounts

    # Builds a basket from zero or more {Money} entries. Same-currency entries
    # are netted and zero entries are eliminated.
    #
    # @param entries [Array<Money>] Money amounts to group.
    # @return [Basket]
    def initialize(*entries)
      @amounts = self.class.send(:net_entries, entries.map { |entry| to_money(entry) })
      freeze
    end

    # Returns the net money for a currency, or +nil+ when the currency is not
    # present.
    #
    # @param currency [Currency, String, Symbol] Currency to look up.
    # @return [Money, nil]
    def [](currency)
      @amounts[Currency.wrap(currency).iso_code]
    end

    # ISO codes of the currencies represented by the basket.
    #
    # @return [Array<String>]
    def currencies
      @amounts.keys
    end

    # Yields each net amount in currency order.
    #
    # @yieldparam money [Money]
    # @return [Enumerator, self]
    def each(&block)
      return enum_for(__method__) unless block

      @amounts.each_value(&block)
      self
    end

    # @return [Boolean] Whether the basket contains no non-zero amounts.
    def empty?
      @amounts.empty?
    end

    # @return [Boolean] Whether every net amount is zero. Zero entries are
    #   eliminated, so this is equivalent to {#empty?}.
    def zero?
      empty?
    end

    # Merges another basket (or a single {Money}) per currency without
    # converting currencies.
    #
    # @param other [Basket, Money] Basket or money to add.
    # @return [Basket]
    def +(other)
      self.class.send(:from_entries, entries + normalize(other))
    end

    alias merge +

    # Subtracts another basket (or a single {Money}) per currency without
    # converting currencies.
    #
    # @param other [Basket, Money] Basket or money to subtract.
    # @return [Basket]
    def -(other)
      self.class.send(:from_entries, entries + normalize(other).map { |money| -money })
    end

    # Negates every amount in the basket.
    #
    # @return [Basket]
    def -@
      self.class.send(:from_entries, entries.map { |money| -money })
    end

    # Builds an explicit {Quote} for converting the basket once, at the final
    # reporting boundary.
    #
    # @param report_currency [Currency, String, Symbol] Currency to quote.
    # @param bank [Money::Bank::Base, nil] Bank to read rates from. Defaults
    #   to {Money.default_bank}.
    # @return [Quote]
    def quote_for(report_currency, bank: nil)
      Quote.capture(self, report_currency, bank: bank || Money.default_bank)
    end

    # Converts the basket to a single {Money} using an explicit quote snapshot.
    #
    # Rates are read once while the quote is captured; repeated evaluation of
    # the returned quote always yields the same result even if the bank later
    # changes. If any required rate is missing, the conversion fails entirely
    # and no partial result is produced.
    #
    # @param report_currency [Currency, String, Symbol] Reporting currency.
    # @param bank [Money::Bank::Base, nil] Bank to read rates from.
    # @return [Money] Converted total, rounded once.
    def convert_to(report_currency, bank: nil)
      quote_for(report_currency, bank: bank).convert
    end

    # Stable JSON representation mapping ISO codes to fractional amounts as
    # strings. Fractional values are strings to keep BigDecimal precision and
    # avoid float loss.
    #
    # @return [Hash{String => String}]
    def as_json(*)
      @amounts.transform_values { |money| money.fractional.to_s }
    end

    # @return [String] JSON document with sorted currency codes.
    def to_json(*args)
      JSON.generate(as_json, *args)
    end

    # @param other [Object] Object to compare with.
    # @return [Boolean]
    def eql?(other)
      other.is_a?(Basket) && other.amounts == @amounts
    end

    alias == eql?

    # @return [Integer]
    def hash
      [self.class, @amounts].hash
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{@amounts.inspect}>"
    end

    protected

    # @return [Array<Money>]
    def entries
      @amounts.values
    end

    private

    def to_money(entry)
      raise TypeError, "expected Money, got #{entry.class.name}" unless entry.is_a?(Money)

      entry
    end

    def normalize(other)
      case other
      when Basket then other.entries
      when Money then [other]
      else raise TypeError, "expected Money::Basket or Money, got #{other.class.name}"
      end
    end

    class << self
      # Restores a basket previously serialized with {#to_json}.
      #
      # @param string [String, Hash] JSON document or parsed hash.
      # @return [Basket]
      def from_json(string)
        data = string.is_a?(String) ? JSON.parse(string) : string
        restored = data.map do |iso_code, fractional|
          Money.new(BigDecimal(fractional.to_s), iso_code)
        end
        from_entries(restored)
      end

      private

      def from_entries(entries)
        allocate.tap do |basket|
          basket.instance_variable_set(:@amounts, net_entries(entries))
          basket.freeze
        end
      end

      def net_entries(entries)
        netted = entries.each_with_object({}) do |money, totals|
          iso_code = money.currency.iso_code
          current = totals[iso_code]
          if current
            money = money.dup_with(fractional: current.fractional + money.fractional)
          end
          totals[iso_code] = money
        end
        netted.reject { |_, money| money.fractional.zero? }.sort.to_h.freeze
      end
    end
  end
end
