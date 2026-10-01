# frozen_string_literal: true

require "bigdecimal"

class Money
  class ExchangeRateConsistency
    class Snapshot
      attr_reader :adjacency, :vertices

      def self.build(snapshot)
        new(snapshot).build
      end

      def initialize(snapshot)
        @snapshot = snapshot
        @adjacency = Hash.new { |hash, currency| hash[currency] = {} }

        normalize_snapshot
        @vertices = @adjacency.keys.sort.freeze
      end

      def build
        { adjacency: adjacency, vertices: vertices }
      end

      private

      def normalize_snapshot
        if @snapshot.is_a?(Hash)
          normalize_hash(@snapshot)
        elsif @snapshot.respond_to?(:each_rate)
          normalize_enumerator(rate_enumerator(@snapshot))
        elsif @snapshot.respond_to?(:store) && @snapshot.store.respond_to?(:each_rate)
          normalize_enumerator(rate_enumerator(@snapshot.store))
        elsif @snapshot.is_a?(Array)
          normalize_enumerator(@snapshot)
        else
          raise InvalidSnapshot, "exchange-rate snapshot must be a Hash, Array of triples, or respond to #each_rate"
        end
      end

      def normalize_hash(hash)
        hash.each do |from, value|
          if value.is_a?(Hash)
            value.each { |to, rate| add_rate(from, to, rate) }
          else
            add_flat_rate(from, value)
          end
        end
      end

      def add_flat_rate(key, rate)
        case key
        when Array
          unless key.size == 2
            raise_invalid_snapshot("flat rate key must contain from and to currencies")
          end

          add_rate(key[0], key[1], rate)
        when String, Symbol
          from, to = key.to_s.split("_TO_", 2)
          if from.nil? || to.nil? || from.empty? || to.empty?
            raise_invalid_snapshot("flat rate key must be in the FROM_TO_TO format")
          end

          add_rate(from, to, rate)
        else
          raise_invalid_snapshot("unsupported exchange-rate key #{key.inspect}")
        end
      end

      def normalize_enumerator(enumerable)
        enumerable.each do |*entry|
          entry = entry[0] if entry.size == 1 && entry[0].is_a?(Array)

          unless entry.is_a?(Array) && entry.size == 3
            raise_invalid_snapshot("each rate must be supplied as [from, to, rate]")
          end

          add_rate(entry[0], entry[1], entry[2])
        end
      end

      def rate_enumerator(source)
        Enumerator.new do |yielder|
          source.each_rate do |from, to, rate|
            yielder << [from, to, rate]
          end
        end
      end

      def add_rate(from, to, rate)
        from_code = currency_code(from)
        to_code = currency_code(to)
        rational_rate = rationalize_rate(rate)
        edge = Edge.new(
          from: from_code,
          to: to_code,
          rate: rate,
          rational_rate: rational_rate,
        )

        if @adjacency[from_code].key?(to_code)
          raise InvalidSnapshot, "duplicate directed rate #{from_code} -> #{to_code}"
        end

        @adjacency[from_code][to_code] = edge
        @adjacency[to_code] unless @adjacency.key?(to_code)
      end

      def currency_code(value)
        code =
          case value
          when String then value
          when Symbol then value.to_s
          when Money::Currency then value.iso_code
          else
            raise_invalid_snapshot("currency must be a String, Symbol, or Money::Currency")
          end

        raise_invalid_snapshot("currency cannot be empty") if code.strip.empty?

        code.upcase
      end

      def rationalize_rate(rate)
        rational =
          case rate
          when String
            decimal =
              begin
                BigDecimal(rate)
              rescue ArgumentError
                raise_invalid_rate(rate)
              end

            raise_invalid_rate(rate) unless decimal.finite? && decimal.positive?
            decimal.to_r
          when BigDecimal
            raise_invalid_rate(rate) unless rate.finite? && rate.positive?
            rate.to_r
          when Integer, Rational then rate.to_r
          when Float
            raise_invalid_rate(rate) unless rate.finite?
            rate.to_r
          else
            raise_invalid_rate(rate)
          end

        raise_invalid_rate(rate) unless rational.positive?
        rational
      end

      def raise_invalid_rate(rate)
        raise InvalidRate, "exchange rate must be a finite positive Numeric or numeric String, got #{rate.inspect}"
      end

      def raise_invalid_snapshot(message)
        raise InvalidSnapshot, message
      end
    end
  end
end
