#!/usr/bin/env ruby
# A simple Ruby class for controlling a Rotel amplifier, specifically
# RA-1570 but the protocol is probably used in others as well.
# 
# Requires the `serialport` gem.
#
# Note that the amplifier is a bit evil in that it can send sudden
# status updates at any time, which messes things up if you are
# expecting a specific response.
#
# By Kimmo Kulovesi <http://arkku.com>
# Use at your own risk only!

require 'rubygems'
require 'serialport'

class Rotel

  attr_reader :serial
  attr_reader :sources
  attr_reader :max_volume

  def initialize(serial_device = "/dev/ttyAMA0")
    @serial = SerialPort.new(serial_device, 115200, 8, 1, SerialPort::NONE)
    @max_volume = 96
    begin
      @serial.flush
      write '!power_on!get_volume_max!'
      str = read_until(/volume/)
      if str.slice!(/^volume_max=/)
        @max_volume = str.to_i
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

  def read
    result = ''
    loop do
      r = @serial.read(1)
      break if r.nil?
      #r = r.chr
      break if r == '!'
      result << r
    end
    log ">> #{result}" unless result.empty?
    result
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
    log "<< #{msg}"
    @serial.write("!#{msg}")
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

