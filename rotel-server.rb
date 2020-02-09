#!/usr/bin/env ruby
#Process.setproctitle("rotel-server")
#$0="rotel-server"

require 'socket'
require 'timeout'
require_relative 'rotel'

max_volume = 55
attempts_remaining = 10

$mutex = Mutex.new
$server = nil

port = ARGV.first.to_i
port = 65015 if port == 0

Thread.report_on_exception = true if Thread.respond_to? :report_on_exception
Thread.abort_on_exception = true
Process.daemon if ARGV.include?('-d') && !ARGV.include?('-n')

loop do
  $mutex.synchronize do
    $keep_running = true
    $rotel = Rotel.new(power_on: false)
    begin
      $server.close if $server
      $server = nil
    rescue Exception => e
    end
    begin
      $server = TCPServer.new("127.0.0.1", port)
    rescue Exception => e
      $stderr.puts("Exception: #{e.inspect}\n")
      attempts_remaining -= 1
      if attempts_remaining == 0
        $keep_running = false
        $stderr.puts("Error: Failed to listen on port #{port}")
        exit 1
      end
    end
    $stderr.puts("! Listening on port #{port}") if $server
  end
  while $keep_running && $server do
    client = $server.accept
    if !client
      $mutex.synchronize do
        $stderr.puts("! No client, restarting")
        $keep_running = false
      end
      next
    end
    $mutex.synchronize do
      attempts_remaining = 10
    end
    Thread.start(client) do |client|
      log = ''
      command = nil
      begin
        Timeout::timeout(3) do
          command = client.gets
        end
      rescue Exception => e
        command = nil
      end

      if command
        command.strip!
        command.rstrip!
        fields = command.split
        $mutex.synchronize do
          $rotel.flush
          source = nil
          volume = nil
          power = :keep
          speakers = :keep

          case fields.first.to_s
          when 'vol', 'volume'
            if fields.count == 2
              volume = fields[1].to_s
            elsif fields.count > 2
              source = fields[1]
              volume = fields[2].to_s
            else
              log = '?'
            end
            if volume == '0.0'
              volume = nil
            elsif volume == '1.0'
              volume = max_volume
            elsif volume =~ /^-/
              volume = max_volume.to_f + volume.to_f
            else
              volume = volume.to_f
              volume *= 100.0 if volume < 1.0
              volume = max_volume.to_f * (volume / 100.0)
            end
          when 'in', 'input'
            if fields.count >= 2
              source = fields[1].to_s
            else
              log = '?'
            end
            power = :on
          when 'source'
            if fields.count >= 2
              source = fields[1].to_s
            else
              log = '?'
            end
          when 'wake', 'on'
            if $rotel && !$rotel.power
              power = :on
              source = fields[1] if fields.count == 2
            end
          when 'off'
            if fields.count == 1 || ($rotel && fields.include?($rotel.source))
              power = :off
            end
          when 'power'
            if fields.count == 2
              value = fields[1].to_s.downcase
              if value == 'on' || value == 'true' || value == '1'
                power = :on
              else
                power = :off
              end
            end
          when 'maybe'
            if $rotel && $rotel.power && $rotel.volume <= 10 && (fields.count == 1 || fields.include?($rotel.source))
              power = :off
            end
          when 'mute'
            if fields.count == 2 && $rotel && $rotel.power
              value = fields[1].to_s.downcase
              if value == 'on' || value == 'true' || value == '1'
                log = ($rotel.muted = true) ? 'true' : 'false'
              else
                log = ($rotel.muted = false) ? 'true' : 'false'
              end
            end
          when 'speakers'
            if fields.count == 2
              value = fields[1].to_s.downcase
              if value == 'a'
                speakers = :a
              elsif value == 'b'
                speakers = :b
              elsif value == 'ab'
                speakers = :both
              elsif value == 'off' || value == 'none'
                speakers = :off
              end
            end
          when 'a'
            if fields.count == 2
              value = fields[1].to_s.downcase
              value = (value == 'on' || value == 'true' || value == '1')
              current = $rotel.speakers
              if value
                speakers = (current == :b ? :both : :a)
              else
                speakers = (current == :both ? :b : :off)
              end
            end
          when 'b'
            if fields.count == 2
              value = fields[1].to_s.downcase
              value = (value == 'on' || value == 'true' || value == '1')
              current = $rotel.speakers
              if value
                speakers = (current == :a ? :both : :b)
              else
                speakers = (current == :both ? :a : :off)
              end
            end
          when 'key', 'button'
            if fields.count >= 2 && $rotel && $rotel.power
              $rotel.send_button(fields[1].to_s.downcase)
            end
          when '?'
            if fields.count >= 2
              power_state = ($rotel && $rotel.power)
              case fields[1].to_s.downcase
              when 'power'
                log = power_state ? 'on' : 'off'
              when 'on'
                log = power_state ? 'true' : 'false'
              when 'vol', 'volume'
                if power_state
                  value = (($rotel.volume.to_f * (100.0 / max_volume.to_f)) + 0.5).to_i
                  value = 100 if value > 100
                  log = value.to_s
                end
              when 'in', 'input', 'source'
                log = $rotel.source.to_s if power_state
              when 'speakers'
                log = $rotel.speakers.to_s if power_state
              when 'a'
                if power_state
                  current = $rotel.speakers
                  log = (current == :a || current == :both) ? 'true' : 'false'
                end
              when 'b'
                if power_state
                  current = $rotel.speakers
                  log = (current == :b || current == :both) ? 'true' : 'false'
                end
              when 'mute', 'muted'
                log = (power_state && $rotel.muted? ? 'true' : 'false')
              else
                query = fields[1].to_s.downcase
                if power_state && $rotel.sources.include?(query)
                  log = ($rotel.source == query) ? 'true' : 'false'
                else
                  log = 'false'
                end
              end
            else
              log = '?'
            end
          else
            source = fields.first
          end

          case power
          when :on
            $rotel.power = true if $rotel
            log = 'true'
          when :off
            $rotel.power = false if $rotel
            log = 'false'
          else
            #
          end

          if $rotel && $rotel.power && speakers != :keep && $rotel.speakers != speakers
            $rotel.speakers = speakers
          end

          if volume != nil
            if $rotel && $rotel.power && (source.nil? || $rotel.source == source)
              target_volume = (volume.to_f + 0.5).to_i
              target_volume = 0 if target_volume < 0
              target_volume = max_volume if target_volume > max_volume
              $stderr.puts("! Volume #{target_volume} on #{source}\n")
              $rotel.volume = target_volume if $rotel
              log = (target_volume.to_f * (100 / max_volume.to_f) + 0.5).to_i.to_s
            else
              log = 'false'
            end
          elsif source
            source = source.downcase
            if $rotel && $rotel.power && $rotel.sources.include?(source)
              $stderr.puts("! Source: #{source}\n")
              attempts = 10
              while attempts > 0 && $rotel.source != source
                log = ($rotel.source = source).to_s.strip
                break if log == source
                attempts -= 1
              end
              $keep_running = false if attempts < 1
              attempts = 3
              while attempts > 0 && log.empty?
                log = $rotel.source.to_s.strip
                attempts -= 1
              end
            end
          end
          $rotel.flush if $rotel
        end
      end

      client.puts("#{log}\n") if !log.empty?
      client.close
    end
  end
  $mutex.synchronize do
    $rotel = nil
    $stderr.puts("Restarting...\n")
  end
end
