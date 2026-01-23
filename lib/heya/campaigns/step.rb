# frozen_string_literal: true

require "ostruct"

module Heya
  module Campaigns
    class Step < OpenStruct
      include GlobalID::Identification

      def self.find(id)
        campaign_name, _step_name = id.to_s.split("/")
        campaign_name.constantize.steps.find { |s| s.id == id }
      end

      def initialize(id:, name:, campaign:, position:, action:, wait:, segment:, queue:, send_at: nil, params: {})
        super
        if action.respond_to?(:validate_step)
          action.validate_step(self)
        end
      end

      def gid
        to_gid(app: "heya").to_s
      end

      def in_segment?(user)
        Heya.in_segments?(user, *campaign.__segments, segment)
      end

      def campaign_name
        @campaign_name ||= campaign.name
      end

      # Returns true if this step has a send_at time specified.
      def has_send_at?
        !send_at.nil?
      end

      # Returns the parsed send_at hour, or nil if not specified.
      def send_at_hour
        parsed = ScheduleCalculator.parse_send_at(send_at)
        parsed&.first
      end

      # Returns the parsed send_at minute, or nil if not specified.
      def send_at_minute
        parsed = ScheduleCalculator.parse_send_at(send_at)
        parsed&.last
      end
    end
  end
end
