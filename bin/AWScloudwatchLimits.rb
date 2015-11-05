#!/usr/bin/env ruby
## grab AWS limits
### gem install fog  --no-ri --no-rdoc
### gem install aws-sdk --no-ri --no-rdoc

$:.unshift File.join(File.dirname(__FILE__), *%w[.. conf])
$:.unshift File.join(File.dirname(__FILE__), *%w[.. lib])

require 'config'
require 'rubygems' if RUBY_VERSION < "1.9"
require 'fog'
require 'json'
require 'aws-sdk'
require 'optparse'

begin
  require 'hand-tracked-aws-limits'
rescue LoadError
  puts 'no hand tracked limits'
end

$options = {}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: AWScloudwatchLimits.rb [options]"

  opts.on('-p', '--prefix [STRING]', 'Graphite prefix') do |p|
    $options[:prefix] = p
  end

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

$startTime = Time.now.utc.to_i.to_s
$runStart  = Time.now.utc
$metricsSent = 0
$collectionRetries = 0
$sendRetries = Hash.new(0)
my_script_tags = {}
my_script_tags[:script] = "AWScloudwatchLimits"
my_script_tags[:account] = $aws_account_alias

if $awscredential && $awscredential[:aws_access_key_id]
  Aws.config[:credentials] = Aws::Credentials.new($awscredential[:aws_access_key_id], $awscredential[:aws_secret_access_key])
end
$support = Aws::Support::Client.new(region:'us-east-1')
$autoscaling_sdk = Aws::AutoScaling::Client.new(region:$awsregion)
$ec2_sdk = Aws::EC2::Client.new(region:$awsregion)
$autoscaling = Fog::AWS::AutoScaling.new($awscredential.merge({:region => $awsregion}))
$compute = Fog::Compute.new($awscredential.merge({:region => $awsregion, :provider => :aws}))
$cloudformation = Fog::AWS::CloudFormation.new($awscredential.merge({:region => $awsregion}))
$elasticbeanstalk = Fog::AWS::ElasticBeanstalk.new($awscredential.merge({:region => $awsregion}))
$iam = Fog::AWS::IAM.new($awscredential.merge({:region => 'us-east-1'}))
$iam_sdk = Aws::IAM::Client.new(region:'us-east-1')
$s3 = Fog::Storage.new($awscredential.merge({:region => $awsregion, :provider => :aws}))
$elasticache = Fog::AWS::Elasticache.new($awscredential.merge({:region => $awsregion}))
$r53 = Fog::DNS.new($awscredential.merge({:region => $awsregion, :provider => :aws}))
$dynamodb_sdk = Aws::DynamoDB::Client.new(region:$awsregion)

$account_limits = {}
$account_values = {}

$current_instances = $compute.servers.all

# Fetch limits from Trusted Advisor
def fetch_trusted_advisor()
  # skip these TA checks if we can query at higher resolution
  advisor_checks_to_skip = [
    'Auto_Scaling_groups',
    'Launch_configurations',
    'VPC_Elastic_IP_addresses_EIPs'
  ]
  advisor_checks = $support.describe_trusted_advisor_checks({
    language: "en",
  })
  limits_id = ''
  advisor_checks[0].each do |check|
    limits_id = check.id if check.name == "Service Limits"
  end

  results = $support.describe_trusted_advisor_check_result({
    check_id: limits_id,
    language: "en",
  })

  results.result.flagged_resources.each do |result|
    region = result['metadata'][0]
    service = result['metadata'][1]
    check = result['metadata'][2].tr(' ', '_').tr('(', '').tr(')', '').gsub(/\-_/, '')
    max = result['metadata'][3]
    current = result['metadata'][4]
    next if advisor_checks_to_skip.include? check 

    metricpath = "AWSlimits.#{region}.#{service}.#{check}"
    Sendit "#{metricpath}.max", max, $startTime
    $metricsSent += 1

    # the RI limits only have a max, current value appears to always be nil
    if current
      Sendit "#{metricpath}.value", current, $startTime
      Sendit "#{metricpath}.used_percent", (current.to_i * 100 / max.to_i), $startTime
      $metricsSent += 2
    end
  end
end

