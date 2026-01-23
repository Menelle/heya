# frozen_string_literal: true

require "ostruct"

module Heya
  class Config < OpenStruct
    def initialize
      super(
        user_type: "User",
        default_time_zone: "UTC",
        campaigns: OpenStruct.new(
          priority: [],
          default_options: {}
        ),
      )
    end
  end
end
