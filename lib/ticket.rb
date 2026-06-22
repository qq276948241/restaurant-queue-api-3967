require 'securerandom'
require 'time'

class Ticket
  attr_reader :id, :number, :table_type, :vip, :people_count, :status, :created_at, :called_at

  def initialize(number, table_type, vip = false, people_count = nil)
    @id = SecureRandom.uuid
    @number = number
    @table_type = table_type
    @vip = vip
    @people_count = people_count
    @status = 'waiting'
    @created_at = Time.now
    @called_at = nil
  end

  def call!
    @status = 'called'
    @called_at = Time.now
    self
  end

  def called?
    @status == 'called'
  end

  def waiting?
    @status == 'waiting'
  end

  def to_h
    {
      id: @id,
      number: @number,
      table_type: @table_type,
      vip: @vip,
      people_count: @people_count,
      status: @status,
      created_at: @created_at.iso8601,
      called_at: @called_at&.iso8601
    }
  end
end