# Only query these "hardcoded" limits if the max values appear in the configs
def fetch_hard_coded_limits()
  if $dynamodb_tables || $dynamodb_write_units || $dynamodb_read_units
    is_truncated = true
    exclusive_start_table_name = false
    $my_dynamodb_tables = Array.new
    $my_dynamodb_write_units = 0
    $my_dynamodb_read_units = 0
    while is_truncated do
      dynamodb_tables = exclusive_start_table_name ? $dynamodb_sdk.list_tables(exclusive_start_table_name: exclusive_start_table_name) : $dynamodb_sdk.list_tables()
      $my_dynamodb_tables.concat(dynamodb_tables.data.table_names)
      is_truncated = dynamodb_tables.data.last_evaluated_table_name
      exclusive_start_table_name = dynamodb_tables.data.last_evaluated_table_name
    end
    $my_dynamodb_tables.each {|table|
      my_table = $dynamodb_sdk.describe_table({table_name: table})
      $my_dynamodb_write_units += my_table.table.provisioned_throughput.write_capacity_units
      $my_dynamodb_read_units += my_table.table.provisioned_throughput.read_capacity_units
    }
  end
  if $dynamodb_tables
    $account_limits[$awsregion + '.DynamoDB.dynamodb_tables'] = $dynamodb_tables
    $account_values[$awsregion + '.DynamoDB.dynamodb_tables'] = $my_dynamodb_tables.length
  end
  if $dynamodb_write_units
    $account_limits[$awsregion + '.DynamoDB.dynamodb_write_units'] = $dynamodb_write_units
    $account_values[$awsregion + '.DynamoDB.dynamodb_write_units'] = $my_dynamodb_write_units
  end
  if $dynamodb_read_units
    $account_limits[$awsregion + '.DynamoDB.dynamodb_read_units'] = $dynamodb_read_units
    $account_values[$awsregion + '.DynamoDB.dynamodb_read_units'] = $my_dynamodb_read_units
  end
  if $ec2_flavors
    $my_by_type = Hash.new {|k,v| k[v] = []}
    $current_instances.each {|instance| $my_by_type[instance.flavor_id.tr('.', '_')] << [instance] }
    $ec2_flavors.each {|flavor,limit|
      $account_limits[$awsregion + '.ec2.' + flavor.to_s] = limit
      $account_values[$awsregion + '.ec2.' + flavor.to_s] = $my_by_type[flavor.to_s].length
    }
  end
  if $r53_hosted_zones
    $account_limits[$awsregion + '.R53.r53_hosted_zones'] = $r53_hosted_zones
    hosted_zones = $r53.zones.all
    $account_values[$awsregion + '.R53.r53_hosted_zones'] = hosted_zones.length
  end
  if $elasticache_clusters || $elasticache_total_nodes || $elasticache_max_nodes_per_cluster
    $my_elasticache_clusters = $elasticache.clusters.all
  end
  if $elasticache_clusters
    $account_limits[$awsregion + '.ElastiCache.elasticache_clusters'] = $elasticache_clusters
    $account_values[$awsregion + '.ElastiCache.elasticache_clusters'] = $my_elasticache_clusters.length
  end
  if $elasticache_total_nodes
    $account_limits[$awsregion + '.ElastiCache.elasticache_total_nodes'] = $elasticache_total_nodes
    elasticache_total_nodes = 0
    $my_elasticache_clusters.each {|c| elasticache_total_nodes += c.num_nodes}
    $account_values[$awsregion + '.ElastiCache.elasticache_total_nodes'] = elasticache_total_nodes
  end
  if $elasticache_max_nodes_per_cluster
    $account_limits[$awsregion + '.ElastiCache.elasticache_max_nodes_per_cluster'] = $elasticache_max_nodes_per_cluster
    ec_max_nodes = $my_elasticache_clusters.max_by {|c| c.num_nodes}
    $account_values[$awsregion + '.ElastiCache.elasticache_max_nodes_per_cluster'] = ec_max_nodes.num_nodes
  end
  if $s3_buckets
    # S3 is global, set region to us-east-1
    $account_limits['us-east-1.S3.s3_buckets'] = $s3_buckets
    s3_buckets = $s3.directories.all
    $account_values['us-east-1.S3.s3_buckets'] = s3_buckets.length
  end
  # IAM is global, set region to us-east-1
  if $iam_groups
    $account_limits['us-east-1.IAM.iam_groups'] = $iam_groups
    iam_groups = $iam.groups.all
    $account_values['us-east-1.IAM.iam_groups'] = iam_groups.length
  end
  if $iam_roles
    $account_limits['us-east-1.IAM.iam_roles'] = $iam_roles
    is_truncated = true
    marker = false
    my_iam_roles = Array.new
    while is_truncated do
      iam_roles = marker ? $iam_sdk.list_roles(marker: marker) : $iam_sdk.list_roles()
      my_iam_roles.concat(iam_roles.data.roles)
      is_truncated = iam_roles.data.is_truncated
      marker = iam_roles.data.marker
    end
    $account_values['us-east-1.IAM.iam_roles'] = my_iam_roles.length
  end
  if $iam_policies
    $account_limits['us-east-1.IAM.iam_policies'] = $iam_policies
    is_truncated = true
    marker = false
    my_iam_policies = Array.new
    while is_truncated do
      iam_policies = marker ? $iam_sdk.list_policies(scope: 'Local', marker: marker) : $iam_sdk.list_policies(scope: 'Local')
      my_iam_policies.concat(iam_policies.data.policies)
      is_truncated = iam_policies.data.is_truncated
      marker = iam_policies.data.marker
    end
    $account_values['us-east-1.IAM.iam_policies'] = my_iam_policies.length
  end
  if $iam_profiles
    $account_limits['us-east-1.IAM.iam_profiles'] = $iam_profiles
    is_truncated = true
    marker = false
    my_iam_profiles = Array.new
    while is_truncated do
      iam_profiles = marker ? $iam_sdk.list_instance_profiles(marker: marker) : $iam_sdk.list_instance_profiles()
      my_iam_profiles.concat(iam_profiles.data.instance_profiles)
      is_truncated = iam_profiles.data.is_truncated
      marker = iam_profiles.data.marker
    end
    $account_values['us-east-1.IAM.iam_profiles'] = my_iam_profiles.length
  end
  if $iam_certs
    $account_limits['us-east-1.IAM.iam_certs'] = $iam_certs
    is_truncated = true
    marker = false
    my_iam_certs = Array.new
    while is_truncated do
      iam_certs = marker ? $iam_sdk.list_server_certificates(marker: marker) : $iam_sdk.list_server_certificates()
      my_iam_certs.concat(iam_certs.data.server_certificate_metadata_list)
      is_truncated = iam_certs.data.is_truncated
      marker = iam_certs.data.marker
    end
    $account_values['us-east-1.IAM.iam_certs'] = my_iam_certs.length
  end
  if $eb_apps
    $account_limits[$awsregion + '.ElasticBeanstalk.eb_apps'] = $eb_apps
    applications = $elasticbeanstalk.applications.all
    $account_values[$awsregion + '.ElasticBeanstalk.eb_apps'] = applications.length
  end
  if $eb_versions
    $account_limits[$awsregion + '.ElasticBeanstalk.eb_versions'] = $eb_versions
    versions = $elasticbeanstalk.versions.all
    $account_values[$awsregion + '.ElasticBeanstalk.eb_versions'] = versions.length
  end
  if $eb_envs
    $account_limits[$awsregion + '.ElasticBeanstalk.eb_envs'] = $eb_envs
    environments = $elasticbeanstalk.environments.all
    $account_values[$awsregion + '.ElasticBeanstalk.eb_envs'] = environments.length
  end
  if $eb_templates
    $account_limits[$awsregion + '.ElasticBeanstalk.eb_templates'] = $eb_templates
    templates = $elasticbeanstalk.templates.all
    $account_values[$awsregion + '.ElasticBeanstalk.eb_templates'] = templates.length
  end
  if $secgroups_per_vpc
    my_groups = $compute.describe_security_groups
    vpc_map = Hash.new(0) 
    my_groups[:body]['securityGroupInfo'].map {|group| vpc_map[group['vpcId']] += 1 }
    $account_limits[$awsregion + '.VPC.secgroups_per_vpc'] = $secgroups_per_vpc
    $account_values[$awsregion + '.VPC.secgroups_per_vpc'] = vpc_map.values.max
  end
  if $cloudformation_stacks
    cf_stacks = $cloudformation.describe_stacks
    $account_limits[$awsregion + '.CloudFormation.cloudformation_stacks'] = $cloudformation_stacks
    $account_values[$awsregion + '.CloudFormation.cloudformation_stacks'] = cf_stacks.data[:body]['Stacks'].length
  end
