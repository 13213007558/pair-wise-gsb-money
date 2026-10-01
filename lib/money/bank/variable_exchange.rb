# frozen_string_literal: true

require "money/bank/base"
require "money/bank/exchange_route"
require "money/rates_store/memory"
require "json"
require "yaml"

class Money
  module Bank
    # Thrown when an unknown rate format is requested.
    class UnknownRateFormat < StandardError; end

    # Class for aiding in exchanging money between different currencies. By
    # default, the +Money+ class uses an object of this class (accessible
    # through +Money#bank+) for performing currency exchanges.
    #
    # By default, +Money::Bank::VariableExchange+ has no knowledge about
    # conversion rates. One must manually specify them with +add_rate+, after
    # which one can perform exchanges with +#exchange_with+.
    #
    # Exchange rates are stored in memory using +Money::RatesStore::Memory+ by default.
    # Pass custom rates stores for other types of storage (file, database, etc)
    #
    # @example
    #   bank = Money::Bank::VariableExchange.new
    #   bank.add_rate("USD", "CAD", 1.24515)
    #   bank.add_rate("CAD", "USD", 0.803115)
    #
    #   c1 = Money.new(100_00, "USD")
    #   c2 = Money.new(100_00, "CAD")
    #
    #   # Exchange 100 USD to CAD:
    #   bank.exchange_with(c1, "CAD") #=> #<Money fractional:12451 currency:CAD>
    #
    #   # Exchange 100 CAD to USD:
    #   bank.exchange_with(c2, "USD") #=> #<Money fractional:8031 currency:USD>
    #
    #   # With custom exchange rates storage
    #   redis_store = MyCustomRedisStore.new(host: 'localhost:6379')
    #   bank = Money::Bank::VariableExchange.new(redis_store)
    #   # Store rates in redis
    #   bank.add_rate 'USD', 'CAD', 0.98
    #   # Get rate from redis
    #   bank.get_rate 'USD', 'CAD'
    class VariableExchange < Base
      attr_reader :mutex

      # Available formats for importing/exporting rates.
      RATE_FORMATS = [:json, :ruby, :yaml].freeze
      SERIALIZER_SEPARATOR = "_TO_"
      FORMAT_SERIALIZERS = { json: JSON, ruby: Marshal, yaml: YAML }.freeze

      # Initializes a new +Money::Bank::VariableExchange+ object.
      # It defaults to using an in-memory, thread safe store instance for
      # storing exchange rates.
      #
      # @param [RateStore] st An exchange rate store, used to persist exchange rate pairs.
      # @yield [n] Optional block to use when rounding after exchanging one
      #  currency for another. See +Money::bank::base+
      def initialize(store = Money::RatesStore::Memory.new, &)
        @store = store
        super(&)
      end

      def store
        @store.is_a?(String) ? Object.const_get(@store) : @store
      end

      def marshal_dump
        [store.marshal_dump, @rounding_method]
      end

      def marshal_load(arr)
        store_info = arr[0]
        @store = store_info.shift.new(*store_info)
        @rounding_method = arr[1]
      end

      # Exchanges the given +Money+ object to a new +Money+ object in
      # +to_currency+.
      #
      # @param  [Money] from
      #         The +Money+ object to exchange.
      # @param  [Currency, String, Symbol] to_currency
      #         The currency to exchange to.
      #
      # @yield [n] Optional block to use when rounding after exchanging one
      #  currency for another.
      # @yieldparam [Float] n The resulting float after exchanging one currency
      #  for another.
      # @yieldreturn [Integer]
      #
      # @return [Money]
      #
      # @raise +Money::Bank::UnknownRate+ if the conversion rate is unknown.
      #
      # @example
      #   bank = Money::Bank::VariableExchange.new
      #   bank.add_rate("USD", "CAD", 1.24515)
      #   bank.add_rate("CAD", "USD", 0.803115)
      #
      #   c1 = Money.new(100_00, "USD")
      #   c2 = Money.new(100_00, "CAD")
      #
      #   # Exchange 100 USD to CAD:
      #   bank.exchange_with(c1, "CAD") #=> #<Money fractional:12451 currency:CAD>
      #
      #   # Exchange 100 CAD to USD:
      #   bank.exchange_with(c2, "USD") #=> #<Money fractional:8031 currency:USD>
      def exchange_with(from, to_currency, &)
        to_currency = Currency.wrap(to_currency)
        if from.currency == to_currency
          from
        elsif (rate = get_rate(from.currency, to_currency))
          fractional = calculate_fractional(from, to_currency)
          from.dup_with(
            fractional: exchange(fractional, rate, &),
            currency: to_currency,
            bank: self,
          )
        else
          raise UnknownRate, "No conversion rate known for '#{from.currency.iso_code}' -> '#{to_currency}'"
        end
      end

      def calculate_fractional(from, to_currency)
        BigDecimal(from.fractional.to_s) / (
          BigDecimal(from.currency.subunit_to_unit.to_s) /
          BigDecimal(to_currency.subunit_to_unit.to_s)
        )
      end

      def exchange(fractional, rate, &)
        ex = fractional * BigDecimal(rate.to_s)
        if block_given?
          yield ex
        elsif @rounding_method
          @rounding_method.call(ex)
        else
          ex
        end
      end

      # Finds the bounded route receiving the largest destination amount.
      # The supplied rates and fees are copied into an ExchangeQuote and do not
      # change while this search is running.
      def best_exchange_route(from, to_currency = nil, graph = nil,
                               positional_fees = nil, positional_max_hops = nil,
                               rates: nil, quotes: nil, edges: nil,
                               fees: nil, fixed_fees: nil, edge_fees: nil,
                               max_hops: 3, maximum_hops: nil, hop_limit: nil,
                               max_jumps: nil, quote: nil,
                               rounding_method: nil, rounding: nil,
                               **keyword_options, &rounding_block)
        to_currency, rates, quotes, fees, max_hops, quote = route_search_options(
          to_currency, rates || graph, positional_fees, positional_max_hops,
          quotes, edges, fees, fixed_fees, edge_fees, max_hops,
          maximum_hops, hop_limit, max_jumps, quote, keyword_options,
        )
        rounding_method ||= rounding || rounding_block
        quote ||= build_exchange_quote(rates, quotes, fees)
        ExchangeRoutePlanner.new(self).call(
          from, to_currency, quote, max_hops, rounding_method: rounding_method,
        )
      end
      alias find_best_exchange_route best_exchange_route
      alias best_exchange_path best_exchange_route
      alias exchange_route best_exchange_route
      alias best_conversion_route best_exchange_route
      alias find_best_route best_exchange_route

      # Registers a conversion rate and returns it (uses +#set_rate+).
      # Delegates to +Money::RatesStore::Memory+
      #
      # @param [Currency, String, Symbol] from Currency to exchange from.
      # @param [Currency, String, Symbol] to Currency to exchange to.
      # @param [Numeric] rate Rate to use when exchanging currencies.
      #
      # @return [Numeric]
      #
      # @example
      #   bank = Money::Bank::VariableExchange.new
      #   bank.add_rate("USD", "CAD", 1.24515)
      #   bank.add_rate("CAD", "USD", 0.803115)
      def add_rate(from, to, rate)
        set_rate(from, to, rate)
      end

      # Set the rate for the given currencies.
      # access.
      # Delegates to +Money::RatesStore::Memory+
      #
      # @param [Currency, String, Symbol] from Currency to exchange from.
      # @param [Currency, String, Symbol] to Currency to exchange to.
      # @param [Numeric] rate Rate to use when exchanging currencies.
      # @param [Hash] opts Options hash to set special parameters. Backwards compatibility only.
      #
      # @return [Numeric]
      #
      # @example
      #   bank = Money::Bank::VariableExchange.new
      #   bank.set_rate("USD", "CAD", 1.24515)
      #   bank.set_rate("CAD", "USD", 0.803115)
      def set_rate(from, to, rate, _opts = {})
        store.add_rate(Currency.wrap(from).iso_code, Currency.wrap(to).iso_code, rate)
      end

      # Retrieve the rate for the given currencies.
      # data access.
      # Delegates to +Money::RatesStore::Memory+
      #
      # @param [Currency, String, Symbol] from Currency to exchange from.
      # @param [Currency, String, Symbol] to Currency to exchange to.
      # @param [Hash] opts Options hash to set special parameters. Backwards compatibility only.
      #
      # @return [Numeric]
      #
      # @example
      #   bank = Money::Bank::VariableExchange.new
      #   bank.set_rate("USD", "CAD", 1.24515)
      #   bank.set_rate("CAD", "USD", 0.803115)
      #
      #   bank.get_rate("USD", "CAD") #=> 1.24515
      #   bank.get_rate("CAD", "USD") #=> 0.803115
      def get_rate(from, to, _opts = {})
        store.get_rate(Currency.wrap(from).iso_code, Currency.wrap(to).iso_code)
      end

      # Return the known rates as a string in the format specified. If +file+
      # is given will also write the string out to the file specified.
      # Available formats are +:json+, +:ruby+ and +:yaml+.
      #
      # @param [Symbol] format Request format for the resulting string.
      # @param [String] file Optional file location to write the rates to.
      # @param [Hash] opts Options hash to set special parameters. Backwards compatibility only.
      #
      # @return [String]
      #
      # @raise +Money::Bank::UnknownRateFormat+ if format is unknown.
      #
      # @example
      #   bank = Money::Bank::VariableExchange.new
      #   bank.set_rate("USD", "CAD", 1.24515)
      #   bank.set_rate("CAD", "USD", 0.803115)
      #
      #   s = bank.export_rates(:json)
      #   s #=> "{\"USD_TO_CAD\":1.24515,\"CAD_TO_USD\":0.803115}"
      def export_rates(format, file = nil, _opts = {})
        raise Money::Bank::UnknownRateFormat unless RATE_FORMATS.include?(format)

        store.transaction do
          s = FORMAT_SERIALIZERS[format].dump(rates)

          unless file.nil?
            File.write(file, s)
          end

          s
        end
      end

      # This should be deprecated.
      def rates
        store.each_rate.with_object({}) do |(from, to, rate), hash|
          hash[[from, to].join(SERIALIZER_SEPARATOR)] = rate
        end
      end

      # Loads rates provided in +string+ given the specified format. Available
      # formats are +:json+, +:ruby+ and +:yaml+.
      # Delegates to +Money::RatesStore::Memory+
      #
      # @param [Symbol] format The format of +string+.
      # @param [String] string The rates string.
      # @param [Hash] opts Options hash to set special parameters. Backwards compatibility only.
      #
      # @return [self]
      #
      # @raise +Money::Bank::UnknownRateFormat+ if format is unknown.
      #
      # @example
      #   string = "{\"USD_TO_CAD\":1.24515,\"CAD_TO_USD\":0.803115}"
      #   bank = Money::Bank::VariableExchange.new
      #   bank.import_rates(:json, string)
      #
      #   bank.get_rate("USD", "CAD") #=> 1.24515
      #   bank.get_rate("CAD", "USD") #=> 0.803115
      def import_rates(format, string, _opts = {})
        raise Money::Bank::UnknownRateFormat unless RATE_FORMATS.include?(format)

        if format == :ruby
          warn "[WARNING] Using :ruby format when importing rates is potentially unsafe and " \
               "might lead to remote code execution via Marshal.load deserializer. Consider using " \
               "safe alternatives such as :json and :yaml."
        end

        store.transaction do
          data = format == :json ? JSON.parse(string) : FORMAT_SERIALIZERS[format].load(string)

          data.each do |key, rate|
            from, to = key.split(SERIALIZER_SEPARATOR)
            store.add_rate from, to, rate
          end
        end

        self
      end

      private

      def route_search_options(to_currency, graph, positional_fees, positional_max_hops,
                               keyword_quotes, keyword_edges, keyword_fees,
                               fixed_fees, edge_fees, keyword_max_hops,
                               maximum_hops, hop_limit, max_jumps, quote, options)
        option_target, option_graph, option_quotes, option_fees, option_quote,
          option_hops = route_options(to_currency.is_a?(Hash) ? to_currency : options)

        to_currency = option_target if to_currency.is_a?(Hash) || to_currency.nil?

        graph = option_graph || graph
        quotes = option_quotes || keyword_quotes || keyword_edges
        fees = option_fees || keyword_fees || fixed_fees || edge_fees || positional_fees
        quote = option_quote || quote || (graph if graph.is_a?(ExchangeQuote))
        hops = option_hops || maximum_hops || hop_limit || max_jumps ||
               positional_max_hops || keyword_max_hops
        [to_currency, graph, quotes, fees, hops, quote]
      end

      def route_options(options)
        [
          option_value(options, :to, :target, :target_currency),
          option_value(options, :rates, :graph, :exchange_rates, :rate_graph),
          option_value(options, :quotes, :edges),
          option_value(options, :fees, :fixed_fees, :edge_fees),
          option_value(options, :quote),
          option_value(options, :max_hops, :maximum_hops, :hop_limit, :max_jumps),
        ]
      end

      def option_value(options, *keys)
        symbol_key = keys.find { |key| options.key?(key) }
        return options[symbol_key] if symbol_key

        string_key = keys.find { |key| options.key?(key.to_s) }
        options[string_key] if string_key
      end

      def build_exchange_quote(rates, quotes, fees)
        rates = stored_route_rates if rates.nil? && quotes.nil? && store.respond_to?(:each_rate)
        ExchangeQuote.new(rates: rates, quotes: quotes, fees: fees)
      end

      def stored_route_rates
        store.each_rate.map do |from, to, rate|
          { from: from, to: to, rate: rate }
        end
      end
    end
  end
end
