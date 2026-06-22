require 'fileutils'
require 'sequel'

db_path = File.expand_path('../queue.db', __FILE__)

if File.exist?(db_path)
  puts "Removing existing database at #{db_path}..."
  10.times do
    begin
      FileUtils.rm(db_path, force: true)
      break
    rescue => e
      puts "Attempt failed: #{e.message}, retrying..."
      sleep 1
    end
  end
end

if File.exist?(db_path)
  puts "WARNING: Could not remove database file!"
  exit 1
end

puts "Creating new database..."

DB = Sequel.sqlite(db_path)

DB.create_table :queue_items do
  primary_key :id
  String :queue_number, null: false
  String :table_type, null: false
  String :customer_token, null: false, unique: true
  TrueClass :vip, default: false
  String :status, default: 'waiting'
  Integer :priority, default: 0
  DateTime :created_at
  DateTime :called_at
  DateTime :completed_at
  index [:table_type, :status]
  index [:customer_token], unique: true
end

DB.create_table :call_records do
  primary_key :id
  Integer :queue_item_id
  String :table_type
  DateTime :called_at
end

puts "Database created successfully!"
puts "Tables: #{DB.tables.inspect}"
