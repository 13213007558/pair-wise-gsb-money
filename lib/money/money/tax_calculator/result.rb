# frozen_string_literal: true

class Money
  class TaxCalculator
    # The complete result of one forward or reverse calculation.
    Result = Struct.new(
      :net,
      :taxes,
      :tax_total,
      :gross,
      :cash_total,
      keyword_init: true,
    )
  end
end
