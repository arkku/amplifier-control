#!/usr/bin/env ruby
#Process.setproctitle("rotel-server")
#$0="rotel-server"

require 'socket'
require 'timeout'
require_relative 'rotel'

max_volume = 50
min_volume = 10
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
      log = '#'
      command = nil
      begin
        Timeout::timeout(5) do
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

          case fields.first.to_s
          when 'vol', 'volume'
            if fields.count == 2
              volume = fields[1].to_f
            elsif fields.count > 2
              source = fields[1]
              volume = fields[2].to_f
            else
              log = '?'
            end
          when 'in', 'input'
            if fields.count >= 2
              source = fields[1].to_s
            else
              log = '?'
            end
            power = :on
          when 'wake'
            if $rotel && !$rotel.power
              power = :on
              source = fields[1] if fields.count == 2
            end
          when 'off'
            if fields.count == 1 || ($rotel && fields.include?($rotel.source))
              power = :off
            end
          when 'maybe'
            if $rotel && $rotel.power && $rotel.volume <= 10 && (fields.count == 1 || fields.include?($rotel.source))
              power = :off
            end
          else
            source = fields.first
          end

          case power
          when :on
            $rotel.power = true if $rotel
            log = '# on'
          when :off
            $rotel.power = false if $rotel
            log = '# off'
          else
            #
          end
          if !volume.nil?
            if source.nil? || ($rotel && $rotel.source == source)
              target_volume = (max_volume + volume + 0.5).to_i
              target_volume = 0 if target_volume < 0
              target_volume = max_volume if target_volume > max_volume
              $stderr.puts("! Volume #{target_volume} on #{source}\n")
              $rotel.volume = target_volume if $rotel
              log = "# volume #{target_volume}"
            else
              log = "! #{source}"
            end
          elsif source
            source = source.downcase
            if $rotel && $rotel.sources.include?(source)
              $stderr.puts("! Source: #{source}\n")
              attempts = 10
              while attempts > 0 && $rotel.source != source
                $rotel.source = source
                attempts -= 1
              end
              $keep_running = false if attempts < 1
              log = "# source #{source}"
            else
              log = "! #{source}"
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
