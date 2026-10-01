# frozen_string_literal: true

class Money
  # An immutable snapshot of the exchange rates used to convert a {Basket} to a
  # single reporting currency at one moment in time.
  #
  # A quote is formed explicitly with {.capture}, which reads every required
  # rate up front and remembers the basket's original currency totals. If any
  # rate is missing the quote fails entirely and no partial conversion is
  # produced. Once captured, {#convert} evaluates repeatedly against the same
  # rates, even if the underlying bank changes.
  #
  # All converted legs are summed at full precision; rounding happens exactly
  # once, on the final total.
  class Quote
    # @!attribute [r] totals
    #   @return [Hash{String => Money}] Original net amount per ISO code.
    # @!attribute [r] rates
    #   @return [Hash{Array(String, String) => BigDecimal}] Captured rates,
    #     keyed by [from_iso_code, to_iso_code].
    # @!attribute [r] report_currency
    #   @return [Currency] Currency the basket is converted to.
    attr_reader :totals, :rates, :report_currency

    # Reads all required rates from +bank+ and returns an immutable quote.
    #
    # @param basket [Basket] Basket whose totals are quoted.
    # @param report_currency [Currency, String, Symbol] Reporting currency.
    # @param bank [Money::Bank::Base] Bank to read rates from.
    # @raise [Money::Bank::UnknownRate] if one or more rates are missing; the
    #   message lists every missing currency pair.
    # @return [Quote]
    def self.capture(basket, report_currency, bank: Money.default_bank)
      report = Currency.wrap(report_currency)
      totals = basket.amounts.dup
      rates = {}
      missing = []

      totals.each_key do |iso_code|
        key = [iso_code, report.iso_code]
        if iso_code == report.iso_code
          rates[key] = BigDecimal("1")
          next
        end

        rate = bank.get_rate(iso_code, report.iso_code)
        if rate.nil?
          missing << "'#{iso_code}' -> '#{report.iso_code}'"
        else
          rates[key] = BigDecimal(rate.to_s)
        end
      end

      unless missing.empty?
        raise Money::Bank::UnknownRate,
              "No conversion rate known for #{missing.join(', ')}"
      end

      quote = allocate
      quote.send(:init, totals.freeze, rates.freeze, report, bank)
      quote
    end

    # @return [Hash{String => Money}] Alias of {#totals}.
    def from_currency_totals
      @totals
    end

    # Returns the captured rate between two currencies.
    #
    # @param from [Currency, String, Symbol] Source currency.
    # @param to [Currency, String, Symbol] Target currency.
    # @return [BigDecimal, nil]
    def [](from, to)
      @rates[[Currency.wrap(from).iso_code, Currency.wrap(to).iso_code]]
    end

    # Converts every captured total into the report currency and rounds the
    # combined result exactly once. Repeated calls always return the same
    # value because the quote never re-reads the bank.
    #
    # @return [Money]
    def convert
      @converted
    end

    # @return [Hash] Stable representation of the quote.
    def to_h
      {
        "report_currency" => @report_currency.iso_code,
        "rates" => @rates.transform_keys { |from, to| "#{from}_TO_#{to}" }.transform_values(&:to_s),
        "totals" => @totals.transform_values { |money| money.fractional.to_s },
      }
    end

    # @param other [Object]
    # @return [Boolean]
    def eql?(other)
      other.is_a?(Quote) &&
        other.report_currency == @report_currency &&
        other.totals == @totals &&
        other.rates == @rates
    end

    alias == eql?

    # @return [Integer]
    def hash
      [self.class, @report_currency, @totals, @rates].hash
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} report_currency:#{@report_currency} rates:#{@rates.inspect}>"
    end

    private

    def init(totals, rates, report_currency, bank)
      @totals = totals
      @rates = rates
      @report_currency = report_currency
      @bank = bank
      @converted = calculate
      freeze
    end

    def calculate
      fractional = @totals.sum(BigDecimal("0")) do |iso_code, money|
        rate = @rates.fetch([iso_code, @report_currency.iso_code])
        BigDecimal(money.fractional.to_s) * rate
      end

      rounded =
        if Money.default_infinite_precision
          fractional
        else
          fractional.round(0, Money.rounding_mode).to_i
        end

      Money.new(rounded, @report_currency, bank: @bank)
    end
  end
end
