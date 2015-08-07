#!/usr/bin/env ruby
## grab AWS limits
### gem install fog  --no-ri --no-rdoc
### gem install aws-sdk --no-ri --no-rdoc

$:.unshift File.join(File.dirname(__FILE__), *%w[.. conf])
$:.unshift File.join(File.dirname(__FILE__), *%w[.. lib])

require 'config'
# require 'Sendit'
require 'rubygems' if RUBY_VERSION < "1.9"
require 'fog'
require 'json'
require 'aws-sdk'
require 'optparse'
require 'hand-tracked-aws-limits'

$options = {
    :start_offset => 180,
    :end_offset => 120
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: AWScloudwatchLimits.rb [options]"

  opts.on('-d', '--dryrun', 'Dry run, does not send metrics') do |d|
    $options[:dryrun] = d
  end

  opts.on('-v', '--verbose', 'Run verbosely') do |v|
    $options[:verbose] = v
  end

  opts.on('-h', '--help', '') do
    puts opts
    exit
  end
end

optparse.parse!

require 'Sendit'

startTime = Time.now.utc.to_i.to_s
$runStart  = Time.now.utc
$metricsSent = 0
$collectionRetries = 0
$sendRetries = Hash.new(0)
my_script_tags = {}
my_script_tags[:script] = "AWScloudwatchLimits"
my_script_tags[:account] = "nonprod"

creds = Aws::Credentials.new($awsaccesskey, $awssecretkey)
autoscaling_sdk = Aws::AutoScaling::Client.new(region:$awsregion, credentials:creds)
ec2_sdk = Aws::EC2::Client.new(region:$awsregion, credentials:creds)
autoscaling = Fog::AWS::AutoScaling.new(:aws_secret_access_key => $awssecretkey, :aws_access_key_id => $awsaccesskey, :region => $awsregion)
compute = Fog::Compute.new(:provider => :aws, :aws_secret_access_key => $awssecretkey, :aws_access_key_id => $awsaccesskey, :region => $awsregion)
cloudformation = Fog::AWS::CloudFormation.new(:aws_secret_access_key => $awssecretkey, :aws_access_key_id => $awsaccesskey, :region => $awsregion)
elasticbeanstalk = Fog::AWS::ElasticBeanstalk.new(:aws_secret_access_key => $awssecretkey, :aws_access_key_id => $awsaccesskey, :region => $awsregion)

account_limits = {}
account_values = {}

# Only query these "hardcoded" limits if the max values appear in the configs
if $eb_apps
  account_limits['eb_apps'] = $eb_apps
  applications = elasticbeanstalk.applications.all
  account_values['eb_apps'] = applications.length
end
if $eb_versions
  account_limits['eb_versions'] = $eb_versions
  versions = elasticbeanstalk.versions.all
  account_values['eb_versions'] = versions.length
end
if $eb_envs
  account_limits['eb_envs'] = $eb_envs
  environments = elasticbeanstalk.environments.all
  account_values['eb_envs'] = environments.length
end
if $eb_templates
  account_limits['eb_templates'] = $eb_templates
  templates = elasticbeanstalk.templates.all
  account_values['eb_templates'] = templates.length
end
if $max_vpc_securitygroups
  my_groups = compute.describe_security_groups
  vpc_map = Hash.new(0) 
  my_groups[:body]['securityGroupInfo'].map {|group| vpc_map[group['vpcId']] += 1 }
  account_limits['secgroups_per_vpc'] = $max_vpc_securitygroups
  account_values['secgroups_per_vpc'] = vpc_map.values.max
end
if $max_cloudformation_stacks
  cf_stacks = cloudformation.describe_stacks
  account_limits['cloudformation_stacks'] = $max_cloudformation_stacks
  account_values['cloudformation_stacks'] = cf_stacks.data[:body]['Stacks'].length
end

asg_limits = autoscaling_sdk.describe_account_limits()
account_limits['autoscale_groups'] = asg_limits.data.max_number_of_auto_scaling_groups
account_limits['launch_configs'] = asg_limits.data.max_number_of_launch_configurations

ec2_limits = ec2_sdk.describe_account_attributes(attribute_names: ["max-instances","vpc-max-elastic-ips"])
ec2_limits.data.account_attributes.each do |ec2_limit|
  account_limits[ec2_limit.attribute_name.tr('-', '_').sub('max_', '')] = ec2_limit.attribute_values[0].attribute_value
end

autoscalinggroup_list = autoscaling.groups.all
account_values['autoscale_groups'] = autoscalinggroup_list.length
autoscaling_launch_configs = autoscaling.configurations.all
account_values['launch_configs'] = autoscaling_launch_configs.length

vpc_eips = compute.addresses.all
account_values['vpc_elastic_ips'] = vpc_eips.length
current_instances = compute.servers.all
account_values['instances'] = current_instances.length

account_limits.each do |limit, value|
  metricpath = "AWSlimits." + limit + ".max"
  metricvalue = value
  metrictimestamp = startTime
  Sendit metricpath, metricvalue, metrictimestamp
  $metricsSent += 1
end

account_values.each do |limit, value|
  metricpath = "AWSlimits." + limit 
  metricvalue = value
  metrictimestamp = startTime
  Sendit "#{metricpath}.value", metricvalue, metrictimestamp
  Sendit "#{metricpath}.used_percent", (metricvalue.to_i * 100 / account_limits[limit].to_i), metrictimestamp
  $metricsSent += 2
end

$runEnd = Time.new.utc
$runDuration = $runEnd - $runStart

Sendit "vacuumetrix.#{my_script_tags[:script]}.run_time_sec", $runDuration, $runStart.to_i.to_s, my_script_tags
Sendit "vacuumetrix.#{my_script_tags[:script]}.metrics_sent", $metricsSent, $runStart.to_i.to_s, my_script_tags
Sendit "vacuumetrix.#{my_script_tags[:script]}.collection_retries", $collectionRetries, $runStart.to_i.to_s, my_script_tags
$sendRetries.each do |k, v|
  Sendit "vacuumetrix.#{my_script_tags[:script]}.send_retries_#{k.to_s}", v, $runStart.to_i.to_s, my_script_tags
end
