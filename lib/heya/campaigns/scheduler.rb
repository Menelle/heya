# frozen_string_literal: true

module Heya
  module Campaigns
    # {Campaigns::Scheduler} schedules campaign jobs to run for each campaign.
    #
    # For each step in each campaign:
    #   1. Find users who haven't completed step, and are outside the `wait`
    #   window
    #   2. Match segment
    #   3. Create CampaignReceipt (excludes user in subsequent steps)
    #   4. Process job
    class Scheduler
      def run(user: nil)
        Heya.campaigns.each do |campaign|
          if campaign.steps.any?
            Queries::OrphanedMemberships.call(campaign).update_all(step_gid: campaign.steps.first.gid)
          end
        end

        Queries::MembershipsToProcess.call(user: user).find_each do |membership|
          step = GlobalID::Locator.locate(membership.step_gid)
          campaign = GlobalID::Locator.locate(membership.campaign_gid)

          if membership.user.nil?
            # User not found; delete orphaned memberships and receipts.
            CampaignReceipt.where(
              user_type: membership.user_type,
              user_id: membership.user_id
            ).delete_all
            CampaignMembership.where(
              user_type: membership.user_type,
              user_id: membership.user_id
            ).delete_all
            next
          end

          process(campaign, step, membership)

          if (next_step = get_next_step(campaign, step, membership.user))
            next_scheduled_for = calculate_next_scheduled_for(
              campaign: campaign,
              next_step: next_step,
              current_membership: membership
            )
            membership.update(step_gid: next_step.gid, scheduled_for: next_scheduled_for)
          else
            membership.destroy
          end
        end
      end

      private

      def get_next_step(campaign, step, user)
        receipt_gids = CampaignReceipt
          .where(user: user, step_gid: campaign.steps.map(&:gid))
          .pluck(:step_gid)
          .uniq
        current_index = campaign.steps.index(step)
        campaign.steps[(current_index + 1)..].find { |s| receipt_gids.exclude?(s.gid) }
      end

      def calculate_next_scheduled_for(campaign:, next_step:, current_membership:)
        # Use last_sent_at as reference (tracks last actually sent step).
        # This ensures skipped steps don't delay subsequent steps - the next
        # step's timing is calculated from when the last email was actually sent.
        # Falls back to current time for new memberships with no sends yet.
        reference_time = current_membership.last_sent_at || Time.now.utc
        time_zone = campaign.class.time_zone

        scheduled_for = ScheduleCalculator.calculate_scheduled_for(
          step: next_step,
          reference_time: reference_time,
          time_zone: time_zone
        )

        # Ensure we don't schedule for a past date (can happen after skips).
        # If the calculated date is in the past, roll forward to next occurrence.
        ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: next_step.send_at,
          time_zone: time_zone
        )
      end

      def process(campaign, step, membership)
        user = membership.user

        ActiveRecord::Base.transaction do
          return if CampaignReceipt.where(user: user, step_gid: step.gid).exists?

          if step.in_segment?(user)
            now = Time.now.utc
            Queries::MembershipsForUpdate.call(campaign, user).update_all(last_sent_at: now)
            CampaignReceipt.create!(user: user, step_gid: step.gid, sent_at: now)
            step.action.new(user: user, step: step).deliver_later
          else
            # Mark step as skipped (sent_at: nil distinguishes from sent)
            CampaignReceipt.create!(user: user, step_gid: step.gid, sent_at: nil)
          end
        end
      end
    end
  end
end
