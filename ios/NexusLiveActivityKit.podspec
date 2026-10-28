#
# NexusLiveActivityKit — the Nexus Live Activity renderer for your Widget
# Extension. Flutter-free (extensions can't link Flutter). Add once, in the
# app's ios/Podfile:
#
#   target 'YourWidgetExtension' do
#     use_frameworks!
#     pod 'NexusLiveActivityKit', :path => '.symlinks/plugins/nexus_flutter/ios'
#   end
#
Pod::Spec.new do |s|
  s.name             = 'NexusLiveActivityKit'
  s.version          = '1.0.0'
  s.summary          = 'Renders Nexus Live Activity templates (Lock Screen + Dynamic Island) in a Widget Extension.'
  s.homepage         = 'https://inverge.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Inverge' => 'info@inverge.net' }
  s.source           = { :path => '.' }
  # The attributes file is shared with the nexus_flutter pod (one source, so the
  # app and the widget always agree on the ActivityKit type).
  s.source_files     = [
    'NexusLiveActivityKit/Sources/**/*.swift',
    'nexus_flutter/Sources/nexus_flutter/LiveActivity/NexusLiveActivityAttributes.swift',
  ]
  s.frameworks       = 'ActivityKit', 'WidgetKit', 'SwiftUI'
  s.platform         = :ios, '16.1'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'APPLICATION_EXTENSION_API_ONLY' => 'YES' }
end
