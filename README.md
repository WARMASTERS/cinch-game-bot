# cinch-game-bot

cinch-game-bot is a generic skeleton for turn-based games written in [Cinch](https://github.com/cinchrb/cinch).

## Interface

Extend GameBot and override the methods listed in the section "Implementing classes should override these"

You will probably want to call `common_commands` in the extending class.

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
