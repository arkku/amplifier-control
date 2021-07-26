#!/usr/bin/env ruby
# rotel-server.rb: A server to query and control a Rotel RA-1570 amplifier.
# The instance of `RotelAmplifier` watches the serial port connection and
# maintains a local copy of the amplifier's state (power, volume, input, etc.).
# Meanwhile the server listens for TCP connections and accepts commands
# (such as "power on" or "vol 50") and queries (such as "? power") from them.
#
# There are no credentials needed for the TCP interface, so by default the
# server only listens on `127.0.0.1`. The maximum volume is also limited, so
# it should not be possible to blow up the speakers or damage hearing through
# this. (Some wear could certainly be caused by toggling the power repeatedly,
# although things are rate-limited by the reaction times of the amplifier.)
#
# Personally I run this on a Raspberry Pi, together with clients for Homekit
# and shairport-sync to access the server. While the TCP service may seem like
# overkill for this use, it is in fact necessary because it seems that the
# amplifier is very picky about input and freezes easily if queried repeatedly
# in standby mode.
#
# By Kimmo Kulovesi <https://arkku.dev/>, 2020-02-09

require 'rubygems'
require 'serialport'
require 'socket'

#require 'em/pure_ruby'
require 'eventmachine'

module EventMachine
  if defined?(EventMachine.library_type) && EventMachine.library_type == :pure_ruby
    # A serial port stream object for use with EventMachine.
    class StreamSerial < StreamObject
      attr_reader :serial_port

      # Open serial port `device` at the given settings.
      def self.open(device, baud:, bits: 8, stop_bits: 1, parity: SerialPort::NONE, flow_control: SerialPort::NONE)
        serial = SerialPort.new(device, baud, bits, stop_bits, parity)
        serial.flow_control = flow_control
        self.new serial
      end

      def initialize(io)
        @serial_port = io
        super
      end
    end

    # Create a new `Connection` subclass instance (class or module passed
    # as `handler`) to handle `stream_serial`, a `StreamSerial` instance.
    # An optional block may be given, to which the resulting instance is
    # yielded.
    def connection_for_serial_stream(stream_serial, handler: nil)
      handler_class = if (handler && handler.is_a?(Class))
        handler
      else
        Class.new(Connection) { include handler if handler }
      end
      uuid = stream_serial.uuid
      connection = handler_class.new(uuid)
      @conns[uuid] = connection
      yield connection if block_given?
      connection
    end
  end

  class << self
  public
    # Open serial port `device` at the given settings, and create a new
    # `Connection` subclass instance (class or module passed as `handler`)
    # to handle it. An optional block may be given, to which the resulting
    # instance is yielded.
    def open_serial(device, baud:, bits: 8, stop_bits: 1, parity: SerialPort::NONE, flow_control: SerialPort::NONE, handler: nil)
      if defined?(EventMachine.library_type) && EventMachine.library_type == :pure_ruby
        serial_stream = StreamSerial.open(device, baud: baud, bits: bits, stop_bits: stop_bits, parity: parity, flow_control: flow_control)
        connection_for_serial_stream(serial_stream, handler: handler)
      else
        serial = SerialPort.new(device, baud, bits, stop_bits, parity)
        serial.flow_control = flow_control
        attach(serial, handler)
      end
    end
  end
end

