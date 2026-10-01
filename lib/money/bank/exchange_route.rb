# frozen_string_literal: true

class Money
  module Bank
    # Immutable snapshot of all rates and fixed fees available to one search.
    class ExchangeQuote
      Edge = Struct.new(:from, :to, :rate, :fee, keyword_init: true)

      def initialize(rates: nil, quotes: nil, fees: nil)
        @edges = Hash.new { |hash, key| hash[key] = {} }
        add_rates(rates)
        add_quotes(quotes)
        add_fees(fees)
        complete_and_freeze
      end

      def outgoing(currency)
        @edges.fetch(Currency.wrap(currency).iso_code, {}).values
      end

      def each_edge(&block)
        @edges.each_value do |outgoing|
          outgoing.each_value { |edge| block.call(edge) }
        end
      end

      private

      def add_rates(rates)
        return if rates.nil?

        case rates
        when Hash then add_hash_rates(rates)
        when Array then rates.each { |rate| add_array_rate(rate) }
        else raise ArgumentError, "rates must be a Hash or an Array"
        end
      end

      def add_hash_rates(rates)
        rates.each do |from, destinations|
          if destinations.is_a?(Hash)
            destinations.each do |to, details|
              if details.is_a?(Hash)
                add_edge(from, to, rate_value(details), fee_value(details))
              else
                add_edge(from, to, details, nil)
              end
            end
          else
            from, to = split_key(from)
            add_edge(from, to, destinations, nil)
          end
        end
      end

      def add_array_rate(rate)
        if rate.is_a?(Hash)
          add_edge(
            rate[:from] || rate["from"],
            rate[:to] || rate["to"],
            rate[:rate] || rate["rate"],
            fee_value(rate),
          )
          return
        end

        unless rate.is_a?(Array) && (3..4).cover?(rate.length)
          raise ArgumentError, "unsupported rate entry: #{rate.inspect}"
        end

        from, to, value, fee = rate
        add_edge(from, to, value, fee)
      end

      def add_quotes(quotes)
        return if quotes.nil?

        quotes.each do |quote|
          unless quote.is_a?(Hash)
            raise ArgumentError, "quotes must be an Array of Hashes"
          end

          add_edge(
            quote[:from] || quote["from"],
            quote[:to] || quote["to"],
            quote[:rate] || quote["rate"],
            quote[:fee] || quote["fee"] ||
              quote[:fixed_fee] || quote["fixed_fee"],
          )
        end
      end

      def add_fees(fees)
        return if fees.nil?

        case fees
        when Hash
          fees.each do |key, fee|
            from, to = split_key(key)
            edge = @edges.dig(Currency.wrap(from).iso_code, Currency.wrap(to).iso_code)
            raise ArgumentError, "fee has no rate for #{from} -> #{to}" unless edge

            edge.fee = build_fee(fee, Currency.wrap(edge.from), Currency.wrap(edge.to))
          end
        when Array
          fees.each { |fee| add_array_fee(fee) }
        else
          raise ArgumentError, "fees must be a Hash or an Array"
        end
      end

      def add_array_fee(fee)
        unless fee.is_a?(Hash) && (fee.key?(:from) || fee.key?("from"))
          raise ArgumentError, "unsupported fee entry: #{fee.inspect}"
        end

        from = fee[:from] || fee["from"]
        to = fee[:to] || fee["to"]
        amount = fee[:amount] || fee["amount"] ||
                 fee[:fee] || fee["fee"] ||
                 fee[:fixed_fee] || fee["fixed_fee"]
        currency = fee[:currency] || fee["currency"] ||
                   fee[:fee_currency] || fee["fee_currency"]
        edge = @edges.dig(Currency.wrap(from).iso_code, Currency.wrap(to).iso_code)
        raise ArgumentError, "fee has no rate for #{from} -> #{to}" unless edge

        edge.fee = build_fee(
          currency ? { amount: amount, fee_currency: currency } : amount,
          Currency.wrap(edge.from), Currency.wrap(edge.to),
        )
      end

      def add_edge(from, to, rate, fee)
        raise ArgumentError, "missing exchange rate for #{from} -> #{to}" if rate.nil?

        from_code = Currency.wrap(from).iso_code
        to_code = Currency.wrap(to).iso_code
        rate = BigDecimal(rate.to_s)
        raise ArgumentError, "exchange rates must be non-negative" if rate.negative?

        if @edges.dig(from_code, to_code)
          raise ArgumentError, "duplicate exchange quote for #{from_code} -> #{to_code}"
        end

        @edges[from_code][to_code] = Edge.new(
          from: from_code,
          to: to_code,
          rate: rate,
          fee: build_fee(fee, Currency.wrap(from), Currency.wrap(to)),
        )
      end

      def split_key(key)
        return key if key.is_a?(Array) && key.length == 2

        key.to_s.split(RatesStore::Memory::INDEX_KEY_SEPARATOR)
      end

      def rate_value(hash)
        hash[:rate] || hash["rate"] ||
          hash[:exchange_rate] || hash["exchange_rate"]
      end

      def fee_value(hash)
        hash[:fee] || hash["fee"] ||
          hash[:fixed_fee] || hash["fixed_fee"]
      end

      def build_fee(fee, from_currency, to_currency)
        return Money.new(0, from_currency) if fee.nil?
        return fee if fee.is_a?(Money)

        if fee.is_a?(Hash)
          amount = fee[:amount] || fee["amount"] ||
                   fee[:fee_amount] || fee["fee_amount"] ||
                   fee[:fee] || fee["fee"] ||
                   fee[:fixed_fee] || fee["fixed_fee"]
          currency = fee[:currency] || fee["currency"] ||
                     fee[:fee_currency] || fee["fee_currency"] || from_currency
          currency = Currency.wrap(currency)
        else
          amount = fee
          currency = from_currency
        end

        unless [from_currency, to_currency].include?(currency)
          raise ArgumentError, "fee currency must be either edge endpoint"
        end

        amount = BigDecimal(amount.to_s)
        raise ArgumentError, "fees must be non-negative" if amount.negative?

        Money.new(amount, currency)
      end

      def complete_and_freeze
        @edges.each do |from, outgoing|
          outgoing.each do |to, edge|
            raise ArgumentError, "missing exchange rate for #{from} -> #{to}" unless edge.rate

            edge.freeze
          end
          outgoing.freeze
        end
        @edges.freeze
        freeze
      end
    end

    # Details for one conversion, including the source fee and rounded amount.
    class ExchangeHop
      attr_reader :from_currency, :to_currency, :rate, :fee,
                  :input_amount, :amount_after_fee, :output_amount

      def initialize(from_currency:, to_currency:, rate:, fee:,
                     input_amount:, amount_after_fee:, output_amount:)
        @from_currency = from_currency
        @to_currency = to_currency
        @rate = rate
        @fee = fee
        @input_amount = input_amount
        @amount_after_fee = amount_after_fee
        @output_amount = output_amount
      end

      def from
        from_currency
      end

      def to
        to_currency
      end

      def amount
        output_amount
      end

      def amount_after
        output_amount
      end

      def before_amount
        input_amount
      end

      def [](key)
        to_h[key]
      end

      def to_h
        {
          from_currency: from_currency,
          to_currency: to_currency,
          from: from_currency,
          to: to_currency,
          rate: rate,
          fee: fee,
          input_amount: input_amount,
          amount_before: input_amount,
          before_amount: input_amount,
          amount_after_fee: amount_after_fee,
          after_fee: amount_after_fee,
          output_amount: output_amount,
          amount_after: output_amount,
          amount: output_amount,
        }
      end
    end

    # Complete bounded route and the Money ultimately received.
    class ExchangeRoute
      attr_reader :input_amount, :hops

      def initialize(input_amount, hops)
        @input_amount = input_amount
        @hops = hops
      end

      def final_amount
        hops.empty? ? input_amount : hops.last.output_amount
      end
      alias amount final_amount
      alias money final_amount
      alias output_amount final_amount

      def currencies
        [input_amount.currency.iso_code, *hops.map { |hop| hop.to_currency.iso_code }]
      end
      alias path currencies

      def amounts
        [input_amount, *hops.map(&:output_amount)]
      end

      def fees
        hops.map(&:fee)
      end

      def rates
        hops.map(&:rate)
      end

      def hops_count
        hops.length
      end
      alias length hops_count

      def to_money
        final_amount
      end

      def [](key)
        to_h[key]
      end

      def to_a
        hops.map(&:to_h)
      end

      def to_h
        {
          currencies: currencies,
          path: currencies,
          amounts: amounts,
          fees: fees,
          rates: rates,
          hops: hops.map(&:to_h),
          input_amount: input_amount,
          final_amount: final_amount,
          amount: final_amount,
          output_amount: final_amount,
        }
      end
    end

    # Enumerates every bounded path rather than pruning by intermediate amount.
    class ExchangeRoutePlanner
      def initialize(bank)
        @bank = bank
      end

      def call(from, target_currency, quote, max_hops, rounding_method: nil)
        unless max_hops.is_a?(Integer) && max_hops >= 0
          raise ArgumentError, "max_hops must be a non-negative Integer"
        end
        raise ArgumentError, "input amount must be non-negative" if from.fractional.negative?

        target = Currency.wrap(target_currency)
        best = nil

        visit = lambda do |current, used, route_hops|
          if current.currency == target
            candidate = ExchangeRoute.new(from, route_hops)
            best = better?(candidate, best) ? candidate : best
          end

          return if used == max_hops

          quote.outgoing(current.currency.iso_code).each do |edge|
            hop = hop_for(current, edge, rounding_method)
            visit.call(hop.output_amount, used + 1, route_hops + [hop]) if hop
          end
        end

        visit.call(from, 0, [])
        best
      end

      private

      attr_reader :bank

      # More money wins. Ties prefer fewer hops and then lexicographic path.
      def better?(candidate, best)
        return true if best.nil?

        amount_comparison = candidate.final_amount.fractional <=> best.final_amount.fractional
        return amount_comparison.positive? unless amount_comparison.zero?

        hop_comparison = best.hops_count <=> candidate.hops_count
        return hop_comparison.positive? unless hop_comparison.zero?

        (best.currencies <=> candidate.currencies).positive?
      end

      def hop_for(amount, edge, rounding_method)
        to_currency = Currency.wrap(edge.to)
        after_fee, output = converted_amounts(amount, to_currency, edge, rounding_method)
        return unless after_fee && output
        return if after_fee.fractional.negative? || output.fractional.negative?

        ExchangeHop.new(
          from_currency: amount.currency,
          to_currency: to_currency,
          rate: edge.rate,
          fee: edge.fee,
          input_amount: amount,
          amount_after_fee: after_fee,
          output_amount: output,
        )
      end

      def converted_amounts(amount, to_currency, edge, rounding_method)
        if edge.fee.currency == amount.currency
          after_fee = amount.dup_with(
            fractional: amount.fractional - edge.fee.fractional,
            currency: amount.currency, bank: bank,
          )
          return [nil, nil] if after_fee.fractional.negative?

          converted = convert(after_fee, to_currency, edge.rate, rounding_method)
          [after_fee, converted]
        else
          converted = convert(amount, to_currency, edge.rate, rounding_method)
          after_fee = converted.dup_with(
            fractional: converted.fractional - edge.fee.fractional,
            currency: to_currency, bank: bank,
          )
          return [nil, nil] if after_fee.fractional.negative?

          output = if rounding_method || bank.rounding_method
                     after_fee
                   else
                    after_fee.dup_with(
                      fractional: round_to_cash(after_fee.fractional, to_currency),
                      currency: to_currency, bank: bank,
                    )
                   end
          [after_fee, output]
        end
      end

      def convert(amount, to_currency, rate, rounding_method)
        unit_ratio = BigDecimal(amount.currency.subunit_to_unit.to_s) /
                     BigDecimal(to_currency.subunit_to_unit.to_s)
        raw = BigDecimal(amount.fractional.to_s) / unit_ratio * rate
        amount.dup_with(
          fractional: round_cash(raw, to_currency, rounding_method),
          currency: to_currency, bank: bank,
        )
      end

      def round_cash(raw, currency, rounding_method)
        method = rounding_method || bank.rounding_method
        if method
          rounded = method.call(raw)
          return Money.default_infinite_precision ? BigDecimal(rounded.to_s) : rounded.to_i
        end

        round_to_cash(raw, currency)
      end

      def round_to_cash(fractional, currency)
        denomination = BigDecimal((currency.smallest_denomination || 1).to_s)
        rounded = (fractional / denomination).round(0, Money.rounding_mode) * denomination
        Money.default_infinite_precision ? rounded : rounded.to_i
      end
    end
  end
end
