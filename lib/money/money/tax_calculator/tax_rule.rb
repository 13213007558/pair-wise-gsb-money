# frozen_string_literal: true

class Money
  class TaxCalculator
    # A configured tax and the previously rounded amounts its base depends on.
    TaxRule = Struct.new(
      :name,
      :rate,
      :dependencies,
      :rounding_step,
      :rounding_mode,
      keyword_init: true,
    )
  end
end
