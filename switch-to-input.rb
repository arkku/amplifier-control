#!/usr/bin/env ruby
require_relative 'rotel'
require 'timeout'

Timeout::timeout(10) do
  my_source = ARGV.first || 'coax1'
  max_volume = 48
  min_volume = 10
  normal_volume = 42

  rotel = Rotel.new(power_on: true)
  exit 0 unless rotel.sources.include? my_source

  source = rotel.source
  exit 0 if source == my_source

  rotel.speakers = :a if rotel.speakers == :both

  volume = rotel.volume
  rotel.volume = normal_volume if volume > max_volume || volume < min_volume

  while rotel.source != my_source
    rotel.source = my_source
  end
end

