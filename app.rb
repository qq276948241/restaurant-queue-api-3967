require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'securerandom'
require 'rack/cors'

use Rack::Cors do
  allow do
    origins '*'
    resource '*', headers: :any, methods: [:get, :post, :put, :options]
  end
end

DB = Sequel.sqlite('queue.db')

unless DB.table_exists?(:queue_items)
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
else
  DB.alter_table :queue_items do
    add_column :priority, Integer, default: 0 unless DB[:queue_items].columns.include?(:priority)
    add_column :created_at, DateTime unless DB[:queue_items].columns.include?(:created_at)
    add_column :called_at, DateTime unless DB[:queue_items].columns.include?(:called_at)
    add_column :completed_at, DateTime unless DB[:queue_items].columns.include?(:completed_at)
  end
end

unless DB.table_exists?(:call_records)
  DB.create_table :call_records do
    primary_key :id
    Integer :queue_item_id
    String :table_type
    DateTime :called_at
  end
end

require_relative 'helpers/api_helper'
require_relative 'models/queue_item'
require_relative 'models/call_record'

helpers ApiHelper

before do
  content_type :json
  QueueItem.expire_timeout!
end

Dir[File.join(__dir__, 'routes', '*.rb')].each { |file| require_relative file }
