#!/usr/bin/env ruby
require_relative 'rotel'
require 'timeout'

max_volume = 50
my_source = 'coax1'
requested_volume = -10
if ARGV.count == 2
  my_source = ARGV[0].to_s
  requested_volume = ARGV[1].to_i
else
  requested_volume = ARGV.first.to_i
end

target_volume = max_volume + requested_volume
target_volume = 0 if target_volume < 0

$stderr.puts "set volume to #{target_volume} on #{my_source}"

Timeout::timeout(10) do
  rotel = Rotel.new()
  exit 0 unless rotel.sources.include? my_source

  exit 0 if rotel.source != my_source

  exit 0 if rotel.volume == target_volume
  rotel.volume = target_volume
end

