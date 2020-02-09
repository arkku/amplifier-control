# Rotel RA-1570 control

## Introduction

This repository is a collection of scripts I use to control the Rotel RA-1570
amplifier via serial port (RS-232). Since the task is extremely specific to
my setup, I don't expect them to be usable by anyone else as-is, but there may
be some helpful ideas to be had.

The basis of my setup is a Raspberry Pi running Linux, which controls the
amplifier over its serial port (`/dev/ttyAMA0`) and runs *shairport-sync*
connected to the USB input of the amplifier (`pc_usb`). Starting AirPlay
switches the amplifier to the corresponding input. I also have a
Mac Mini Server connected to one of the amplifier's optical inputs (`opt1`),
running *iTunes*. Starting playback on *iTunes* (usually via the *Remote* app
on an iPad) sends a TCP message to the Raspberry Pi, instructing it to
switch to the corresponding input.

~ [Kimmo Kulovesi](https://arkku.dev/), 2016-10-01


## Serial Port Control

The Rotel RA-1570 can be controlled over an RS-232 serial port. Only the TXD and
RXD lines are required as there is no hardware flow control or handshake. The
Raspberry Pi's built-in serial port can be used with a simple converter, e.g.,
a MAX3232 chip (simple pre-soldered boards with a connector can be found on the
big auction site for around 1 EUR/USD).

On this particular amplifier the protocol settings are 115200 bps, 8 bits,
1 stop bit, no parity, no flow control. A thing to note about the protocol is
that it uses the exclamation mark (`!`) as the record separator _without_
any newlines. Adding newlines will break the following commands, although a
way to circumvent this is to start every command with an exclamation mark.

I believe similar protocols are used on other Rotel devices with RS-232
control. Other manufacturers surely have their own protocols and settings, but
the basic ideas are the same.

### Control Server

One problem with running a new script every time an action is taken is that
multiple scripts in rapid succession can read partial data from the serial
port, or alternatively end up blocking one another. Hence the server,
`rotel-server.rb` was born: it is run as a daemon (see `rotel-server.initd`
for the `/etc/init.d` script), and maintains a single open descriptor to
the serial port, while processing commands received via TCP (listening only
on the loopback interface at `127.0.0.1`). This allows very rapid commands
like interactive volume control. Most of the other scripts are now implemented
using it, but `switch-to-input` falls back to the stand-alone version as
needed.

## Switching Inputs Locally

The Ruby "library" `rotel.rb` contains an implementation of a subset of the
amplifier's control protocol. Communication happens over serial port using the
`serialport` gem (install with `gem install serialport`).

The Ruby script `switch-to-input.rb` uses the library to switch to the input
named on the command line (e.g., `switch-to-input.rb coax1`). It also ensures
the volume is at a safe level before switching. See this script for a reference
of how to control the amplifier with Ruby.

### shairport-sync

The machine controlling the input switching is also running *shairport-sync*,
an open-source implementation of an AirPlay server. The included
`shairport-sync.conf` calls the switch-to-input and set-volume scripts.

### raspotify/librespotify

The script `librespot-event` can be set up to respond to the `--onevent`
call of *Raspotify*, as seen in `raspotify.default`.

## Remote Switching of Inputs

To switch inputs remotely, the machine attached to the serial port needs to
run some kind of server. One option would be *ssh*, but the idea of leaving
login credentials permanently unlocked does not appeal to me. (This is more of
an ideological than practical concern, however, as the Raspberry Pi used as
amp controller is behind a firewall, NAT, and also not really doing anything
else except this.)

I decided to run *xinetd*, as it makes the implementation of a TCP server
very simple. The configuration file `amplifier-xinetd` is placed in
`/etc/xinetd.d` whereas the server script itself is `amplifier-inetd.sh`
(the path in `amplifier-xinetd` needs to be edited accordingly). Also,
add the service `amplistener 65432/tcp` to `/etc/services` (edit the port
as desired).

The service accepts messages of the format `playing input`, where input is
the name of the input to switch to. For example, when *iTunes* starts playing
on the machine connected to `opt1` input, it sends the message with:

    echo 'playing opt1' | nc pi.local 65321

## Listening to iTunes Events

Detecting when iTunes starts playback can be done with Applescript. The
script `itunes-state` simply queries the state and prints it. The permanently
running script `itunes-watcher` polls this script every couple of seconds
to detect the start of playback, which triggers the message over TCP to
switch the amplifier's input.

The file `com.arkku.itunes.plist` contains the property list to configure
the `itunes-watcher` to start (and be kept running) automatically. It is
placed in `~/Library/LaunchAgents` (with the paths and username inside the
file edited) and loaded with:

    launchctl load ~/Library/LaunchAgents/com.arkku.itunes.plist

## Homekit Control

I wrote a little Homebridge plugin to interface with the `rotel-server.rb`
service, which makes it possible to control the amplifiar via Homekit (e.g.,
"Hey Siri, turn off amplifier"). It resides in a [separate
repository](https://github.com/arkku/homebridge-rotel-arkku/)
for ease of installation into Homekit.

