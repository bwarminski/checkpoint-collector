# ABOUTME: Creates the minimal table needed by the fixture app seed script.
# ABOUTME: Keeps the integration fixture schema deliberately small.
class CreateFixtureRecords < ActiveRecord::Migration[7.1]
  def change
    create_table :fixture_records do |t|
      t.string :label, null: false
      t.timestamps null: false
    end
  end
end
