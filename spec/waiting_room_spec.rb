require 'spec_helper'

require 'cinch/plugins/game_bot'

RSpec.describe Cinch::Plugins::GameBot::WaitingRoom do
  subject { described_class.new('hi', 3) }

  it 'associates data with users' do
    subject.add('testuser')
    subject.data['testuser'][:testkey] = :testvalue
    expect(subject.data['testuser'][:testkey]).to be == :testvalue
  end
end
