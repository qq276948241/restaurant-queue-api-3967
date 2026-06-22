require 'sinatra'

get '/health' do
  json status: 'ok', time: Time.now.iso8601
end
