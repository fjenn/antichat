#!/usr/bin/env ruby
# Registers ios/AntiChat/* in PocketPal.xcodeproj and applies the debug-build
# identity (bundle id, display name, entitlements, automatic signing).
# Idempotent: run again after an upstream merge that rewrites project.pbxproj.
#   ruby tools/antichat/add-ios-files.rb [DEVELOPMENT_TEAM]
require 'xcodeproj'

root = File.expand_path('../..', __dir__)
team = ARGV[0] || ENV['ANTICHAT_TEAM_ID'] || abort('usage: add-ios-files.rb <your Apple team id>')
project = Xcodeproj::Project.open(File.join(root, 'ios/PocketPal.xcodeproj'))
target = project.targets.find { |t| t.name == 'PocketPal' } or abort 'PocketPal target not found'

group = project.main_group.find_subpath('AntiChat', true)
group.set_source_tree('<group>')
group.set_path('AntiChat')

Dir[File.join(root, 'ios/AntiChat/*')].sort.each do |path|
  name = File.basename(path)
  ref = group.files.find { |f| f.path == name } || group.new_file(name)
  next unless %w[.swift .m .mm].include?(File.extname(name))
  target.source_build_phase.add_file_reference(ref, true)
end

target.build_configurations.each do |config|
  s = config.build_settings
  if config.name == 'Debug'
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'ai.antichat.mobile.dev'
    s['ANTICHAT_DISPLAY_NAME'] = 'AntiChat Dev'
    s['CODE_SIGN_ENTITLEMENTS'] = 'AntiChat/AntiChatDev.entitlements'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['DEVELOPMENT_TEAM'] = team
    s.delete('DEVELOPMENT_TEAM[sdk=iphoneos*]')
    s.delete('PROVISIONING_PROFILE_SPECIFIER')
    s.delete('PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]')
  else
    s['ANTICHAT_DISPLAY_NAME'] ||= 'PocketPal'
  end
end

project.save
puts "ios/AntiChat registered; Debug = ai.antichat.mobile.dev (team #{team})"
