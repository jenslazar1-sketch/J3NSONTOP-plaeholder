#!/usr/bin/env ruby
# frozen_string_literal: true

# Switches the Runner target of ios/Runner.xcodeproj to manual code signing
# for the Release and Profile configurations. Only the Runner target is
# touched: RunnerTests and the Swift package targets stay unsigned/automatic.
#
#   ruby scripts/ci/ios_configure_signing.rb \
#     --project ios/Runner.xcodeproj --team-id ABCDE12345 \
#     --profile-specifier "J3 Ad Hoc" --identity "Apple Distribution" \
#     --bundle-id com.j3nsontop.multitool
#
# Requires the xcodeproj gem (installed with CocoaPods on GitHub macOS runners;
# otherwise: gem install xcodeproj).

require 'optparse'

options = {
  project: 'ios/Runner.xcodeproj',
  target: 'Runner',
  configurations: %w[Release Profile]
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: ios_configure_signing.rb --team-id ID --profile-specifier NAME --identity NAME [options]'
  opts.on('--project PATH', 'Path to the .xcodeproj (default: ios/Runner.xcodeproj)') { |v| options[:project] = v }
  opts.on('--team-id ID', 'Apple Developer Team ID (10 characters)') { |v| options[:team_id] = v }
  opts.on('--profile-specifier NAME', 'Provisioning profile name (or UUID)') { |v| options[:profile] = v }
  opts.on('--identity NAME', '"Apple Distribution" or "Apple Development"') { |v| options[:identity] = v }
  opts.on('--bundle-id ID', 'Expected PRODUCT_BUNDLE_IDENTIFIER (verified, not changed)') { |v| options[:bundle_id] = v }
  opts.on('--configurations LIST', 'Comma-separated (default: Release,Profile)') do |v|
    options[:configurations] = v.split(',').map(&:strip).reject(&:empty?)
  end
end
parser.parse!(ARGV)

required = { team_id: '--team-id', profile: '--profile-specifier', identity: '--identity' }
missing = required.reject { |key, _flag| options[key] && !options[key].strip.empty? }.values
abort("ERROR: missing required option(s): #{missing.join(', ')}\n#{parser}") unless missing.empty?
abort("ERROR: invalid team id '#{options[:team_id]}'") unless options[:team_id].match?(/\A[A-Z0-9]{10}\z/)

begin
  require 'xcodeproj'
rescue LoadError
  abort('ERROR: the xcodeproj gem is not installed (gem install xcodeproj).')
end

project = Xcodeproj::Project.open(options[:project])
target = project.native_targets.find { |t| t.name == options[:target] }
abort("ERROR: target '#{options[:target]}' not found in #{options[:project]}") unless target

configured = []
target.build_configurations.each do |config|
  next unless options[:configurations].include?(config.name)

  settings = config.build_settings
  if options[:bundle_id] && settings['PRODUCT_BUNDLE_IDENTIFIER'] != options[:bundle_id]
    abort("ERROR: #{config.name} PRODUCT_BUNDLE_IDENTIFIER is '#{settings['PRODUCT_BUNDLE_IDENTIFIER']}', " \
          "expected '#{options[:bundle_id]}'")
  end
  settings['CODE_SIGN_STYLE'] = 'Manual'
  settings['DEVELOPMENT_TEAM'] = options[:team_id]
  settings['PROVISIONING_PROFILE_SPECIFIER'] = options[:profile]
  settings['CODE_SIGN_IDENTITY'] = options[:identity]
  # The project level sets CODE_SIGN_IDENTITY[sdk=iphoneos*]; override it here too.
  settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = options[:identity]
  settings.delete('PROVISIONING_PROFILE')
  configured << config.name
end

missing_configs = options[:configurations] - configured
abort("ERROR: configuration(s) not found on #{target.name}: #{missing_configs.join(', ')}") unless missing_configs.empty?

attributes = project.root_object.attributes
target_attributes = (attributes['TargetAttributes'] ||= {})
entry = (target_attributes[target.uuid] ||= {})
entry['ProvisioningStyle'] = 'Manual'
entry['DevelopmentTeam'] = options[:team_id]

project.save

puts "Configured manual signing for target '#{target.name}' (#{configured.join(', ')}):"
puts "  DEVELOPMENT_TEAM=#{options[:team_id]}"
puts "  PROVISIONING_PROFILE_SPECIFIER=#{options[:profile]}"
puts "  CODE_SIGN_IDENTITY=#{options[:identity]}"
