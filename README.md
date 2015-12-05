# cinch-game-bot

cinch-game-bot is a generic skeleton for turn-based games written in [Cinch](https://github.com/cinchrb/cinch).

## Interface

Extend GameBot and override the methods listed in the section "Implementing classes should override these"

You will probably want to call `add_common_commands` in the extending class.

The Game class provided in `game_class` must have the following instance methods:

```
Game#initialize(String channel_name)
Game#channel_name               -> String (typically what was passed to initialize)
Game#started?                   -> Boolean
Game#size                       -> Fixnum (number of players currently in the game)
Game#users                      -> [Cinch::User]
Game#has_player?(Cinch::User)   -> Boolean
Game#add_player(Cinch::User)    -> Boolean (was add successful?)
Game#remove_player(Cinch::User) -> Boolean (was remove successful?)
Game#replace_player(Cinch::User(out), Cinch::User(in)) -> Boolean (successfuly replaced out with in?)
```

The Game class provided in `game_class` must have the following constants:

```
Game::GAME_NAME -> String
Game::MAX_PLAYERS -> Fixnum
Game::MIN_PLAYERS -> Fixnum
```

Overall, note that the above interface makes no assumptions as to what `Cinch::User` can do.
Because of this, a conforming Game class could substitute any other class for `Cinch::User`.
As an example, one might simply use `String` when testing.

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
