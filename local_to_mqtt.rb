# frozen_string_literal: true

require 'date'
require 'json'
require 'net/http'
require 'optparse'

require 'descriptive_statistics'
require 'dotenv'
require 'mqtt'
Dotenv.load
Dotenv.require_keys('MQTT_BROKER_HOST', 'MQTT_USERNAME', 'MQTT_PASSWORD', 'SOUTH_WEST_LAT', 'SOUTH_WEST_LONG', 'NORTH_EAST_LAT', 'NORTH_EAST_LONG')

### Configuration ###
options = {
  # Defaults
  limit: 100,
  update_frequency: 60,
  max_age: 180,
  discovery_prefix: 'homeassistant',
  debug: false,
  no_send: false,
  error_limit: 3
}
OptionParser.new do |opts|
  opts.banner = "Usage: local_to_mqtt.rb [options]"

  opts.on('-l LIMIT', '--limit LIMIT', Integer, 'Limit to the number of stations to check') { |v| options[:limit] = v }
  opts.on('-f FREQ', '--update_frequency FREQ', Integer, 'Time between refreshes, in seconds') { |v| options[:update_frequency] = v }
  opts.on('-m AGE', '--max_age AGE', Integer, 'Maximum age of data to collect, in seconds') { |v| options[:update_frequency] = v }
  opts.on('-p PREFIX', '--discovery_prefix PREFIX', 'The home assistant discovery prefix') { |v| options[:discovery_prefix] = v }
  opts.on('-d [FLAG]', '--debug [FLAG]', TrueClass, 'Set to true to print debug logs to console while running') { |v| options[:debug] = v.nil? ? true : v }
  opts.on('-n [FLAG]', '--no_send [FLAG]', TrueClass, 'Set to true to prevent sending data to MQTT') { |v| options[:no_send] = v.nil? ? true : v }
  opts.on('-e ERROR_LIMIT', '--error_limit ERROR_LIMIT', Integer, 'How many consecutive HTTP errors before aborting (0 for no limit)') { |v| options[:error_limit] = v }
end.parse!

### Setup ###
keys_to_collect = JSON.parse(File.read('keys_to_collect.json'), symbolize_names: true)
# Weather API HTTP connection
url = "https://lightning.ambientweather.net/devices?$publicBox[0][0]=#{ENV['SOUTH_WEST_LAT']}&$publicBox[0][1]=#{ENV['SOUTH_WEST_LONG']}&$publicBox[1][0]=#{ENV['NORTH_EAST_LAT']}&$publicBox[1][1]=#{ENV['NORTH_EAST_LONG']}&$limit=#{options[:limit]}"
# TODO: What if this returns no stations/is malformed?

puts url if options[:debug]
uri = URI(url)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

# MQTT Connection
client = MQTT::Client.new
client.username = ENV['MQTT_USERNAME']
client.password = ENV['MQTT_PASSWORD']
client.host     = ENV['MQTT_BROKER_HOST']
client.will_topic = 'area_weather/status'
client.will_payload = 'offline'

# Send config info for the sensors we will publish to MQTT
client.connect do |c|
  c.publish('area_weather/status', 'online', retain = true) unless options[:no_send]
  keys_to_collect.each do |key|
    config_payload = {
      "name": key[:mqtt_name],
      "unique_id": "area_weather_#{key[:mqtt_name]}",
      "availability_topic": "area_weather/status",
      "state_class": "measurement",
      "state_topic": "area_weather/#{key[:mqtt_name]}/state",
      "json_attributes_topic": "area_weather/#{key[:mqtt_name]}/attributes"
    }
    config_payload[:icon] = key[:icon] unless key[:icon].nil?
    config_payload[:device_class] = key[:device_class] unless key[:device_class].nil?
    config_payload[:unit_of_measurement] = key[:unit] unless key[:unit].nil?
    config_payload[:expire_after] = key[:expire_after] unless key[:expire_after].nil?
    c.publish("#{options[:discovery_prefix]}/sensor/area_weather/#{key[:mqtt_name]}/config", config_payload.to_json, retain = true) unless options[:no_send]
  end
end

error_count = 0

### Main Loop ###
begin
  loop do
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    weather_payload = JSON.parse(response.body, symbolize_names: true)[:data]
    values = Hash.new { |h, k| h[k] = [] }

    # Parse through API data and find each weather station
    weather_payload.each do |station|
      # Check if this station has recent data, and skip it if not
      next if station[:lastData][:created_at].nil?
      data_dt = Time.at(station[:lastData][:created_at] / 1000.0).to_datetime
      next if data_dt < Time.at(Time.now.to_i - options[:max_age]).to_datetime

      # Get all the values we will analyze from this weather station, store them in arrays for later
      keys_to_collect.map { |e| e[:aw_key_name] }.uniq.each do |aw_key_name|
        values[aw_key_name].append(station[:lastData][aw_key_name.to_sym]) unless station[:lastData][aw_key_name.to_sym].nil?
      end

      puts "#{station[:_id]} #{station[:info][:name]} #{data_dt} #{station[:lastData][:tempf]}" if options[:debug]
    end

    puts "keys:\n#{keys_to_collect}" if options[:debug]
    puts "values:\n#{values}" if options[:debug]

    # Now that we have all the data in arrays, analyze each array and find the correct percentile value, publish it to MQTT
    client.connect do |c|
      keys_to_collect.each do |key|
        # TODO: What if there are no values of this type?  Maybe fall back to another type?  Should there be some minimum number required to report it?
        result = values[key[:aw_key_name]].percentile(key[:percentile])&.round(4)
        puts "#{key[:mqtt_name]} (#{key[:aw_key_name]}:#{key[:percentile]}, #{values[key[:aw_key_name]].count}) - #{result}" if options[:debug]
        unless result.nil? || options[:no_send]
          c.publish("area_weather/#{key[:mqtt_name]}/state", result)
          c.publish("area_weather/#{key[:mqtt_name]}/attributes", { aw_key_name: key[:aw_key_name], station_count: values[key[:aw_key_name]].count, min_value: values[key[:aw_key_name]].min, max_value: values[key[:aw_key_name]].max }.to_json)
        end
      end
    end

    error_count = 0
    sleep(options[:update_frequency])
  rescue SocketError, Timeout::Error, JSON::ParserError, Errno::EPIPE => e
    error_count += 1
    # TODO: Should this be shown even if debug is set to false?  Maybe another flag 'silent' that surpresses all output
    puts "Retrying after error: #{e.class} - #{e.message} ##{error_count}" if options[:debug]
    raise e, "Too many HTTP errors" if options[:error_limit].positive? && error_count >= options[:error_limit]
    sleep(options[:update_frequency])
  end
rescue Interrupt => e
  puts "Interrupt: #{e.class}\n#{e.message}\n#{e.backtrace.join("\n")}" if options[:debug]
rescue SignalException => e
  puts "SignalException: #{e.class}\n#{e.message}\n#{e.backtrace.join("\n")}" if options[:debug]
rescue StandardError => e
  puts "Exception: #{e.class}\n#{e.message}\n#{e.backtrace.join("\n")}" if options[:debug]
ensure
  puts "ensure" if options[:debug]
  # Send 'offline' as our status if the script is terminated
  client.connect do |c|
    c.publish('area_weather/status', 'offline', retain = false) unless options[:no_send] # rubocop:disable Lint/UselessAssignment
  end
  client.disconnect
  puts "done" if options[:debug]
end