# The raw serial data connection for Rotel amplifiers. This parses the
# serial data stream and separates events from display updates.
# Use `subscribe` and `subscribe_display` to subscribe to the events.
class RotelConnection < EventMachine::Connection
  attr_reader :partial_data
  attr_reader :messages_received
  attr_reader :messages_sent
  attr_reader :bytes_received
  attr_reader :bytes_sent
  attr_reader :display1
  attr_reader :display2
  attr_accessor :log_output

  def post_init
    @partial_data = ''
    @log_output = @@log_output
    @messages_received = 0
    @messages_sent = 0
    @bytes_received = 0
    @bytes_sent = 0
    @receive_channel = EventMachine::Channel.new
    @display_channel = EventMachine::Channel.new
    @display1 = ''
    @display2 = ''
  end

  @@log_output = nil

  # The default log output of all `RotelConnection` instances.
  def self.log_output
    @@log_output
  end

  # Enable logging of all data in/out by setting this to an IO object,
  # e.g., `$stderr`.
  def self.log_output=(io)
    @@log_output = io
  end

  def send(msg)
    msg = msg.to_s
    return if msg.empty?
    log "<< #{msg}"
    @messages_sent += 1
    @bytes_sent += msg.size
    send_data msg
  end

  # Strip and parse display events from `original_message`, return
  # the stripped message.
  def display_stripped(original_message)
    message = "#{original_message}"
    display = message.slice!(/^[\r\n]*(display|product_[a-z]+|[a-z]+_version)([12]?)=/)
    return original_message if display.to_s.empty?

    message.slice!(/^0*/)
    display_length = message.to_i
    return original_message if display_length == 0

    message.slice!(/^[0-9]*,/)
    is_display = display.slice!(/^[\r\n]*display/)
    line = display.to_i
    display = message.slice! (0...display_length)
    return original_message if display.size < display_length

    if is_display
      case line
      when 0
        @display1 = display[0...(display_length / 2)]
        @display2 = display[(display_length / 2)..-1]
      when 1
        @display1 = display
      when 2
        @display2 = display
      end
      @display_channel.push [ @display1, @display2 ]
    else
      log "# Non-display text: #{original_message.inspect}"
    end

    message
  end

  def receive_data(data)
    @partial_data << data
    data = @partial_data
    @partial_data = ''
    while (message = data.slice!(/^[^!]*!/))
      log ">> #{message.inspect}"
      @bytes_received += message.size
      @messages_received += 1
      message = display_stripped(message)
      @receive_channel.push message unless message.empty?
    end
    @partial_data = display_stripped(data)
  end

  # Subscribe to events, which are yielded to the given block
  # as strings.
  def subscribe(&block)
    @receive_channel.subscribe(&block)
    self
  end

  # Subscribe to display updates, which are yielded to the given
  # block as an array of lines. The whole array is always present,
  # even if only one line has changed.
  def subscribe_display(&block)
    @display_channel.subscribe(&block)
    self
  end

  def associate_callback_target(target)
    nil
  end

  protected
  def log(msg)
    @log_output.puts(msg.to_s) if @log_output
  end
end