end

def fetch_limits_via_api()
  asg_limits = $autoscaling_sdk.describe_account_limits()
  $account_limits[$awsregion + '.AutoScaling.Auto_Scaling_groups'] = asg_limits.data.max_number_of_auto_scaling_groups
  $account_limits[$awsregion + '.AutoScaling.Launch_configurations'] = asg_limits.data.max_number_of_launch_configurations

  ec2_limit = $ec2_sdk.describe_account_attributes(attribute_names: ["max-instances"])
  eip_limit = $ec2_sdk.describe_account_attributes(attribute_names: ["vpc-max-elastic-ips"])
  $account_limits[$awsregion + '.EC2.instances'] = ec2_limit.account_attributes[0].attribute_values[0].attribute_value
  $account_limits[$awsregion + '.VPC.vpc_elastic_ips'] = eip_limit.account_attributes[0].attribute_values[0].attribute_value
  
  autoscalinggroup_list = $autoscaling.groups.all
  $account_values[$awsregion + '.AutoScaling.Auto_Scaling_groups'] = autoscalinggroup_list.length
  autoscaling_launch_configs = $autoscaling.configurations.all
  $account_values[$awsregion + '.AutoScaling.Launch_configurations'] = autoscaling_launch_configs.length

  vpc_eips = $compute.addresses.all
  $account_values[$awsregion + '.VPC.vpc_elastic_ips'] = vpc_eips.length
  $account_values[$awsregion + '.EC2.instances'] = $current_instances.length
end

fetch_trusted_advisor
fetch_hard_coded_limits
fetch_limits_via_api

$account_limits.each do |limit, value|
  metricpath = "AWSlimits." + limit + ".max"
  metricvalue = value
  metrictimestamp = $startTime
  Sendit metricpath, metricvalue, metrictimestamp
  $metricsSent += 1
end

$account_values.each do |limit, value|
  metricpath = "AWSlimits." + limit 
  metricvalue = value
  metrictimestamp = $startTime
  Sendit "#{metricpath}.value", metricvalue, metrictimestamp
  Sendit "#{metricpath}.used_percent", (metricvalue.to_i * 100 / $account_limits[limit].to_i), metrictimestamp
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
