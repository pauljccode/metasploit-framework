require 'rubygems/package'
require 'zlib'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

class PlatformProbeError < StandardError; end

# Offline resolver experiment. --simulate-windows only tests Bundler's
# platform selection; running without it requires an actual Windows Ruby.
simulate = ARGV.delete('--simulate-windows')
raise ArgumentError, 'Use Windows Ruby or --simulate-windows' unless Gem.win_platform? || simulate

root = Dir.mktmpdir('bundler-platform-', __dir__)
repo = File.join(root, 'repo')
source_url = "file:///#{repo.tr('\\', '/').sub(%r{\A/}, '')}"
FileUtils.mkdir_p(File.join(repo, 'gems'))
specs = []
[['fixture_native', 'ruby'], ['fixture_native', 'x64-mingw-ucrt'], ['fixture_marker', 'ruby']].each do |name, platform|
  spec = Gem::Specification.new do |s|
    s.name = name
    s.version = '1.0.0'
    s.platform = platform
    s.summary = 'Private offline platform-selection fixture'
    s.authors = ['pauljccode']
    s.files = []
  end
  Dir.chdir(File.join(repo, 'gems')) { Gem::Package.build(spec) }
  specs << spec
end
quick = File.join(repo, 'quick', 'Marshal.4.8')
FileUtils.mkdir_p(quick)
specs.each do |spec|
  File.binwrite(File.join(quick, "#{spec.full_name}.gemspec.rz"), Zlib::Deflate.deflate(Marshal.dump(spec)))
end
%w[specs latest_specs prerelease_specs].each do |name|
  tuples = name == 'prerelease_specs' ? [] : specs.map { |s| [s.name, s.version, s.platform.to_s] }.sort
  Zlib::GzipWriter.open(File.join(repo, "#{name}.4.8.gz")) { |gz| gz.write(Marshal.dump(tuples)) }
end
override = File.join(root, 'windows-platform.rb')
File.write(override, <<~RUBY)
  require 'rubygems'
  module FixturePlatform
    def local(*)
      @fixture_platform ||= Gem::Platform.new('x64-mingw-ucrt')
    end
  end
  Gem::Platform.singleton_class.prepend(FixturePlatform)
  Gem.platforms = [Gem::Platform::RUBY, Gem::Platform.local]
RUBY
runner = File.join(root, 'bundle-runner.rb')
File.write(runner, "gem 'bundler', '2.5.22'\nload Gem.bin_path('bundler', 'bundle', '2.5.22')\n")
command = [Gem.ruby]
command.concat(['-r', override]) if simulate
command << runner
report = []
%w[baseline explicit-platform].each do |variant|
  dir = File.join(root, variant)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'Gemfile'), "source #{source_url.inspect}\ngem 'fixture_native'\ngem 'fixture_marker'\n")
  File.write(File.join(dir, 'Gemfile.lock'), <<~LOCK)
    GEM
      remote: #{source_url}/
      specs:
        fixture_marker (1.0.0)
        fixture_native (1.0.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      fixture_marker
      fixture_native

    BUNDLED WITH
       2.5.22
  LOCK
  env = ENV.keys.grep(/\ABUNDLE_/).to_h { |key| [key, nil] }
  env.merge!('BUNDLE_USER_HOME' => File.join(dir, 'user'), 'BUNDLE_PATH' => File.join(dir, 'vendor'), 'BUNDLE_DEPLOYMENT' => 'true')
  commands = [['install']]
  commands << ['lock', '--add-platform', 'x64-mingw-ucrt'] if variant == 'explicit-platform'
  commands << ['update', 'fixture_marker']
  commands.each_with_index do |args, index|
    env['BUNDLE_DEPLOYMENT'] = 'false' if index > 0
    out, status = Open3.capture2e(env, *command, *args, chdir: dir)
    File.write(File.join(dir, "step-#{index}.log"), out)
    raise PlatformProbeError, "#{variant} #{args.inspect} failed: #{out}" unless status.success?

    lock = File.read(File.join(dir, 'Gemfile.lock'))
    File.write(File.join(dir, "step-#{index}.lock"), lock)
    selected, selected_status = Open3.capture2e(env, *command, 'info', 'fixture_native', '--path', chdir: dir)
    raise PlatformProbeError, "Cannot inspect installed gem: #{selected}" unless selected_status.success?

    expected = variant == 'baseline' && args.first == 'update' ? 'fixture_native-1.0.0' : 'fixture_native-1.0.0-x64-mingw-ucrt'
    raise PlatformProbeError, "Expected #{expected}, selected #{selected}" unless File.basename(selected.strip) == expected

    report << { variant: variant, command: args, selected: File.basename(selected.strip), output: out, lock: lock }
  end
end
File.write(File.join(root, 'results.json'), JSON.pretty_generate(report))
puts JSON.pretty_generate(root: root, results: report)
