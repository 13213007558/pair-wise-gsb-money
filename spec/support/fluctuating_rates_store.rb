# frozen_string_literal: true

# A rates store whose rate changes on every read. It is intentionally a
# plain store object (no caching) so any repeated lookups are observable.
class FluctuatingRatesStore
  attr_reader :read_count

  def initialize(seed_rates)
    @seed_rates = seed_rates
    @read_count = 0
  end

  def add_rate(from, to, rate)
    @seed_rates[[from, to]] = BigDecimal(rate.to_s)
  end

  def get_rate(from, to)
    from = Money::Currency.wrap(from).iso_code
    to = Money::Currency.wrap(to).iso_code
    base = @seed_rates[[from, to]]
    return nil if base.nil?

    @read_count += 1
    base + BigDecimal(@read_count) * BigDecimal("0.1")
  end

  def transaction
    yield
  end

  def each_rate
    @seed_rates.each { |(from, to), rate| yield(from, to, rate) }
  end

  def marshal_dump
    [@seed_rates, @read_count]
  end
end
