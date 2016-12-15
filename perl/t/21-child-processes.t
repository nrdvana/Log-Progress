#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp;
use Time::HiRes 'sleep';

use_ok 'Log::Progress::Parser'
and use_ok 'Log::Progress'
	or BAIL_OUT;

my $fh= File::Temp->new();

my ($writer_a_pid, $writer_b_pid);
{
	Log::Progress->new(to => $fh)->substep('a', .5, 'Task A');
	local $ENV{PROGRESS_STEP_ID}= 'a';
	defined($writer_a_pid= fork) or die "fork: $!";
	if (!$writer_a_pid) {
		my $p= Log::Progress->new(to => $fh);
		for (my $i= 0; $i < 789; $i++) {
			sleep .003;
			$p->progress_ratio($i+1, 789);
		}
		exit 0;
	}
}
{
	Log::Progress->new(to => $fh)->substep('b', .5, 'Task B');
	$ENV{PROGRESS_STEP_ID}= 'b';
	defined ($writer_b_pid= fork) or die "fork: $!";
	if (!$writer_b_pid) {
		my $p= Log::Progress->new(to => $fh);
		for (my $i= 0; $i < 67; $i++) {
			sleep .05;
			$p->progress(($i+1)/67, "$i of 67");
		}
		exit 0;
	}
}

my $in_fh= IO::File->new("$fh", "<");
my $parser= Log::Progress::Parser->new(input => $in_fh);
my $w= 0;
while (($parser->parse->{progress}||0) < 1) {
	if (++$w > 6) {
		warn "Progress did not reach 100% within timeout. tmpfile= $fh";
		$fh->unlink_on_destroy(0);
		kill TERM => $writer_a_pid, $writer_b_pid;
		last;
	};
	note sprintf(" %3d%% %3d%%, parent waiting",
		($parser->status->{step}{a}{progress}||0)*100,
		($parser->status->{step}{b}{progress}||0)*100);
	sleep 1;
}
waitpid $writer_a_pid, 0 or die "waitpid: $!";
waitpid $writer_b_pid, 0 or die "waitpid: $!";

is( $parser->status->{progress}, 1, 'reached 100%' )
	or diag explain $parser->status;

done_testing;
