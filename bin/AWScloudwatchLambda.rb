#!/usr/bin/env ruby

$:.unshift File.join(File.dirname(__FILE__), *%w[.. conf])
$:.unshift File.join(File.dirname(__FILE__), *%w[.. lib])

require 'config'
# require 'Sendit'
require 'rubygems' if RUBY_VERSION < "1.9"
require 'fog'
require 'aws-sdk'
require 'optparse'

$options = {
    :start_offset => 600,
    :end_offset => 0
}

optparse = OptionParser.new do|opts|
  opts.banner = "Usage: AWScloudwatchLambda.rb [options]"

  opts.on('-d', '--dryrun', 'Dry run, does not send metrics') do |d|
    $options[:dryrun] = d
  end

  opts.on('-v', '--verbose', 'Run verbosely') do |v|
    $options[:verbose] = v
  end

  opts.on( '-s', '--start-offset [OFFSET_SECONDS]', 'Time in seconds to offset from current time as the start of the metrics period. Default 600') do |s|
    $options[:start_offset] = s
  end

  opts.on( '-e', '--end-offset [OFFSET_SECONDS]', 'Time in seconds to offset from current time as the start of the metrics period. Default 0') do |e|
    $options[:end_offset] = e
  end

  opts.on( '-h', '--help', '' ) do
    puts opts
    exit
  end
end

optparse.parse!

require 'Sendit'

$runStart  = Time.now.utc
$metricsSent = 0
$collectionRetries = 0
$sendRetries = Hash.new(0)
my_script_tags = {}
my_script_tags[:script] = "AWScloudwatchLambda"
my_script_tags[:account] = "nonprod"

startTime = Time.now.utc - $options[:start_offset].to_i
endTime  = Time.now.utc - $options[:end_offset].to_i

functions = ['global']
creds = Aws::Credentials.new($awsaccesskey, $awssecretkey)
lambda_sdk = Aws::Lambda::Client.new(:region => $awsregion, credentials:creds)
all_functions = lambda_sdk.list_functions
all_functions.functions.each do |func|
  functions << func.function_name
end

lambdaMetrics = [
    {
        :name => "Duration",
        :unit => "Milliseconds",
        :stats => ["Average"]
    },
    {
        :name => "Errors",
        :unit => "Count",
        :stats => ["Maximum"],
    },
    {
        :name => "Invocations",
        :unit => "Count",
        :stats => ["Average"],
    },
    {
        :name => "Throttles",
        :unit => "Count",
        :stats => ["Average"],
    }
]


cloudwatch = Fog::AWS::CloudWatch.new(:aws_secret_access_key => $awssecretkey, :aws_access_key_id => $awsaccesskey, :region => $awsregion)

functions.each do |func|
  lambdaMetrics.each do |metric|
    dimensions = case func
    when /^global$/
      { }
    else
      { 'Name' => 'FunctionName', 'Value' => func }
    end
    responses = cloudwatch.get_metric_statistics({
                                                  'Statistics' => metric[:stats],
                                                  'StartTime' => startTime.iso8601,
                                                  'EndTime' => endTime.iso8601,
                                                  'Period' => 60,
                                                  'Unit' => metric[:unit],
                                                  'MetricName' => metric[:name],
                                                  'Namespace' => 'AWS/Lambda',
                                                  'Dimensions' => [
                                                    dimensions
                                                  ]
                                                 }).body['GetMetricStatisticsResult']['Datapoints']

    metric[:stats].each do |stat|
      responses.each do |response|
        metricpath = "AWScloudwatch.Lambda." + func + "." + metric[:name] + "." + stat
        begin
          metricvalue = response[stat]
          metrictimestamp = response["Timestamp"].to_i.to_s

          Sendit metricpath, metricvalue, metrictimestamp
          $metricsSent += 1
        rescue
          # ignored
        end
      end
    end
  end
end

$runEnd = Time.new.utc
$runDuration = $runEnd - $runStart

Sendit "vacuumetrix.#{my_script_tags[:script]}.run_time_sec", $runDuration, $runStart.to_i.to_s, my_script_tags
Sendit "vacuumetrix.#{my_script_tags[:script]}.metrics_sent", $metricsSent, $runStart.to_i.to_s, my_script_tags
Sendit "vacuumetrix.#{my_script_tags[:script]}.collection_retries", $collectionRetries, $runStart.to_i.to_s, my_script_tags
$sendRetries.each do |k, v|
  Sendit "vacuumetrix.#{my_script_tags[:script]}.send_retries_#{k.to_s}", v, $runStart.to_i.to_s, my_script_tags
end
