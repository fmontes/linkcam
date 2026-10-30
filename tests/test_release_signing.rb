require 'yaml'
require 'open3'
require 'tmpdir'

workflow = YAML.load_file(File.join(__dir__, '../.github/workflows/release.yml'))
step = workflow.fetch('jobs').fetch('release').fetch('steps').find { |item| item['id'] == 'signing' }
blank_secrets = step.fetch('env').keys.to_h { |name| [name, ''] }

cases = [
  ['no credentials', {}, true],
  ['account credentials without certificate', {
    'APPLE_ID' => 'example@example.com',
    'APPLE_TEAM_ID' => 'EXAMPLE123',
    'APPLE_APP_SPECIFIC_PASSWORD' => 'dummy-password'
  }, true],
  ['certificate without companion credentials', {
    'SIGNING_CERTIFICATE_BASE64' => 'dummy-certificate'
  }, false]
]

Dir.mktmpdir('linkcam-signing-test-') do |directory|
  output = File.join(directory, 'output')
  cases.each do |name, secrets, succeeds|
    File.write(output, '')
    environment = blank_secrets.merge(secrets).merge('GITHUB_OUTPUT' => output)
    stdout, stderr, status = Open3.capture3(environment, 'bash', '-e', '-o', 'pipefail', '-c', step.fetch('run'))
    raise "#{name}: unexpected exit status: #{stdout}#{stderr}" unless status.success? == succeeds
    expected_output = succeeds ? "signed=false\n" : ''
    raise "#{name}: unexpected signing selection" unless File.read(output) == expected_output
  end
end

puts 'Release signing selection tests passed'
