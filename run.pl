#!/usr/bin/env perl

use FindBin '$Bin';

$ENV{PERL5LIB} = "$Bin/deps/mouse/lib:$Bin/deps/mousex-nativetraits/lib";

my $command = "$Bin/get_iplayer " . join(" ",map {"'" . $_ . "'"} @ARGV);
`$command`;

