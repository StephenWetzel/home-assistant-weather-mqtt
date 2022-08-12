require 'net/http'
require 'date'
require 'json'
require 'mqtt'
require 'dotenv'
require 'descriptive_statistics'
Dotenv.load
Dotenv.require_keys('MQTT_BROKER_HOST', 'MQTT_USERNAME', 'MQTT_PASSWORD', 'SOUTH_WEST_LAT', 'SOUTH_WEST_LONG', 'NORTH_EAST_LAT', 'NORTH_EAST_LONG')

### Configuration ###
# TODO: Document attributes in this array
keys_to_collect = [
  {key_name: :uv, percentile: 100, unit: 'UV index', device_class: 'illuminance', mqtt_name: 'area_uv_max'},
  {key_name: :uv, percentile: 90, unit: 'UV index', device_class: 'illuminance', mqtt_name: 'area_uv_90_percentile'},
  {key_name: :uv, percentile: 50, unit: 'UV index', device_class: 'illuminance', mqtt_name: 'area_uv_median'},
  {key_name: :feelsLike, percentile: 50, unit: '°F', device_class: 'temperature', mqtt_name: 'area_feels_like_median'}
]
limit = 100 # Limit to the number of stations to check
update_frequency = 60 # Time between refreshes, in seconds
discovery_prefix = 'homeassistant' # The home assistant discovery prefix, default: 'homeassistant'
debug = false # Set to true to print debug logs to console while running

### Setup ###
# Weather API HTTP connection
url = "https://lightning.ambientweather.net/devices?$publicBox[0][0]=#{ENV['SOUTH_WEST_LAT']}&$publicBox[0][1]=#{ENV['SOUTH_WEST_LONG']}&$publicBox[1][0]=#{ENV['NORTH_EAST_LAT']}&$publicBox[1][1]=#{ENV['NORTH_EAST_LONG']}&$limit=#{limit}"
# TODO: What if this returns no stations/is malformed?

puts url if debug
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
  c.publish('area_weather/status', 'online', retain=false)
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
    c.publish("#{discovery_prefix}/sensor/area_weather/#{key[:mqtt_name]}/config", config_payload.to_json, retain=true)
  end
end

### Main Loop ###
begin
  # TODO: Should this connect just be down in the loop that sends the update?
  # Will that make it more robust?  How to detect when we lose a connection?
  client.connect do |c|
    while true
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      weather_payload = JSON.parse(response.body, symbolize_names: true)[:data]
      values = Hash.new { |h, k| h[k] = [] }

      # Parse through API data and find each weather station
      weather_payload.each do |station|
        # Check if this station has recent data, and skip it if not
        next if station[:lastData][:created_at].nil?
        data_dt = Time.at(station[:lastData][:created_at] / 1000.0).to_datetime
        next if data_dt < Time.at(Time.now.to_i - update_frequency).to_datetime

        # Get all the values we will analyze from this weather station, store them in arrays for later
        keys_to_collect.map {|e| e[:key_name]}.uniq.each do |key_name|
          values[key_name].append(station[:lastData][key_name]) unless station[:lastData][key_name].nil?
        end

        puts "#{station[:_id]} #{station[:info][:name]} #{data_dt} #{station[:lastData][:tempf]}" if debug
      end

      puts "keys:\n#{keys_to_collect}" if debug
      puts "values:\n#{values}" if debug

      # Now that we have all the data in arrays, analyze each array and find the correct percentile value, publish it to MQTT
      keys_to_collect.each do |key|
        result = values[key[:key_name]].percentile(key[:percentile]).round(4)
        puts "#{key[:mqtt_name]} (#{key[:key_name]}:#{key[:percentile]}, #{values[key[:key_name]].count}) - #{result}" if debug
        c.publish("area_weather/#{key[:mqtt_name]}/state", result)
        c.publish("area_weather/#{key[:mqtt_name]}/attributes", {key_name: key[:key_name], station_count: values[key[:key_name]].count, min_value: values[key[:key_name]].min, max_value: values[key[:key_name]].max}.to_json)
      end

      sleep(update_frequency)
    end
  end
rescue Interrupt => e
  puts "Interrupt: #{e}" if debug
rescue SignalException => e
  puts "SignalException: #{e}" if debug
rescue Exception => e
  puts "Exception: #{e}" if debug
ensure
  puts "ensure" if debug
  # Send 'offline' as our status if the script is terminated
  client.connect do |c|
    c.publish('area_weather/status', 'offline', retain=false)
  end
  client.disconnect
  puts "done" if debug
end
