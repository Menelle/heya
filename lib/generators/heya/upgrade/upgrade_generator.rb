# frozen_string_literal: true

class Heya::UpgradeGenerator < Rails::Generators::Base
  include Rails::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  def copy_migrations
    migration_template "add_scheduled_for_to_heya_campaign_memberships.rb",
      "db/migrate/add_scheduled_for_to_heya_campaign_memberships.rb"
  end

  def self.next_migration_number(dirname)
    next_migration_number = current_migration_number(dirname) + 1
    ActiveRecord::Migration.next_migration_number(next_migration_number)
  end
end
