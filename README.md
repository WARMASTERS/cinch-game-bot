# cinch-game-bot

cinch-game-bot is a generic skeleton for turn-based games written in [Cinch](https://github.com/cinchrb/cinch).

[![Build Status](https://travis-ci.org/petertseng/cinch-game_bot.svg?branch=master)](https://travis-ci.org/petertseng/cinch-game_bot)

## Setup

You'll need a recent version of [Ruby](https://www.ruby-lang.org/).
Ruby 2.0 or newer is required because of keyword arguments.
The [build status](https://travis-ci.org/petertseng/cinch-game_bot) will confirm compatibility with various Ruby versions.
Note that [2.0 is no longer supported](https://www.ruby-lang.org/en/news/2016/02/24/support-plan-of-ruby-2-0-0-and-2-1/) by the Ruby team, so it would be better to use a later version.

You'll need [cinch](https://github.com/cinchrb/cinch), which can be acquired via `gem install cinch`.

## Usage

Given that you have performed the requisite setup and have written or acquired a game plugin that meets the interface described below, the minimal code to get a working bot might resemble:

```ruby
require 'cinch'
require 'cinch/plugins/my_game'

bot = Cinch::Bot.new do
  configure do |c|
    c.server = 'irc.example.com'
    c.channels = ['#playmygame']
    c.plugins.plugins = [Cinch::Plugins::MyGame]
    c.plugins.optins[Cinch::Plugins::MyGame] = {
      channels: ['#playmygame'],
      settings: 'my-settings.yaml',
    }
  end
end

bot.start
```

## Interface

Extend GameBot and override the methods listed in the section "Implementing classes should override these"

You will probably want to call `add_common_commands` in the extending class.

The return value of `do_start_game`, if it is truthy, must have the following methods:

```
Game#channel_name               -> String (typically what was passed to do_start_game)
Game#users                      -> [Cinch::User]
Game#replace_player(Cinch::User(out), Cinch::User(in)) -> Boolean (successfuly replaced out with in?)
```

Overall, note that the above interface makes no assumptions as to what `Cinch::User` can do.
Because of this, a conforming Game class could substitute any other class for `Cinch::User`.
As an example, one might simply use `String` when testing.

When a game has ended, call `start_new_game(game_that_just_ended)`
to release all players from that game and allow them to join a new game.

See `spec/example_plugin.rb` for an example conforming plugin and associated game.

## Configuration

Configuration is passed to a plugin via `cinch`'s `config` method.
This means in the bot file, `plugins.options[Cinch::Plugins::BotClass]` should be a hash.
The keys of the hash should be the symbols listed below.

The following configuration options are required:

* `:channels`: An array of strings, where each string is a channel name.
    A game may run in each channel simultaneously.
* `:settings`: Path to a settings YAML file to which settings will be saved.
    If this file is not present, one will be created whenever settings are saved.

The following configuration options are optional:

* `:mods`: An array of strings, where each string is an authname of a moderator.
    Moderators may use restricted commands (reset, replace, kick, mode +m).
    If option is omitted, nobody is a moderator.
* `:allowed_idle`: Number of seconds a player may be idle before automatically being removed from an unstarted game.
    If option is omitted, defaults to 900.
* `:invite_reset`: Number of seconds that must pass after an invite before another invite can be sent.
    If option is omitted, defaults to 900.
* `:changelog_file`: Path to a changelog YAML file. If present, file contents must be an array of hashes,
    where each entry has keys "date" and "changes" (an array of strings).
    If option is omitted, changelog will be treated as empty.
