require 'cinch'
require 'set'
require 'yaml'

$pm_users = Set.new

module Cinch
  class Message
    old_reply = instance_method(:reply)

    define_method(:reply) do |*args|
      if self.channel.nil? && !$pm_users.include?(self.user.nick)
        self.user.send(args[0], true)
      else
        old_reply.bind(self).(*args)
      end
    end
  end

  class User
    old_send = instance_method(:send)

    define_method(:send) do |*args|
      old_send.bind(self).(args[0], !$pm_users.include?(self.nick))
    end
  end
end

module Cinch; module Plugins; class GameBot
  include Cinch::Plugin

  def initialize(*args)
    super
    @changelog_file = config[:changelog_file] || ''
    @changelog     = self.load_changelog

    @mods          = config[:mods]
    @channel_names = config[:channels]
    @settings_file = config[:settings]
    @games_dir     = config[:games_dir]

    @idle_timer_length    = config[:allowed_idle]
    @invite_timer_length  = config[:invite_reset]

    @games = {}
    @idle_timers = {}
    @channel_names.each { |c|
      @games[c] = self.game_class.new(c)
      @idle_timers[c] = self.start_idle_timer(c)
    }

    @user_games = {}

    settings = load_settings || {}
    $pm_users = settings['pm_users'] || Set.new

    @last_invitation = Hash.new(0)
  end

  def self.xmatch(regex, args)
    match(regex, args.dup)
    args[:prefix] = lambda { |m| m.bot.nick + ': ' }
    match(regex, args.dup)
    args[:react_on] = :private
    args[:prefix] = /^/
    match(regex, args.dup)
  end

  def self.common_commands
    xmatch /join(?:\s*(##?\w+))?/i, :method => :join
    xmatch /leave/i,                :method => :leave
    xmatch /start(?:\s+(.+))?/i,    :method => :start_game

    # game
    xmatch /who(?:\s*(##?\w+))?/i,  :method => :list_players

    # other
    xmatch /invite/i,               :method => :invite
    xmatch /subscribe/i,            :method => :subscribe
    xmatch /unsubscribe/i,          :method => :unsubscribe
    xmatch /intro/i,                :method => :intro
    xmatch /changelog$/i,           :method => :changelog_dir
    xmatch /changelog (\d+)/i,      :method => :changelog

    # mod only commands
    xmatch /reset(?:\s+(##?\w+))?/i,        :method => :reset_game
    xmatch /replace (.+?) (.+)/i,           :method => :replace_user
    xmatch /kick\s+(.+)/i,                  :method => :kick_user
    xmatch /room(?:\s+(##?\w+))?\s+(.+)/i,  :method => :room_mode

    xmatch /notice(?:\s+(on|off|list))?(?:\s+(.+))?/i, :method => :noticeme

    listen_to :join,               :method => :voice_if_in_game
    listen_to :leaving,            :method => :remove_if_not_started
    listen_to :op,                 :method => :devoice_everyone_on_start
  end

  #--------------------------------------------------------------------------------
  # Listeners & Timers
  #--------------------------------------------------------------------------------

  def voice_if_in_game(m)
    game = @games[m.channel.name]
    m.channel.voice(m.user) if game && game.has_player?(m.user)
  end

  def remove_if_not_started(m, user)
    game = @user_games[user]
    self.remove_user_from_game(user, game) if game && !game.started?
  end

  def devoice_everyone_on_start(m, user)
    self.devoice_channel(m.channel) if user == bot
  end

  def start_idle_timer(channel_name)
    Timer(300) do
      game = @games[channel_name]
      game.users.each do |user|
        user.refresh
        if user.idle > @idle_timer_length
          self.remove_user_from_game(user, game) unless game.started?
          user.send("You have been removed from the #{channel_name} game due to inactivity.")
        end
      end
    end
  end

  #--------------------------------------------------------------------------------
  # Implementing classes should override these
  #--------------------------------------------------------------------------------

  def game_class
    # Implementing classes should override game_class
  end

  def do_start_game(m, game, options)
    Channel(game.channel_name).send('Implementing classes should override do_start_game')
    # Return false or nil if the game failed to start, otherwise return something truthy.
    false
  end

  def do_reset_game(game)
    Channel(game.channel_name).send('Implementing classes should override do_reset_game')
  end

  def do_replace_user(game, replaced_user, replacing_user)
    Channel(game.channel_name).send("Implementing classes should override do_replace_user")
  end

  def bg3po_invite_command(channel_name)
    # Implementing classes should override bg3po_invite_command
  end

  #--------------------------------------------------------------------------------
  # Main IRC Interface Methods
  #--------------------------------------------------------------------------------

  def join(m, channel_name = nil)
    channel = channel_name ? Channel(channel_name) : m.channel

    if (game2 = @user_games[m.user])
      # Be silent if the user's game is already started and user re-joins it
      # by sending !join in the same channel, or !join in a PM
      # This is so games can reuse the join command.
      # If it's not started, warn them like normal.
      ignore = game2.started? && (!channel || channel.name == game2.channel_name)
      m.reply("You are already in the #{game2.channel_name} game", true) unless ignore
      return
    end

    unless channel
      m.reply('To join a game via PM you must specify the channel: ' +
              '!join #channel')
      return
    end

    game = @games[channel.name]
    unless game
      m.reply(channel.name + ' is not a valid channel to join', true)
      return
    end

    unless channel.has_user?(m.user)
      m.reply("You need to be in #{channel.name} to join the game.", true)
      return
    end

    if game.started?
      m.reply('Game has already started.', true)
    elsif game.size >= game.class::MAX_PLAYERS
      m.reply('Game is at max players.', true)
    elsif game.add_player(m.user)
      channel.send("#{m.user.nick} has joined the game (#{game.size}/#{game.class::MAX_PLAYERS})")
      channel.voice(m.user)
      @user_games[m.user] = game
    else
      m.reply('Could not join for an unknown reason.', true)
    end
  end

  def leave(m)
    game = self.game_of(m)
    return unless game

    if game.started?
      m.reply('You cannot leave a game in progress.', true)
    else
      self.remove_user_from_game(m.user, game)
    end
  end

  def start_game(m, options = '')
    game = self.game_of(m)
    return unless game

    return if game.started?

    unless game.size >= game.class::MIN_PLAYERS
      m.reply("Need at least #{game.class::MIN_PLAYERS} to start a game.", true)
      return
    end

    unless game.has_player?(m.user)
      m.reply('You are not in the game.', true)
      return
    end

    successful = self.do_start_game(m, game, options)
    @idle_timers[game.channel_name].stop if successful
  end

  def start_new_game(game)
    Channel(game.channel_name).moderated = false
    game.users.each do |u|
      Channel(game.channel_name).devoice(u)
      @user_games.delete(u)
    end
    @games[game.channel_name] = self.game_class.new(game.channel_name)
    @idle_timers[game.channel_name].start
  end

  def list_players(m, channel_name = nil)
    game = self.game_of(m, channel_name, ['list players', '!who'])
    return unless game

    if game.users.empty?
      m.reply('No one has joined the game yet.')
    else
      m.reply(game.users.map { |u| dehighlight_nick(u.nick) }.join(' '))
    end
  end

  def devoice_channel(channel)
    channel.voiced.each { |user| channel.devoice(user) }
  end

  def remove_user_from_game(user, game, announce = true)
    if game.remove_player(user)
      Channel(game.channel_name).send("#{user.nick} has left the game (#{game.size}/#{game.class::MAX_PLAYERS})") if announce
      Channel(game.channel_name).devoice(user)
      @user_games.delete(user)
    end
  end

  def dehighlight_nick(nickname)
    nickname.chars.to_a.join(8203.chr('UTF-8'))
  end

  #--------------------------------------------------------------------------------
  # Mod commands
  #--------------------------------------------------------------------------------

  def is_mod?(user)
    # make sure that the nick is in the mod list and the user is authenticated
    user.authed? && @mods.include?(user.authname)
  end

  def reset_game(m, channel_name)
    return unless self.is_mod?(m.user)
    game = self.game_of(m, channel_name, ['reset a game', '!reset'])

    return unless game
    channel = Channel(game.channel_name)

    self.do_reset_game(game)

    game.users.each { |u| @user_games.delete(u) }

    @games[channel.name] = self.game_class.new(channel.name)
    self.devoice_channel(channel)
    channel.send('The game has been reset.')
    @idle_timers[channel.name].start
  end

  def kick_user(m, nick)
    return unless self.is_mod?(m.user)

    user = User(nick)
    game = @user_games[user]

    if !game
      m.user.send("#{nick} is not in a game")
    elsif game.started?
      m.user.send("You can't kick someone while a game is in progress.")
    else
      user = User(nick)
      self.remove_user_from_game(user, game)
    end
  end

  def replace_user(m, nick1, nick2)
    return unless self.is_mod?(m.user)
    # find irc users based on nick
    user1 = User(nick1)
    user2 = User(nick2)

    # Find game based on user 1
    game = @user_games[user1]

    # Can't do it if user2 is in a different game!
    if (game2 = @user_games[user2])
      m.user.send("#{nick2} is already in the #{game2.channel_name} game.")
      return
    end

    success = game.replace_player(user1, user2)
    return unless success

    # devoice/voice the players
    Channel(game.channel_name).devoice(user1)
    Channel(game.channel_name).voice(user2)

    @user_games.delete(user1)
    @user_games[user2] = game

    # inform channel
    Channel(game.channel_name).send("#{user1.nick} has been replaced with #{user2.nick}")

    self.do_replace_user(game, user1, user2)
  end

  def room_mode(m, channel_name, mode)
    channel = channel_name ? Channel(channel_name) : m.channel
    return unless self.is_mod?(m.user)
    case mode
    when 'silent'
      Channel(channel.name).moderated = true
    when 'vocal'
      Channel(channel.name).moderated = false
    end
  end

  #--------------------------------------------------------------------------------
  # Helpers
  #--------------------------------------------------------------------------------

  def game_of(m, channel_name = nil, warn_user = nil)
    # If in a channel, must be for that channel.
    return @games[m.channel.name] if m.channel

    # If in private and channel specified, show that channel.
    return game = @games[channel_name] if channel_name

    # If in private and channel not specified, show the game the player is in.
    game = @user_games[m.user]

    # and advise them if they aren't in any
    m.reply("To #{warn_user[0]} via PM you must specify the channel: #{warn_user[1]} #channel") if game.nil? && !warn_user.nil?

    game
  end

  def noticeme(m, toggle, nick)
    if toggle && toggle.downcase == 'list' && self.is_mod?(m.user)
      m.reply("PRIVMSG users: #{$pm_users.to_a}")
      return
    end

    # Mods can act on any nick. Others act only on self.
    target = nick && self.is_mod?(m.user) ? nick : m.user.nick

    if toggle && toggle.downcase == 'on'
      $pm_users.delete(target)
      settings = load_settings || {}
      settings['pm_users'] = $pm_users
      save_settings(settings)
    elsif toggle && toggle.downcase == 'off'
      $pm_users.add(target)
      settings = load_settings || {}
      settings['pm_users'] = $pm_users
      save_settings(settings)
    end

    m.reply("Private communications to #{target} will occur in #{$pm_users.include?(target) ? 'PRIVMSG' : 'NOTICE'}")
  end

  def intro(m)
    m.user.send("Welcome to #{m.bot.nick}. You can join a game if there's one getting started with the command \"!join\". For more commands, type \"!help\". If you don't know how to play, you can read a rules summary with \"!rules\".")
  end

  def changelog_dir(m)
    @changelog.first(5).each_with_index do |changelog, i|
      m.user.send("#{i+1} - #{changelog['date']} - #{changelog['changes'].length} changes")
    end
  end

  def changelog(m, page = 1)
    changelog_page = @changelog[page.to_i-1]
    unless changelog_page
      m.user.send("No changes on page #{page}!")
      return
    end
    m.user.send("Changes for #{changelog_page['date']}:")
    changelog_page['changes'].each { |change| m.user.send("- #{change}") }
  end

  def invite(m)
    game = self.game_of(m)
    return unless game

    return if game.started?

    last_invitation = @last_invitation[game.channel_name]
    if last_invitation + @invite_timer_length > Time.now.to_i
      m.reply('An invitation cannot be sent out again so soon.', true)
      return
    end

    @last_invitation[game.channel_name] = Time.now.to_i

    command = self.bg3po_invite_command(game.channel_name)
    User('BG3PO').send(command) if command && !command.empty?
    m.user.send('Invitation has been sent.')

    settings = load_settings || {}
    subscribers = settings['subscribers']
    current_players = game.users.map(&:nick)
    subscribers.each do |subscriber|
      unless current_players.include?(subscriber)
        u = User(subscriber)
        u.refresh
        u.send("A game of #{game.class::GAME_NAME} is gathering in #{game.channel_name}...") if u.online?
      end
    end
  end

  def subscribe(m)
    settings = load_settings || {}
    subscribers = settings['subscribers'] || []
    if subscribers.include?(m.user.nick)
      m.user.send('You are already subscribed to the invitation list.')
      return
    end

    if User(m.user).authed?
      subscribers << m.user.nick
      settings['subscribers'] = subscribers
      save_settings(settings)
      m.user.send("You've been subscribed to the invitation list.")
    else
      m.user.send('Whoops. You need to be identified on freenode to be able to subscribe. Either identify ("/msg Nickserv identify [password]") if you are registered, or register your account ("/msg Nickserv register [email] [password]")')
      m.user.send('See http://freenode.net/faq.shtml#registering for help')
    end
  end

  def unsubscribe(m)
    settings = load_settings || {}
    subscribers = settings['subscribers'] || []
    unless subscribers.include?(m.user.nick)
      m.user.send("You are not subscribed to the invitation list.")
    end

    if User(m.user).authed?
      subscribers.delete_if { |sub| sub == m.user.nick }
      settings['subscribers'] = subscribers
      save_settings(settings)
      m.user.send("You've been unsubscribed from the invitation list.")
    else
      m.user.send('Whoops. You need to be identified on freenode to be able to unsubscribe. Either identify ("/msg Nickserv identify [password]") if you are registered, or register your account ("/msg Nickserv register [email] [password]")')
      m.user.send('See http://freenode.net/faq.shtml#registering for help')
    end
  end

  #--------------------------------------------------------------------------------
  # Settings
  #--------------------------------------------------------------------------------

  def save_settings(settings)
    output = File.new(@settings_file, 'w')
    output.puts(YAML.dump(settings))
    output.close
  end

  def load_settings
    output = File.new(@settings_file, 'r')
    settings = YAML.load(output.read)
    output.close

    settings
  end

  def load_changelog
    return [] unless File.exist?(@changelog_file)
    output = File.new(@changelog_file, 'r')
    changelog = YAML.load(output.read)
    output.close

    changelog
  end
end; end; end
