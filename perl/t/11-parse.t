#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;

use_ok 'Log::Progress::Parser' or BAIL_OUT;

my $parser= Log::Progress::Parser->new(input => <<'END');
fsjfkjsdhfksjdf
progress: 0
lfgenrnb,merbg
progress: 0.1
rmntbemrbtmrenbt
END

$parser->parse;
is_deeply(
	$parser->status,
	{ message => undef, progress => 0.1 },
	'simple progress'
) or diag explain $parser->status;

$parser= Log::Progress::Parser->new(input => 
"progress: foo (.5) Step 1
progress: bar (.5) Step 2
progress: foo 0/10
progress: bar 1/10 - Status message
progress: bar 5/10" );  # Final line doesn't count because no newline

$parser->parse;
is_deeply(
	$parser->status,
	{ progress => .05, step => {
		foo => {
			idx => 0,
			title => "Step 1",
			contribution => .5,
			progress => 0, pos => 0, max => 10,
			message => undef,
		},
		bar => {
			idx => 1,
			title => "Step 2",
			contribution => .5,
			progress => .1, pos => 1, max => 10,
			message => 'Status message',
		},
	}},
	'substep progress',
) or diag explain $parser->status;

# Now, extend the input and parse more of it
$parser->input($parser->input . " - New Status Message\n");
$parser->parse;
is_deeply(
	$parser->status,
	{ progress => .25, step => {
		foo => {
			idx => 0,
			title => "Step 1",
			contribution => .5,
			progress => 0, pos => 0, max => 10,
			message => undef,
		},
		bar => {
			idx => 1,
			title => "Step 2",
			contribution => .5,
			progress => .5, pos => 5, max => 10,
			message => 'New Status Message',
		},
	}},
	'substep progress',
) or diag explain $parser->status;

done_testing;
