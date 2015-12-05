require 'cinch'
require 'set'
require 'yaml'

module Cinch
  class << self
    attr_reader :pm_users
  end
  @pm_users = Set.new

  class Message
    old_reply = instance_method(:reply)

    define_method(:reply) do |*args|
      if self.channel.nil? && !Cinch.pm_users.include?(self.user.nick)
        self.user.send(args[0], true)
      else
        old_reply.bind(self).(*args)
      end
    end
  end

  class User
    old_send = instance_method(:send)

    define_method(:send) do |*args|
      old_send.bind(self).(args[0], !Cinch.pm_users.include?(self.nick))
    end
  end
end

module Cinch; module Plugins; class GameBot
  include Cinch::Plugin

  def initialize(*args)
    super
    @changelog_file = config[:changelog_file] || ''
    @changelog     = self.load_changelog

    @mods          = config[:mods] || []
    @channel_names = config[:channels]
    @settings_file = config[:settings]

    @idle_timer_length    = config[:allowed_idle] || 900
    @invite_timer_length  = config[:invite_reset] || 900

    @waiting_rooms = {}
    @games = {}
    @idle_timers = {}
    @channel_names.each { |c|
      @waiting_rooms[c] = WaitingRoom.new(c, self.game_class::MAX_PLAYERS)
      @games[c] = self.game_class.new(c)
      @idle_timers[c] = self.start_idle_timer(c)
    }

    @user_games = {}

    settings = load_settings || {}
    if (pm_users = settings['pm_users'])
      Cinch.pm_users.merge(pm_users)
    end

    @last_invitation = Hash.new(0)
  end

  COMMON_COMMANDS = Set.new(%w(
    join
    leave
    start
    who
    status
    invite
    subscribe
    unsubscribe
    intro
    changelog
    reset
    replace
    kick
    room
    notice
  )).freeze

  def self.add_common_commands
    # A recommended plugin prefix could be:
    # c.plugins.prefix = lambda { |m| m.channel.nil? ? /^!?/ : /^#{m.bot.name}[:,]?\s+|^!/  }
    match(/join(?:\s*(##?\w+))?/i, method: :join)
    match(/leave/i,                method: :leave)
    match(/start(?:\s+(.+))?/i,    method: :start_game)

    # game
    match(/who(?:\s*(##?\w+)\s*)?$/i, method: :list_players)
    match(/status/i,                  method: :status)

    # other
    match(/invite/i,            method: :invite)
    match(/subscribe/i,         method: :subscribe)
    match(/unsubscribe/i,       method: :unsubscribe)
    match(/intro/i,             method: :intro)
    match(/changelog$/i,        method: :changelog_dir)
    match(/changelog\s+(\d+)/i, method: :changelog)

    # mod only commands
    match(/reset(?:\s+(##?\w+))?/i,       method: :reset_game)
    match(/replace\s+(.+?)\s+(.+)/i,      method: :replace_user)
    match(/kick\s+(.+)/i,                 method: :kick_user)
    match(/room(?:\s+(##?\w+))?\s+(.+)/i, method: :room_mode)

    match(/notice(?:\s+(on|off|list))?(?:\s+(.+))?/i, method: :noticeme)

    listen_to :join,    method: :voice_if_in_game
    listen_to :leaving, method: :remove_if_not_started
    listen_to :op,      method: :devoice_everyone_on_start
  end

  #--------------------------------------------------------------------------------
  # Listeners & Timers
  #--------------------------------------------------------------------------------

  def voice_if_in_game(m)
    channel_game = @games[m.channel.name]
    user_game = @user_games[m.user]
    m.channel.voice(m.user) if channel_game == user_game
  end

  def remove_if_not_started(m, user)
    game = @user_games[user]
    self.remove_user_from_waiting_room(user, game.channel_name) if game && !game.started?
  end

  def devoice_everyone_on_start(m, user)
    self.devoice_channel(m.channel) if user == bot
  end

  def start_idle_timer(channel_name)
    Timer(300) do
      @waiting_rooms[channel_name].users.each do |user|
        user.refresh
        if user.idle > @idle_timer_length
          self.remove_user_from_waiting_room(user, channel_name)
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

  def do_start_game(m, game, users, options)
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

  def game_status(game)
    'Implementing classes should override game_status'
  end

  #--------------------------------------------------------------------------------
  # Main IRC Interface Methods
  #--------------------------------------------------------------------------------

  class WaitingRoom
    attr_reader :channel_name, :users, :capacity

    def initialize(channel_name, capacity)
      # We'd like to use a Set, but User.nick can change.
      # Performance shouldn't be too terrible since waiting rooms should be small.
      @users = []
      @capacity = capacity
      @channel_name = channel_name
    end

    def size
      @users.size
    end

    def empty?
      @users.empty?
    end

    def include?(user)
      @users.include?(user)
    end

    def add(user)
      @users << user
    end

    def remove(user)
      @users.delete(user)
    end
    alias :delete :remove

    def clear
      @users.clear
    end
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
    waiting_room = @waiting_rooms[channel.name]
    unless game && waiting_room
      m.reply(channel.name + ' is not a valid channel to join', true)
      return
    end

    unless channel.has_user?(m.user)
      m.reply("You need to be in #{channel.name} to join the game.", true)
      return
    end

    if game.started?
      m.reply('Game has already started.', true)
      return
    end

    if waiting_room.size >= waiting_room.capacity
      m.reply("Game is already at #{waiting_room.capacity} players, the maximum supported for #{game.class::GAME_NAME}.", true)
      return
    end

    waiting_room.add(m.user)
    channel.send("#{m.user.nick} has joined the game (#{waiting_room.size}/#{waiting_room.capacity})")
    channel.voice(m.user)
    @user_games[m.user] = game
  end

  def leave(m)
    game = self.game_of(m)
    return unless game

    if game.started?
      m.reply('You cannot leave a game in progress.', true)
    else
      self.remove_user_from_waiting_room(m.user, game.channel_name)
    end
  end

  def start_game(m, options = '')
    game = self.game_of(m)
    return unless game

    return if game.started?

    waiting_room = @waiting_rooms[game.channel_name]
    unless waiting_room && waiting_room.size >= game.class::MIN_PLAYERS
      m.reply("Need at least #{game.class::MIN_PLAYERS} to start a game of #{game.class::GAME_NAME}.", true)
      return
    end

    unless waiting_room.include?(m.user)
      m.reply('You are not in the game.', true)
      return
    end

    if self.do_start_game(m, game, waiting_room.users, options)
      @idle_timers[game.channel_name].stop
      waiting_room.clear
    end
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

    if game.started?
      m.reply(game.users.map { |u| dehighlight_nick(u.nick) }.join(' '))
    else
      waiting_room = @waiting_rooms[game.channel_name]
      if waiting_room.empty?
        m.reply('No one has joined the game yet.')
      else
        m.reply(waiting_room.users.map { |u| dehighlight_nick(u.nick) }.join(' '))
      end
    end
  end

  def status(m)
    game = self.game_of(m)
    return unless game

    if game.started?
      m.reply(self.game_status(game))
      return
    end

    waiting_room = @waiting_rooms[game.channel_name]
    if waiting_room.empty?
      m.reply("No game of #{game.class::GAME_NAME} in progress. Join and start one!")
    else
      m.reply("A game of #{game.class::GAME_NAME} is forming. #{waiting_room.size} players have joined: #{waiting_room.users.map(&:name).join(', ')}")
    end
  end

  def devoice_channel(channel)
    channel.voiced.each { |user| channel.devoice(user) }
  end

  def remove_user_from_waiting_room(user, channel_name, announce: true)
    waiting_room = @waiting_rooms[channel_name]
    return unless waiting_room && waiting_room.include?(user)

    waiting_room.remove(user)
    channel = Channel(channel_name)
    channel.send("#{user.nick} has left the game (#{waiting_room.size}/#{waiting_room.capacity})") if announce
    channel.devoice(user)
    @user_games.delete(user)
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

    return unless game && game.started?
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
      self.remove_user_from_waiting_room(user, game.channel_name)
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

    if game.started?
      success = game.replace_player(user1, user2)
    else
      waiting_room = @waiting_rooms[game.channel_name]
      waiting_room.remove(user1)
      waiting_room.add(user2)
      success = true
    end
    return unless success

    # devoice/voice the players
    Channel(game.channel_name).devoice(user1)
    Channel(game.channel_name).voice(user2)

    @user_games.delete(user1)
    @user_games[user2] = game

    # inform channel
    Channel(game.channel_name).send("#{user1.nick} has been replaced with #{user2.nick}")

    self.do_replace_user(game, user1, user2) if game.started?
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
      m.reply("PRIVMSG users: #{Cinch.pm_users.to_a}")
      return
    end

    # Mods can act on any nick. Others act only on self.
    target = nick && self.is_mod?(m.user) ? nick : m.user.nick

    if toggle && toggle.downcase == 'on'
      Cinch.pm_users.delete(target)
      settings = load_settings || {}
      settings['pm_users'] = Cinch.pm_users
      save_settings(settings)
    elsif toggle && toggle.downcase == 'off'
      Cinch.pm_users.add(target)
      settings = load_settings || {}
      settings['pm_users'] = Cinch.pm_users
      save_settings(settings)
    end

    m.reply("Private communications to #{target} will occur in #{Cinch.pm_users.include?(target) ? 'PRIVMSG' : 'NOTICE'}")
  end

  def intro(m)
    m.reply("Welcome to #{m.bot.nick}. You can join a game if there's one getting started with the command \"!join\". For more commands, type \"!help\". If you don't know how to play, you can read a rules summary with \"!rules\".")
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

    if m.user.authed?
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

    if m.user.authed?
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
    return {} unless File.exist?(@settings_file)
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
