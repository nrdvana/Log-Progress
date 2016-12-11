package Log::Progress::Parser;
use Moo 2;
use JSON;

has input     => ( is => 'rw' );
has input_pos => ( is => 'rw' );
has status    => ( is => 'rw', default => sub { {} } );

sub parse {
	my $self= shift;
	my $fh= $self->input;
	if (!ref $fh) {
		my $input= $fh;
		undef $fh;
		open $fh, '<', \$input or die;
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
		my $status= $self->status;
		my @status_parent;
		if (defined $step_id) {
			for (split /\./, $step_id) {
				push @status_parent, $status;
				$status= ($status->{step}{$_} //= { idx => scalar(keys %{$status->{step}}) - 1 });
			}
		}
		# First, check for progress number followed by optional message
		if ($remainder =~ m,^([\d.]+)(/(\d+))?( (.*))?,) {
			my ($num, $denom, $message)= ($1, $3, $5);
			$message =~ s/^- // if defined $message; # "- " is optional syntax
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
			$status->{data}= JSON->new->decode($remainder);;
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
			$status->{progress} += $_->{progress} * $_->{contribution};
		}
	}
}

1;
