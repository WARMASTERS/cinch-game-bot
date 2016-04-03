require 'simplecov'
SimpleCov.start { add_filter '/spec/' }

RSpec.configure { |c|
  c.warnings = true
  c.disable_monkey_patching!
}