# The state of the Rotel amplifier. This subscribes to the events
# of a `RotelConnection` instance, and parses them to maintain the
# state of the amplifier locally, without having to poll it.
#
# Accessors will sanitize the values and set them on the amplifier,
# but the state of this instance only changes when the amplifier
# acknowledges it. The accessors generally only work when the
# amplifier is powered, although `set_source` and `set_volume` can
# be used to queue a setting before the power is up (e.g., because
# power-on is not instantaneous).
#
# There is no way to associate a given state change with a given
# action, e.g., the user could be operating the physical controls
# at the same time. As such, any actions are simply assumed to
# succeed (unless power is off, in which case they are assumed
# to fail).
class RotelAmplifier
  attr_reader :connection

  # The IO object for log output (e.g., `$stdout`).
  attr_accessor :log_output

  # Should any string be accepted as a source?
  attr_accessor :allow_unknown_sources

  # Should the amplifier be always unmuted on power-up?
  attr_accessor :unmute_on_power_up

  # Is the power on?
  attr_reader :power

  # The raw volume (see also `volume`).
  attr_reader :volume_raw

  # Are the "A" speakers on?
  attr_reader :speakersA

  # Are the "B" speakers on?
  attr_reader :speakersB

  # Is mute enabled?
  attr_reader :mute

  # The current input source.
  attr_reader :source

  # The dictionary of valid sources.
  attr_reader :sources

  # The dictionary of digital input sources.
  attr_reader :digital_sources

  # The digital signal frequency in Hz (e.g., 44100), if a digital
  # input is selected and a signal is present.
  attr_reader :frequency

  # A convenience mutex for multithreaded access to this instance.
  # Not needed with EventMachine, but can be used to support traditional
  # Ruby threads.
  attr_accessor :mutex

  # The threshold for logging changes to the volume. Setting this greater
  # than 1 reduces spam in logs when the volume is incrementally adjusted.
  attr_accessor :volume_report_threshold

  # A settable flag to detect inactivity. Messages from the amplifier reset
  # this to `false`.
  attr_accessor :inactive

  # Initialize with `connection`, a `RotelConnection` instance. The
  # `log` output may be given to enable logging (e.g., `$stderr`).
  # The amplifier supports reporting its display contents whenever they
  # change (which includes every volume change, every passing second of
  # a track from USB, etc.), which we don't really need. However, if you
  # wish to enable it, set `update_display` to `true` and use the `display`
  # accessor to fetch the display contents.
  def initialize(connection, log: nil, update_display: false)
    @connection = connection
    @state_channel = EventMachine::Channel.new
    @mutex = Mutex.new

    # Settings
    @log_output = log
    @allow_unknown_sources = false
    @unmute_on_power_up = true
    @sources = { 'cd' => 'cd',
                 'coax1' => 'coax1',
                 'coax2' => 'coax2',
                 'opt1' => 'opt1',
                 'opt2' => 'opt2',
                 'aux1' => 'aux1',
                 'aux2' => 'aux2',
                 'tuner' => 'tuner',
                 'phono' => 'phono',
                 'usb' => 'usb',
                 'pc_usb' => 'pc_usb',
                 'bal_xlr' => 'bal_xlr',
                 'xlr' => 'bal_xlr',
                 'pc' => 'pc_usb',
    }
    @digital_sources = {
      'coax1' => true,
      'coax2' => true,
      'opt1' => true,
      'opt2' => true,
      'usb' => true,
      'pc_usb' => true,
    }
    @update_display = update_display

    # State
    @power = nil
    @source = nil
    @volume_raw = nil
    @speakersA = nil
    @speakersB = nil
    @volume_raw_limit = nil
    @volume_raw_max = 96
    @volume_raw_min = 0
    @volume_raw_range = nil
    @frequency = nil
    @mute = false
    @future_source = nil
    @future_volume = nil
    @future_speakersA = nil
    @future_speakersB = nil
    @last_reported_volume = -100
    @volume_report_threshold = 1
    @inactive = true

    # Subscribe to state changes
    @connection.subscribe(&method(:handle_message))
    if @update_display
      @connection.subscribe_display(&method(:handle_display))
    end

    # Get the current power state
    send '!get_current_power'
  end

  # Subscribe to the state change channel. The channel simply receives this
  # object on state change.
  def subscribe(&block)
    @state_channel.subscribe(&block)
    self
  end

  # Send the remote control button `button`.
  def send_button(button)
    return false unless @power || button =~ /^power_(on|toggle)$/
    case button.to_s
    when 'play', 'pause', 'stop', 'track_fwd', 'track_back', 'fast_fwd', 'fast_back', 'mute'
      send button
    when 'random', 'repeat', 'menu', 'exit', 'enter'
      send button
    when 'up', 'down', 'left', 'right'
      send button
    when 'tone_on', 'tone_off', 'bass_up', 'bass_down', 'treble_up', 'treble_down'
      send button
    when 'balance_right', 'balance_left', 'balance_000'
      send button
    when 'volume_up'
      volume_up
    when 'volume_down'
      volume_down
    when /^[0-9]$/
      send button
    when 'power_on'
      self.power = true
    when 'power_off'
      self.power = false
    when 'power_toggle'
      send button
    when 'mute_on'
      self.mute = true
    when 'mute_off'
      self.mute = false
    else
      if @sources[button.to_s]
        self.source = button
      else
        log "! Unknown button: #{button}"
        nil
      end
    end
  end

  # Set the amplifier power on (`true)` or off (`false`).
  def power=(state)
    return if state.nil?
    if state
      send '!power_on'
    elsif @power != false
      send '!power_off'
    end
    return !!state
  end

  # Set the state of the "A" speakers.
  def speakersA=(state)
    return @speakersA unless @power && !state.nil? && !@speakersA.nil? && @speakersA != !!state
    send '!speaker_a'
    state
  end

  # Set the state of the "A" speakers. If the amplifier is currently powered
  # off, the state will still be set on power-up, if that happens within
  # `timeout` seconds. Note that this doesn't work on the very first power-up
  # after restarting the server, since the control is a toggle and the initial
  # state is unknown.
  def set_speakersA(state, timeout: 8)
    if @power
      self.speakersA = state
    else
      @future_speakersA = state
      set_timer(timeout) do
        unless @power || @future_speakersA != state
          log "! Pre-set speakers A change expired: #{@future_speakersA}"
          @future_speakersA = nil
        end
      end
      state
    end
  end

  # Set the state of the "B" speakers.
  def speakersB=(state)
    return @speakersB unless @power && !state.nil? && !@speakersB.nil? && @speakersB != !!state
    send '!speaker_b'
    state
  end

  # Set the state of the "B" speakers. If the amplifier is currently powered
  # off, the state will still be set on power-up, if that happens within
  # `timeout` seconds. Note that this doesn't work on the very first power-up
  # after restarting the server, since the control is a toggle and the initial
  # state is unknown.
  def set_speakersB(state, timeout: 8)
    if @power
      self.speakersB = state
    else
      @future_speakersB = state
      set_timer(timeout) do
        unless @power || @future_speakersB != state
          log "! Pre-set speakers B change expired: #{@future_speakersB}"
          @future_speakersB = nil
        end
      end
      state
    end
  end

  # Get the current state of the speakers, returning one of:
  # `:a`, `:b`, `:both`, and `:none`.
  def speakers
    if @speakersA
      return @speakersB ? :both : :a
    end
    return @speakersB ? :b : :none
  end

  # Set the state of the speakers, where the `setting` is one of:
  # `a`, `b`, `both`, and `none`.
  def speakers=(setting)
    return unless @power && setting
    case setting.to_s.downcase
    when 'a'
      self.speakersA = true
      self.speakersB = false
    when 'b'
      self.speakersA = false
      self.speakersB = true
    when 'both', 'ab', 'a_b'
      self.speakersA = true
      self.speakersB = true
    when 'off', 'none', 'false', '0'
      self.speakersA = false
      self.speakersB = false
    end
    setting
  end

  # Set the input source, if the amplifier is powered on.
  def source=(setting)
    src = @sources[setting.to_s].to_s
    return @source unless @power && src && @source.to_s != src
    send "!#{src}"
  end

  # Set the input source. If the amplifier is currently powered off,
  # the source will still be set on power-up, as long as that happens
  # within `timeout` seconds.
  def set_source(src, timeout: 8)
    return @source unless src
    if @power
      self.source = src
    else
      @future_source = src
      set_timer(timeout) do
        unless @power || @future_source != src
          log "! Pre-set source change expired: #{@future_source}"
          @future_source = nil
        end
      end
      src
    end
  end

  # Set mute (`true` = mute, `false` = unmute).
  def mute=(state)
    return false unless @power && !state.nil? && @mute != !!state
    send "!mute_#{state ? 'on' : 'off'}"
    return !!state
  end

  # Convert a 0–100 volume to the raw units. Note that the meaning of
  # the range changes according to `volume_raw_limit` (the "100%").
  def volume_percent_to_raw(vol)
    volmin = @volume_raw_min.to_f
    volmax = self.volume_raw_limit.to_f - volmin
    rawvol = ((vol.to_f / 100.0) * volmax) + volmin
    return rawvol
  end

  # Convert a raw volume to the 0–100 range. Note that the meaning of
  # the range changes according to `volume_raw_limit` (the "100%").
  def volume_raw_to_percent(vol)
    volmin = @volume_raw_min.to_f
    volmax = self.volume_raw_limit.to_f - volmin
    volpct = (vol.to_f - volmin) * (100.0 / volmax)
    return volpct
  end

  # Set the raw volume, in the units displayed on the amplifier.
  def volume_raw=(vol)
    return @volume_raw unless @power && vol && vol.to_i != @volume_raw
    vol = vol.to_i
    vol = volume_raw_limit if vol > volume_raw_limit
    setting = ''
    if vol <= @volume_raw_min
      setting = 'min'
      vol = @volume_raw_min.to_i
    elsif vol >= @volume_raw_max
      setting = 'max'
      vol = @volume_raw_max.to_i
    else
      setting = vol.to_s
    end
    send "volume_#{setting}"
    vol
  end

  # Increase the volume.
  def volume_up
    return false unless @power && @volume_raw < volume_raw_limit
    send 'volume_up'
    return true
  end

  # Decrease the volume.
  def volume_down
    return false unless @power && @volume_raw > @volume_raw_min
    send 'volume_down'
    return true
  end

  # The current volume, in the range 0–100. See `volume_raw` for the
  # actual volume displayed on the amplifier.
  def volume
    volume_raw_to_percent(@volume_raw)
  end

  # Set the volume (0–100) if powered on.
  def volume=(vol)
    return self.volume unless vol
    volraw = volume_percent_to_raw(vol).round
    volume_raw_to_percent(self.volume_raw = volraw)
  end

  # Set the volume (0–100). If the amplifier is currently powered off,
  # the volume will still be set on power-up, if that happens within
  # `timeout` seconds.
  def set_volume(vol, timeout: 8)
    return @volume unless vol
    if @power
      self.volume = vol
    else
      @future_volume = vol
      set_timer(timeout) do
        unless @power || @future_volume != vol
          log "! Pre-set volume change expired: #{@future_volume}"
          @future_volume = nil
        end
      end
      vol
    end
  end

  # The maximum raw volume that is allowed to be set. This value on the
  # amplifier corresponds to the value `100` of `volume` (which always
  # has a range of 0–100.
  def volume_raw_limit
    @volume_raw_limit || @volume_raw_max
  end

  # Set the maximum volume that can be set. This maps the 0–100 `volume`
  # range. The limit given here is in the same units as displayed on the
  # amplifier itself.
  def volume_raw_limit=(limit)
    limit = limit.to_i
    if limit <= 0
      @volume_raw_limit = nil
    else
      limit = @volume_raw_max if limit > @volume_raw_max
      @volume_raw_limit = limit
    end
  end

  # Is the amplifier powered, with a digital source selected and a signal
  # present?
  def has_digital_signal?
    return @power && @digital_sources[@source.to_s] && @frequency
  end

  # Is the amplifier powered, with an analog source selected?
  # (It is not possible to know whether there is a signal actually present,
  # since in a way there is always an analog signal.)
  def has_analog_signal?
    return @power && @sources[@source.to_s] && !@digital_sources[@source.to_s]
  end

  # An array of lines containing the contents of the amplifier's
  # display. This is not reliably updated unless `update_display`
  # is set in the constructor.
  def display
    return [ @rotel.display1, @rotel.display2 ]
  end

  protected

  # Called when the power state changes from off to on. Note that the amplifier
  # is not very good at responding to actions immediately at this point, so
  # this mainly does queries (which seem to work fine) and the separate
  # `after_power_up` method is called a bit later.
  def on_power_up
    send "display_update_#{@update_display ? 'auto' : 'manual'}"

    # Get the volume range if we haven't already
    if @volume_raw_range.nil?
      send 'get_volume_max'
      send 'get_volume_min'
    end

    # Always update state on power-up
    send 'get_current_source'
    send 'get_current_speaker'
    send 'get_volume'
    send 'get_mute_status'

    # Attempt these immediately to make it more responsive
    self.volume = @future_volume if @future_volume
    self.source = @future_source if @future_source
  end

  # Called a few seconds after power-up, since the amplifier takes
  # a while to respond to some actions after booting. (For example,
  # toggling speakers seems to be a NOP for about 3 seconds.)
  def after_power_up
    @state_channel.push self

    if @future_volume
      log "! Pre-set volume change activated: #{@future_volume}"
      self.volume = @future_volume
      @future_volume = nil
    end

    if @future_source
      log "! Pre-set source change activated: #{@future_source}"
      self.source = @future_source
      @future_source = nil
    end

    if @future_speakersA
      log "! Pre-set A speakers change activated: #{@future_speakersA}"
      self.speakersA = @future_speakersA
      @future_speakersA = nil
    end

    if @future_speakersB
      log "! Pre-set B speakers change activated: #{@future_speakersB}"
      self.speakersB = @future_speakersB
      @future_speakersB = nil
    end

    if @unmute_on_power_up && @mute
      log "! Unmute on power-up"
      self.mute = false
    end
  end

  # Called when the power state changes from on to off.
  def on_power_down
    @state_channel.push self
  end

  # Handle a pre-parsed message from the amplifier and update
  # internal state accordingly. This should be the only place where
  # the state is directly changed.
  def handle_message(message)
    msg = message.to_s.gsub(/[^a-zA-Z0-9=_,.\/:+-]+/, '')
    return if msg.empty?

    @inactive = false
    is_power_event = false
    old_volume = @volume_raw

    case msg
    when 'power=on'
      had_power = @power
      @power = true
      log "# Power on" unless had_power
      unless had_power
        on_power_up
        # The amplifier takes a while to respond to some actions after power-up
        set_timer(4) { after_power_up if @power }
      end
      is_power_event = true
    when 'power_on'
      log "# Powering up"
      is_power_event = true
    when '00:power_on'
      log "# About to power up"
      # Send the query due to `is_power_event` remaining false
    when 'power=standby', 'power=off', '00:power_off'
      had_power = @power
      @power = false
      log "# Power off" if had_power != false
      on_power_down if had_power
      is_power_event = true
    when 'mute=on'
      log "# Mute on"
      @mute = true
      @state_channel.push self
    when 'mute=off'
      log "# Mute off"
      @mute = false
      @state_channel.push self
    when /^volume=min/
      @volume_raw = @volume_raw_min
      if @last_reported_volume != @volume_raw
        @last_reported_volume = @volume_raw
        log "# Volume: min #{volume_raw} (#{volume.round} %)"
      end
    when /^volume=max/
      @volume_raw = @volume_raw_max
      if @last_reported_volume != @volume_raw
        @last_reported_volume = @volume_raw
        log "# Volume: max #{volume_raw} (#{volume.round} %)"
      end
    when /^volume=/
      msg.slice!(/^[^=]+=[ 0]*/)
      @volume_raw = msg.to_i
      @future_volume = nil if @power && @future_volume && @future_volume == @volume_raw
      if (@last_reported_volume - @volume_raw).abs >= @volume_report_threshold
        @last_reported_volume = @volume_raw
        log "# Volume: #{@volume_raw} (#{volume.round} %)"
      end
    when /^volume_min=/
      msg.slice!(/^[^=]+=[ 0]*/)
      @volume_raw_min = msg.to_i
      @volume_raw_min = 0 if @volume_raw_min < 0 || @volume_raw_min > @volume_raw_max.to_i
      @volume_raw_range = @volume_raw_max.to_i - @volume_raw_min
      log "# Volume min: #{@volume_raw_min}"
    when /^volume_max=/
      msg.slice!(/^[^=]+=[ 0]*/)
      @volume_raw_max = msg.to_i
      @volume_raw_max = 96 if @volume_raw_max <= @volume_raw_min.to_i
      @volume_raw_range = @volume_raw_max - @volume_raw_min.to_i
      log "# Volume max: #{@volume_raw_max}"
    when /^source=/
      old_source = @source

      msg.slice!(/^[^=]+=[ 0]*/)
      msg = 'cd' if msg == 'analog_cd'
      msg.sub!(/_cd$/, '')
      src = @sources[msg]

      if src
        @source = src
        @future_source = nil if @power && @future_source && @future_source == src
        if @source != old_source
          log "# Source: #{@source}"
          @state_channel.push self
        end
      else
        log "! Unknown source setting: #{msg}"
        @source = msg if @allow_unknown_sources
      end

      if old_source.nil? && @power && @digital_sources[@source.to_s]
        send 'get_current_freq'
      end
    when /^speaker=/
      msg.slice!(/^[^=]+=/)
      case msg.to_s.downcase
      when 'a'
        @speakersA = true
        @speakersB = false
      when 'b'
        @speakersA = false
        @speakersB = true
      when 'a_b', 'ab', 'both'
        @speakersA = true
        @speakersB = true
      when 'off', 'none'
        @speakersA = false
        @speakersB = false
      else
        log "! Unknown speaker setting: #{msg}"
        return
      end
      log "# Speakers: #{self.speakers}"
      @state_channel.push self
    when /^bass=/, /^treble=/, /^balance=/, /^tone=/
      log "# Tone control: #{msg}"
    when /^play_status=/
      msg.slice!(/^[^=]+=/)
      log "# Play status: #{msg}"
    when /^freq=/
      msg.slice!(/^[^=]+=/)
      @frequency = msg.to_f
      if @frequency.nan? || @frequency < 1
        @frequency = nil
      else
        @frequency = (@frequency * 1000).round.to_i
      end
      log "# Frequency: #{@frequency || 'no signal'}"
      @state_channel.push self
    when /^pcusb_class=/
      msg.slice!(/^[^=]+=/)
      log "# PC-USB class: #{msg}"
      is_power_event = true
    when /^display_update=/
      is_power_event = true
      log "# Display updates: #{msg}"
    when /^dimmer[=_]/
      msg.slice!(/^[^=_]+[=_]/)
      log "# Dimmer: #{msg}"
    else
      is_power_event = true # Unknown, so no assumptions
      log "! Unhandled: #{msg.inspect}"
    end

    unless is_power_event || @power
      # We think we are off, but the event indicates we might be on
      send 'get_current_power'
    end

    @state_channel.push(self) if old_volume != @volume_raw
  end

  # Handle display updates (this is only used if `update_display` is set
  # in the constructor).
  def handle_display(display)
    return nil unless @update_display
    (display || []).each do |line|
      log "##|#{line}|##"
    end
    @state_channel.push self
  end

  # Send a message to the amplifier. The terminating `!` is added
  # automatically.
  def send(msg)
    @connection.send "#{msg.strip}!" unless msg.empty?
    msg
  end

  def log(msg)
    @log_output.puts(msg.to_s) if @log_output
  end

  def set_timer(timeout, &block)
    return nil unless timeout.to_f > 0
    EventMachine::Timer.new(timeout.to_f, &block)
  end
