Gem::Specification.new do |s|
  s.name          = 'cinch-game_bot'
  s.version       = '1.0.0'
  s.summary       = 'Cinch Game Bot'
  s.description   = 'Generic skeleton for turn-based games on the Cinch framework'
  s.authors       = ['Peter Tseng']
  s.email         = 'pht24@cornell.edu'
  s.homepage      = 'https://github.com/petertseng/cinch-game_bot'

  s.files         = Dir['LICENSE', 'README.md', 'lib/**/*']
  s.test_files    = Dir['spec/**/*']
  s.require_paths = ['lib']

  s.add_runtime_dependency 'cinch'
  s.add_development_dependency 'cinch-test'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'simplecov'
end
