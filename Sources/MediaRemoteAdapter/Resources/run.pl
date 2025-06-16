#!/usr/bin/perl

# Copyright (c) 2025 Jonas van den Berg
# This file is licensed under the BSD 3-Clause License.

use strict;
use warnings;
use DynaLoader;
use File::Spec;
use File::Basename;
use Cwd 'abs_path';
use FindBin;

# This script dynamically loads the MediaRemoteAdapter dylib and executes
# a command. It's designed to be called by a parent process that provides
# the full path to the dylib.

my $usage = "Usage: $0 <path_to_dylib> <loop|play|pause|...|set_time TIME>";
die $usage unless @ARGV >= 2;

my $dylib_path = shift @ARGV;
my $command = shift @ARGV;

unless (-e $dylib_path) {
    die "Dynamic library not found at $dylib_path\n";
}

# DynaLoader may need to find the mangled C symbol (_bootstrap)
# We add both to the list of symbols to try.
my @bootstrap_symbols = ("bootstrap", "_bootstrap");
DynaLoader::bootstrap_inherit($dylib_path, \@bootstrap_symbols);

# Call bootstrap once loaded
bootstrap();

if (not defined $command) {
    die "A command is required.\n$usage\n";
}

if ($command eq 'loop') {
    loop();
} elsif ($command eq 'play') {
    play();
} elsif ($command eq 'pause') {
    pause_command();
} elsif ($command eq 'toggle_play_pause') {
    toggle_play_pause();
} elsif ($command eq 'next_track') {
    next_track();
} elsif ($command eq 'previous_track') {
    previous_track();
} elsif ($command eq 'stop') {
    stop_command();
} else {
    die "Unknown command: $command\n";
} 