end

# The TCP server that listens for commands and queries and interfaces with the
# serial port `RotelAmplifier`.
module RotelServer
  attr_accessor :log_output
  attr_accessor :single_request

  # Set up with `rotel`, a `RotelAmplifier` instance.
  def initialize(rotel, log_output = nil, single_request = true)
    @partial_data = ''
    @log_output = log_output
    @peer = 'net'
    @rotel = rotel
    @single_request = single_request
    self.comm_inactivity_timeout = 3.0
  end

  # Parse an argument string into a boolean value, or `nil`
  # if it is not recognized as one. This supports all of `on`/`off`,
  # `true`/`false`, `1`/`0`, and `yes`/`no`.
  def parse_boolean(arg)
    case arg.to_s.downcase
    when 'on', 'true', '1', 'yes'
      return true
    when 'off', 'false', '0', 'no'
      return false
    else
      return nil
    end
  end

  # Handle a command or query over TCP. Returns the reply value,
  # which is converted to a string and sent to the client.
  def handle_message(message)
    msg = message.to_s
    fields = msg.split
    return nil if fields.empty?

    case fields[0].to_s
    when 'wake', 'on'
      @rotel.inactive = false
      @rotel.power = true
    when 'off', 'standby'
      @rotel.inactive = false
      @rotel.power = false
    when 'power'
      @rotel.inactive = false
      @rotel.power = parse_boolean(fields[1].to_s)
    when 'in', 'input'
      @rotel.inactive = false
      src = fields[1].to_s
      if @rotel.sources[src]
        @rotel.power = true
        @rotel.set_source(src)
      end
    when 'source'
      @rotel.inactive = false
      @rotel.set_source(fields[1].to_s)
    when 'vol', 'volume'
      @rotel.inactive = false
      vol = nil
      if fields.count == 2
        vol = fields[1].to_s
      elsif fields.count >= 3
        @rotel.source = fields[1].to_s
        vol = fields[2].to_s
      end
      case vol
      when 'up'
        return @rotel.volume_raw = (@rotel.volume_raw.to_i) + 1
      when 'down'
        return @rotel.volume_raw = (@rotel.volume_raw.to_i) - 1
      when '0.0', '', 'nil', '-'
        return @rotel.volume
      when '1.0'
        return @rotel.volume = 100
      when /^-/
        return @rotel.volume_raw = (@rotel.volume_raw_limit + vol.to_f).round.to_i
      else
        vol = vol.to_f
        vol *= 100 if vol < 1.0
        return set_volume(vol)
      end
    when 'maybe'
      # Legacy feature to turn off by lowering volume, but only if a specific
      # source is selected
      if @rotel.power && @rotel.volume_raw <= 10 && (fields.count == 1 || fields.include?(@rotel.source))
        @rotel.power = false
      else
        @rotel.power
      end
    when 'sleep'
      timeout = 30
      timeout = fields[1].to_f if fields.count >= 2
      @rotel.inactive = true
      set_timer(timeout) do
        if @rotel.inactive && @rotel.power
          log "! Sleep timer expired without activity, power off"
          @rotel.power = false
        end
      end
      timeout
    when 'mute'
      @rotel.mute = parse_boolean(fields[1].to_s)
    when 'speakers'
      case fields[1].to_s
      when 'a'
        @rotel.speakers = :a
      when 'b'
        @rotel.speakers = :b
      when 'ab', 'both'
        @rotel.speakers = :both
      when 'off', 'none'
        @rotel.speakers = :none
      else
        #
      end
    when 'a'
      @rotel.set_speakersA(parse_boolean(fields[1].to_s))
    when 'b'
      @rotel.set_speakersB(parse_boolean(fields[1].to_s))
    when 'key', 'button'
      button = fields[1].to_s.gsub(/[^a-z0-9_]/, '')
      @rotel.send_button button
    when '?'
      case fields[1].to_s
      when 'power'
        @rotel.power ? 'on' : 'off'
      when 'on'
        @rotel.power ? 'true' : 'false'
      when 'vol', 'volume'
        (@rotel.volume || 0).round.to_i
      when 'in', 'input', 'source'
        @rotel.source
      when 'speakers'
        @rotel.speakers
      when 'a'
        @rotel.speakersA ? 'true' : 'false'
      when 'b'
        @rotel.speakersB ? 'true' : 'false'
      when 'mute', 'muted'
        @rotel.mute ? 'true' : 'false'
      when 'signal'
        @rotel.has_digital_signal? || @rotel.has_analog_signal?
      else
        src = @rotel.sources[fields[1].to_s.downcase]
        if src && @rotel.power && @rotel.source.to_s == src.to_s
          return 'true'
        else
          return 'false'
        end
      end
    else
      @rotel.set_source(@rotel.sources[fields[0].to_s.downcase])
    end
  end

  # Called when data is received. This waits until it has read a full
  # line (newline-terminated), after which it strips and normalizes
  # whitespace before passing it to `handle_message`.
  def receive_data(data)
    @partial_data << data
    data = @partial_data
    @partial_data = ''
    while (message = data.slice!(/^[^\r\n]*[\r\n]+/))
      message.gsub!(/[ \t\r\n]+/, ' ')
      message.strip!
      log "|#{@peer} >> #{message.inspect}"
      reply = ''
      @rotel.mutex.synchronize do
        reply = handle_message(message).to_s
      end
      send reply
      close_connection_after_writing if @single_request
    end
  end

  protected
  def log(msg)
    @log_output.puts(msg.to_s) if @log_output
  end

  def send(msg)
    log "|#{@peer} << #{msg}"
    send_data "#{msg}\n"
  end

  def set_timer(timeout, &block)
    EventMachine::Timer.new(timeout.to_f, &block)
  end
