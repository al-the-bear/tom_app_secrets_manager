#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint tom_secrets_desktop.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'tom_secrets_desktop'
  s.version          = '0.0.1'
  s.summary          = 'The desktop host of the Tom Secrets Manager app: screen capture, clipboard, login item.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'https://enterprise-flutter.dev'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Peter Nicolai Alexis Kyaw' => 'anthropic@kyaw.de' }

  s.source           = { :path => '.' }
  s.source_files = 'tom_secrets_desktop/Sources/tom_secrets_desktop/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'tom_secrets_desktop_privacy' => ['tom_secrets_desktop/Sources/tom_secrets_desktop/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
