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

    # waiting_rooms always contains valid waiting rooms
    @waiting_rooms = {}
    # games only contains running games
    @games = {}
    @idle_timers = {}
    @channel_names.each { |c|
      @waiting_rooms[c] = WaitingRoom.new(c, self.max_players)
      @idle_timers[c] = self.start_idle_timer(c)
    }

    @user_games = {}
    @user_waiting_rooms = {}

    settings = load_settings || {}
    if (pm_users = settings['pm_users'])
      Cinch.pm_users.merge(pm_users)
    end
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
    return unless channel_game
    user_game = @user_games[m.user]
    m.channel.voice(m.user) if channel_game == user_game
  end

  def remove_if_not_started(m, user)
    waiting_room = @user_waiting_rooms[user]
    self.remove_user_from_waiting_room(user, waiting_room) if waiting_room
  end

  def devoice_everyone_on_start(m, user)
    self.devoice_channel(m.channel) if user == bot
  end

  def start_idle_timer(channel_name)
    Timer(300) do
      waiting_room = @waiting_rooms[channel_name]
      waiting_room.users.each { |user|
        user.refresh
        if user.idle > @idle_timer_length
          self.remove_user_from_waiting_room(user, waiting_room)
          user.send("You have been removed from the #{channel_name} game due to inactivity.")
        end
      }
    end
  end

  #--------------------------------------------------------------------------------
  # Implementing classes should override these
  #--------------------------------------------------------------------------------

  def min_players
    # Implementing classes should override
    0
  end

  def max_players
    # Implementing classes should override
    0
  end

  def game_name
    # Implementing classes should override
    'Game'.freeze
  end

  def do_start_game(m, channel_name, users, settings, start_args)
    Channel(channel_name).send('Implementing classes should override do_start_game')
    # Return false or nil if the game failed to start, otherwise return the game.
    nil
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
  # Waiting room - players waiting to join games not yet formed
  #--------------------------------------------------------------------------------

  class WaitingRoom
    # Games can associate arbitrary data with players in the waiting room.
    Player = Struct.new(:user, :data)
    class DataProxy
      def initialize(room)
        @room = room
      end

      def [](user)
        @room.players.find { |u| u.user == user }.data
      end
    end

    attr_reader :channel_name, :players, :capacity, :settings
    attr_accessor :last_invitation

    def initialize(channel_name, capacity)
      # We'd like to use a Hash keyed by User, but User.nick (used by equality) can change.
      # Performance shouldn't be too terrible since waiting rooms should be small.
      @players = []
      @capacity = capacity
      @channel_name = channel_name
      @settings = {}
      @last_invitation = 0
    end

    def users
      @players.map(&:user)
    end

    def size
      @players.size
    end

    def empty?
      @players.empty?
    end

    def include?(user)
      @players.any? { |u| u.user == user }
    end

    def add(user)
      @players << Player.new(user, {})
    end

    def remove(user)
      @players.reject! { |u| u.user == user }
    end
    alias :delete :remove

    def clear
      @players.clear
    end

    # All I want is to be able to say room.data[user][:stuff] = something
    def data
      DataProxy.new(self)
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
      different_channel = channel && channel.name != game2.channel_name
      m.reply("You are already in the #{game2.channel_name} game", true) if different_channel
      return
    end

    if (waiting_room = @user_waiting_rooms[m.user])
      m.reply("You are already in the #{waiting_room.channel_name} game", true)
      return
    end

    unless channel
      m.reply('To join a game via PM you must specify the channel: ' +
              '!join #channel')
      return
    end

    waiting_room = @waiting_rooms[channel.name]
    unless waiting_room
      m.reply(channel.name + ' is not a valid channel to join', true)
      return
    end

    unless channel.has_user?(m.user)
      m.reply("You need to be in #{channel.name} to join the game.", true)
      return
    end

    if @games[channel.name]
      m.reply('Game has already started.', true)
      return
    end

    if waiting_room.size >= waiting_room.capacity
      m.reply("Game is already at #{waiting_room.capacity} players, the maximum supported for #{self.game_name}.", true)
      return
    end

    waiting_room.add(m.user)
    channel.send("#{m.user.nick} has joined the game (#{waiting_room.size}/#{waiting_room.capacity})")
    channel.voice(m.user)
    @user_waiting_rooms[m.user] = waiting_room
  end

  def leave(m)
    if self.game_of(m)
      m.reply('You cannot leave a game in progress.', true)
      return
    end

    waiting_room = self.waiting_room_of(m)
    return unless waiting_room
    self.remove_user_from_waiting_room(m.user, waiting_room)
  end

  def start_game(m, options = '')
    return if self.game_of(m)

    waiting_room = self.waiting_room_of(m)
    return unless waiting_room

    unless waiting_room.size >= self.min_players
      m.reply("Need at least #{self.min_players} to start a game of #{self.game_name}.", true)
      return
    end

    unless waiting_room.include?(m.user)
      m.reply('You are not in the game.', true)
      return
    end

    if (game = self.do_start_game(m, waiting_room.channel_name, waiting_room.players, waiting_room.settings, options || ''))
      @idle_timers[waiting_room.channel_name].stop
      @games[waiting_room.channel_name] = game
      waiting_room.users.each { |u|
        @user_waiting_rooms.delete(u)
        @user_games[u] = game
      }
      waiting_room.clear
    end
  end

  def start_new_game(game)
    Channel(game.channel_name).moderated = false
    game.users.each do |u|
      Channel(game.channel_name).devoice(u)
      @user_games.delete(u)
    end
    @games.delete(game.channel_name)
    @idle_timers[game.channel_name].start
  end

  def list_players(m, channel_name = nil)
    if (game = self.game_of(m))
      m.reply(game.users.map { |u| dehighlight_nick(u.nick) }.join(' '))
      return
    end

    waiting_room = self.waiting_room_of(m, channel_name, ['list players', '!who'])
    if waiting_room.empty?
      m.reply('No one has joined the game yet.')
    else
      m.reply(waiting_room.users.map { |u| dehighlight_nick(u.nick) }.join(' '))
    end
  end

  def status(m)
    if (game = self.game_of(m))
      m.reply(self.game_status(game))
      return
    end

    waiting_room = self.waiting_room_of(m)
    return unless waiting_room

    if waiting_room.empty?
      m.reply("No game of #{self.game_name} in progress. Join and start one!")
    else
      m.reply("A game of #{self.game_name} is forming. #{waiting_room.size} players have joined: #{waiting_room.users.map(&:name).join(', ')}")
    end
  end

  def devoice_channel(channel)
    channel.voiced.each { |user| channel.devoice(user) }
  end

  def remove_user_from_waiting_room(user, waiting_room)
    return unless waiting_room.include?(user)

    waiting_room.remove(user)
    channel = Channel(waiting_room.channel_name)
    channel.send("#{user.nick} has left the game (#{waiting_room.size}/#{waiting_room.capacity})")
    channel.devoice(user)
    @user_waiting_rooms.delete(user)
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

    @games.delete(channel.name)
    self.devoice_channel(channel)
    channel.send('The game has been reset.')
    @idle_timers[channel.name].start
  end

  def kick_user(m, nick)
    return unless self.is_mod?(m.user)

    user = User(nick)

    if @user_games[user]
      m.user.send("You can't kick someone while a game is in progress.")
      return
    end

    if (waiting_room = @user_waiting_rooms[user])
      self.remove_user_from_waiting_room(user, waiting_room)
    else
      m.user.send("#{nick} is not in a game")
    end
  end

  def replace_user(m, nick1, nick2)
    return unless self.is_mod?(m.user)
    # find irc users based on nick
    user1 = User(nick1)
    user2 = User(nick2)

    # Can't do it if user2 is in a different game!
    if (game2 = @user_games[user2] || @user_waiting_rooms[user2])
      m.user.send("#{nick2} is already in the #{game2.channel_name} game.")
      return
    end

    # Find game based on user 1
    if (game = @user_games[user1])
      success = game.replace_player(user1, user2)
      return unless success

      channel = Channel(game.channel_name)
      @user_games.delete(user1)
      @user_games[user2] = game
    elsif (waiting_room = @user_waiting_rooms[user1])
      waiting_room.remove(user1)
      waiting_room.add(user2)

      channel = Channel(waiting_room.channel_name)
      @user_waiting_rooms.delete(user1)
      @user_waiting_rooms[user2] = waiting_room
    else
      return
    end

    # devoice/voice the players
    channel.devoice(user1)
    channel.voice(user2)

    # inform channel
    channel.send("#{user1.nick} has been replaced with #{user2.nick}")

    self.do_replace_user(game, user1, user2) if game
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
    return @games[channel_name] if channel_name

    # If in private and channel not specified, show the game the player is in.
    @user_games[m.user].tap { |game|
      # and advise them if they aren't in any
      m.reply("To #{warn_user[0]} via PM you must specify the channel: #{warn_user[1]} #channel") if game.nil? && !warn_user.nil?
    }
  end

  def waiting_room_of(m, channel_name = nil, warn_user = nil)
    # If in a channel, must be for that channel.
    return @waiting_rooms[m.channel.name] if m.channel

    # If in private and channel specified, show that channel.
    return @waiting_rooms[channel_name] if channel_name

    # If in private and channel not specified, the waiting room the player is in.
    @user_waiting_rooms[m.user].tap { |room|
      # and advise them if they aren't in any
      m.reply("To #{warn_user[0]} via PM you must specify the channel: #{warn_user[1]} #channel") if room.nil? && !warn_user.nil?
    }
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
    return if self.game_of(m)
    waiting_room = self.waiting_room_of(m)
    return unless waiting_room

    if waiting_room.last_invitation + @invite_timer_length > Time.now.to_i
      m.reply('An invitation cannot be sent out again so soon.', true)
      return
    end

    waiting_room.last_invitation = Time.now.to_i

    m.user.send('Invitation has been sent.')

    settings = load_settings || {}
    subscribers = settings['subscribers']
    current_players = waiting_room.users.map(&:nick)
    subscribers.each do |subscriber|
      next if current_players.include?(subscriber)
      u = User(subscriber)
      u.refresh
      u.send("A game of #{self.game_name} is gathering in #{waiting_room.channel_name}.") if u.online?
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
