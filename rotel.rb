#!/usr/bin/env ruby
require 'rubygems'
require 'serialport'
require 'timeout'

class Rotel

  attr_reader :serial
  attr_reader :sources
  attr_reader :max_volume
  attr_reader :was_off

  def initialize(serial_device: "/dev/ttyAMA0", power_on: false)
    @serial = SerialPort.new(serial_device, 115200, 8, 1, SerialPort::NONE)
    @serial.read_timeout = 3000
    @serial.flow_control = SerialPort::NONE
    begin
      @serial.autoclose = true
      #@serial.ioctl(0x540C, 1)
    rescue Exception => e
    end
    @max_volume = 96
    @maybe_off = true
    begin
      write '!!get_current_power!'
      str = read_until(/power|volume/).to_s
      if !str.to_s.include? 'power=on'
        @was_off = str.include? 'standby'
        if power_on
          write 'power_on!'
          str = read_until(/power|volume/).to_s
          if str.include? 'power=on'
            @maybe_off = false
            write 'display_update_manual!'
            read_until(/display_update/).to_s
          end
        else
          @maybe_off = true
        end
      else
        write 'display_update_manual!'
        read_until(/display_update/).to_s
        @was_off = false
        @maybe_off = false
      end
    rescue Exception => e
    end
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
    self
  end

  def log(msg)
    $stderr.puts "Rotel: #{msg}"
  end

  def flush
    @serial.flush_input
  end

  def read
    result = ''
    begin
      Timeout::timeout(4) do
        loop do
          r = @serial.read(1)
          break if r.nil?
          #r = r.chr
          break if r == '!'
          result << r
        end
      end
    rescue Exception => e
      #
    end
    log ">> #{result}" unless result.empty?
    return result
  end

  def read_until(re)
    loop do
      str = read.to_s
      return str if str =~ re || str.empty?
    end
  end

  def write(msg)
    msg = msg.to_s
    return if msg.empty?
    @serial.flush
    log "<< #{msg}"
    @serial.write("!#{msg}")
  end

  def power
    write 'get_current_power!'
    str = read.to_s
    if str.slice!(/^power=/)
      str.to_s.include? 'on'
    else
      str = read.to_s
      return nil if str.nil? || str.empty?
      str.include? 'power=on'
    end
  end

  def power=(state)
    if state
      write "power_on!"
      @maybe_off = false
      str = read_until(/power=/).to_s
      str = read_until(/power=/).to_s if !str.include? 'power=on'
      return power if str.nil? or str.empty?
      return str.include? 'power=on'
    else
      write "power_off!"
      @maybe_off = true
      str = read_until(/power/).to_s
      return str.include? 'on'
    end
  end

  def source
    write 'get_current_source!'
    str = read
    return '' unless str.slice!(/^source=/)
    str.to_s
  end

  def source=(input)
    dst = @sources[input]
    return nil unless dst
    write "#{dst}!"
    read.to_s
  end

  def volume
    write 'get_volume!'
    str = read_until(/volume/)
    return 0 unless str.slice!(/^volume=/)
    str.to_i
  end

  def volume=(value)
    v = value.to_i
    write "volume_#{v}!"
    volume
  end

  def muted?
    write 'get_mute_status!'
    str = read_until(/mute/)
    return false unless str.slice!(/^mute=/)
    return str == 'on'
  end

  def muted=(state)
    write "mute_#{state ? 'on' : 'off'}!"
    str = read_until(/mute/)
    return false unless str.slice!(/^mute=/)
    return (str == 'on')
  end

  def send_button(button)
    write "#{button}!"
  end

  def speakers
    write 'get_current_speaker!'
    str = read_until(/speaker/)
    return nil unless str.slice!(/^speaker=/)
    case str
    when 'a'
      log 'Speakers: A'
      return :a
    when 'b'
      log 'Speakers: B'
      return :b
    when 'off'
      log 'Speakers: off'
      return :off
    when 'a_b'
      log 'Speakers: A + B'
      return :both
    else
      return nil
    end
  end

  def speakers=(output)
    current = speakers
    return current if current == output || current.nil?
    case output
    when :a
      write 'speaker_a!' unless current == :both
      write 'speaker_b!' unless current == :off
    when :b
      write 'speaker_a!' unless current == :off
      write 'speaker_b!' unless current == :both
    when :both
      write 'speaker_a!' unless current == :a
      write 'speaker_b!' unless current == :b
    when :off
      write 'speaker_a!' if current != :b
      write 'speaker_b!' if current != :a
    end
    speakers
  end

end

