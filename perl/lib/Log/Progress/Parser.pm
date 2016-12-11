package Log::Progress::Parser;
use Moo 2;
use JSON;

has input  => ( is => 'rw' );
has status => ( is => 'rw' );

sub parse {
	my $self= shift;
	$self->status({});
	my $fh= $self->input;
	if (!ref $fh) {
		my $input= $fh;
		undef $fh;
		open $fh, '<', \$input or die;
	}
	# TODO: If input is seekable, then seek to end and work backward
	#  Substeps will make that rather complicated.
	while (<$fh>) {
		next unless $_ =~ /^progress: (([[:alpha:]][\w.]*) )?(.*)/;
		my ($step_id, $remainder)= ($2, $3);
		my $status= $self->status;
		if (defined $step_id) {
			$status= ($status->{step}{$_} //= {})
				for split /\./, $step_id;
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
}

1;