end

server_ip = '127.0.0.1'
server_port = 65015
serial_device = '/dev/ttyAMA0'
log_output = nil
net_log_output = nil
update_display = false
detach_process = false
volume_limit = 55

ARGV.each do |arg|
  case arg
  when '-d'
    detach_process = true
  when '-v'
    if log_output.nil?
      log_output = $stderr
    elsif net_log_output.nil?
      net_log_output = $stdout
    else
      update_display = true
      RotelConnection.log_output = $stderr
    end
  when '-n'
    detach_process = false
  when '-u'
    update_display = true
  when /^[0-9]+$/
    server_port = arg.to_i
  when /^\/dev\//
    serial_device = arg
  when /^([0-9a-z]+[.:]+)+[a-z]+$/
    server_ip = arg
  when '--help', '-h', '--version'
    $stderr.puts 'rotel-server by Kimmo Kulovesi <https://arkku.dev/>, 2020-2021'
    exit 0 if arg == '--version'
    $stderr.puts 'Arguments:'
    $stderr.puts '  -d          detach/daemonize process'
    $stderr.puts '  -n          do not daemonize'
    $stderr.puts '  -v          verbose'
    $stderr.puts '  -v -v       very verbose'
    $stderr.puts '  -v -v -v    very, very verbose (serial data to stderr)'
    $stderr.puts '  -u          listen to display content updates'
    $stderr.puts "  /dev/ttyS0  serial port device (default #{serial_device})"
    $stderr.puts "  0.0.0.0     IP address (default #{server_ip})"
    $stderr.puts "  1234        TCP port (default #{server_port})"
    exit 0
  when '--'
    #
  else
    $stderr.puts "Unknown argument: #{arg}"
    exit 1
  end
end

socket_from_systemd = (ENV['LISTEN_PID'].to_i == $$) ? Socket.for_fd(3) : nil

Thread.report_on_exception = true if Thread.respond_to? :report_on_exception
Process.daemon if detach_process

EventMachine.run do
  connection = EventMachine.open_serial(serial_device, baud: 115200, handler: RotelConnection)

  rotel = RotelAmplifier.new(connection, log: log_output, update_display: update_display)
  rotel.volume_raw_limit = volume_limit

  # Reduce volume state logging spam when detached and not very verbose
  rotel.volume_report_threshold = (!net_log_output ? 10 : 1)

  if socket_from_systemd.nil?
    log_output.puts("Starting server on port #{server_ip} port #{server_port}") if log_output
    EventMachine.start_server(server_ip, server_port, RotelServer, rotel, net_log_output)
  else
    log_output.puts("Attaching to socket from systemd") if log_output
    EventMachine.attach_server(socket_from_systemd, RotelServer, rotel, net_log_output)
    socket_from_systemd = nil
  end
end
