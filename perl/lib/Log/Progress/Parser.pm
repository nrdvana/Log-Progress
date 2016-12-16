package Log::Progress::Parser;
use Moo 2;
use JSON;

# ABSTRACT: Parse progress data from a file

our $VERSION= '0.01';

=head1 DESCRIPTION

(See L<the protocol description|http://github.com/nrdvana/Log-Progress>
 for an overview of what data this module is parsing)

This module parses progress messages from a file handle or string.
Repeated calls to the L</parse> method will continue parsing the file
where it left off, making it relatively efficient to repeatedly call
L</parse> on a live log file.

=head1 SYNOPSIS

  open my $fh, "<", $logfile or die;
  my $parser= Log::Progress::Parser->new(input => $fh);
  $parser->parse;

A practical application:

  # Display a 40-character progress bar at 1-second intervals
  $|= 1;
  while (1) {
    $parser->parse;
    printf "\r%3d%%  [%-40s] ", $parser->status->{progress}*100, "#" x int($parser->status->{progress}*40);
    last if $parser->status->{progress} >= 1;
    sleep 1;
  }
  print "\n";

=head1 ATTRIBUTES

=head2 input

This is a seekable file handle or scalar of log text from which the progress
data will be parsed.  Make sure to set the utf-8 layer on the file handle if
you want to read progress messages that are more than just ascii.

=head2 input_pos

Each call to parse makes a note of the start of the final un-finished line, so
that the next call can pick up where it left off, assuming the file is growing
and the file handle is seekable.

=head2 status

This is a hashref of data describing the progress found in the input.

  {
    progress => $number_between_0_and_1,
    message  => $current_progress_messsage,  # empty string if no message
    pos      => $numerator,   # only present if progress was a fraction
    max      => $denominator, #
    step     => \%sub_steps_by_id,
    data     => \%data,       # most recent JSON data payload, decoded
  }

Substeps may additionally have the keys:

    idx          => $order_of_declaration,   # useful for sorting
    title        => $name_of_this_step,
    contribution => $percent_of_parent_task, # can be undef

=head2 on_data

Optional coderef to handle JSON data discovered on input.  The return value
of this coderef will be stored in the L</data> field of the current step.

For example, you might want to combine all the data instead of overwriting it:

  my $parser= Log::Progress::Parser->new(
    on_data => sub {
      my ($parser, $step_id, $data)= @_;
      return Hash::Merge::merge( $parser->step_status($step_id), $data );
    }
  );

=cut

has input     => ( is => 'rw' );
has input_pos => ( is => 'rw' );
has status    => ( is => 'rw', default => sub { {} } );
has on_data   => ( is => 'rw' );

=head1 METHODS

=head2 parse

Read (any additional) L</input>, and return the L</state> field, or die trying.

  my $state= $parser->parse;

Sets L</input_pos> just beyond the end of the final complete line of text, so
that the next call to L</parse> can follow a growing log file.

=cut

sub parse {
	my $self= shift;
	my $fh= $self->input;
	if (!ref $fh) {
		my $input= $fh;
		undef $fh;
		open $fh, '<', \$input or die "open(scalar): $!";
	}
	if ($self->input_pos) {
		seek($fh, $self->input_pos, 0)
			or die "seek: $!";
	}
	# TODO: If input is seekable, then seek to end and work backward
	#  Substeps will make that rather complicated.
	my $pos;
	my %parent_cleanup;
	while (<$fh>) {
		last unless substr($_,-1) eq "\n";
		$pos= tell($fh);
		next unless $_ =~ /^progress: (([[:alpha:]][\w.]*) )?(.*)/;
		my ($step_id, $remainder)= ($2, $3);
		my $status= $self->step_status($step_id, 1, \my @status_parent);
		# First, check for progress number followed by optional message
		if ($remainder =~ m,^([\d.]+)(/(\d+))?( (.*))?,) {
			my ($num, $denom, $message)= ($1, $3, $5);
			$message= '' unless defined $message;
			$message =~ s/^- //; # "- " is optional syntax
			$status->{message}= $message;
			$status->{progress}= $num+0;
			if (defined $denom) {
				$status->{pos}= $num;
				$status->{max}= $denom;
				$status->{progress} /= $denom;
			}
			if ($status->{contribution}) {
				# Need to apply progress to parent nodes at end
				$parent_cleanup{$status_parent[$_]}= [ $_, $status_parent[$_] ]
					for 0..$#status_parent;
			}
		}
		elsif ($remainder =~ m,^\(([\d.]+)\) (.*),) {
			my ($contribution, $title)= ($1, $2);
			$title =~ s/^- //; # "- " is optional syntax
			$status->{title}= $title;
			$status->{contribution}= $contribution+0;
		}
		elsif ($remainder =~ /^\{/) {
			my $data= JSON->new->decode($remainder);
			$status->{data}= !defined $self->on_data? $data
				: $self->on_data->($self, $step_id, $data);
		}
		else {
			warn "can't parse progress message \"$remainder\"\n";
		}
	}
	# Mark file position for next call
	$self->input_pos($pos);
	# apply child progress contributions to parent nodes
	for (sort { $b->[0] <=> $a->[0] } values %parent_cleanup) {
		my $status= $_->[1];
		$status->{progress}= 0;
		for (values %{$status->{step}}) {
			$status->{progress} += $_->{progress} * $_->{contribution}
				if $_->{progress} && $_->{contribution};
		}
	}
	return $self->status;
}

=head2 step_status

  my $status= $parser->step_status($step_id, $create_if_missing);
  my $status= $parser->step_status($step_id, $create_if_missing, \@path_out);

Convenience method to traverse L</status> to get the data for a step.
If the second paramter is false, this returns undef if the step is not yet
defined.  Else it creates a new status node, with C<idx> initialized.

=cut

sub step_status {
	my ($self, $step_id, $create, $path)= @_;
	my $status= $self->status;
	my @status_parent;
	if (defined $step_id and length $step_id) {
		for (split /\./, $step_id) {
			push @status_parent, $status;
			$status= ($status->{step}{$_} or do {
				return undef unless $create;
				my $idx= scalar(keys %{$status->{step}});
				$status->{step}{$_}= { idx => $idx };
			});
		}
	}
	@$path= @status_parent if defined $path;
	$status;
}

1;
