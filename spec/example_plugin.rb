require 'cinch'

module Cinch; module Plugins; class ExamplePlugin < GameBot
  include Cinch::Plugin

  class ExampleGame
    attr_reader :channel_name, :users

    def initialize(channel_name, users, can_replace: true)
      @channel_name = channel_name
      @users = users.sort_by(&:nick)
      @can_replace = can_replace
    end

    def replace_player(u1, u2)
      return false unless @can_replace
      @users.delete(u1)
      @users << u2
      true
    end
  end

  add_common_commands

  def min_players; 2 end
  def max_players; 3 end
  def game_name; 'Example Game'.freeze end

  def do_start_game(m, channel_name, players, settings, start_args)
    return nil if start_args.include?('fail')
    ExampleGame.new(channel_name, players.map(&:user), can_replace: !start_args.include?('noreplace'))
  end

  def do_reset_game(game)
    Channel(game.channel_name).send('plugin-specific reset message')
  end

  def do_replace_user(game, replaced_user, replacing_user)
    Channel(game.channel_name).send("plugin-specific replace message: #{replaced_user.nick} -> #{replacing_user.nick}")
  end

  def game_status(game)
    "Game started with players #{game.users.map(&:nick).join(', ')}"
  end
end; end; end
