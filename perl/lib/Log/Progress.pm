package Log::Progress;
use Moo 2;
use JSON;

=head1 DESCRIPTION

This module assists with writing the Log::Progress protocol, which can then
be parsed with the Log::Progress::Parser

This module either writes to STDOUT, STDERR, Log::Any, or an anonymous sub
of your choice.

=head1 SYNOPSIS

  my $p= Log::Progress->new(to => \*STDERR); # The default
  $p->squelch(.1); # only emit messages every 10%
  my $max= 1000;
  for (my $i= 0; $i < $max; $i++) {
    # do the thing
    ...;
    $p->progress(($i+1)/$max);
  }

=head1 ATTRIBUTES

=head2 to

The destination for progress messages.  \*STDERR is the default.
You can pass any file handle, coderef, or object with a 'info' method.

=head2 precision

The progress number is written as text, with L</precision> digits after the
decimal point.  The default precision is 2.  This default corresponds with a
default L</squelch> of 0.01, so that calls to ->progress with less than 1%
change from the previous call are suppressed.

If you set precision but not squelch, the second will use a default to match
the one you specified.  For example, setting a precision of 5 results in a
default squelch of .00001, or a default squelch of 350 results in a precision
of 3.

Once set, precision will not receive a default value from changes to squelch.
(but you can un-define it)

=head2 squelch

You can prevent spamming your log file with tiny progress updates using
"squelch", which limits progress messages to one per some fraction of overall
progress.  For example, the default squelch of .01 will only emit at most 101
progress messages.  (unless you start reporting negative progress)

If you set squelch but not precision, the second will use a sensible default.
See example in L</precision>

Once set, squelch will not receive a default value from changing precision.
(but you can un-define it)

=head2 step_id

If this object is reporting the progress of a sub-step, set this ID to
the step name.

=cut

has to        => ( is => 'rw', default => sub { \*STDERR }, trigger => sub { delete $_[0]{_writer} } );
sub squelch   {
	my $self= shift;
	if (@_) { $self->_squelch(shift); $self->_calc_precision_squelch() }
	$self->{squelch};
}
sub precision {
	my $self= shift;
	if (@_) { $self->_precision(shift); $self->_calc_precision_squelch() }
	$self->{precision};
}
has step_id   => ( is => 'rw', trigger => sub { delete $_[0]{_writer} } );

has _writer    => ( is => 'lazy' );
has _squelch   => ( is => 'rw', init_arg => 'squelch' );
has _precision => ( is => 'rw', init_arg => 'precision' );
has _last_progress => ( is => 'rw' );

sub BUILD {
	shift->_calc_precision_squelch();
}

sub _calc_precision_squelch {
	my $self= shift;
	my $squelch= $self->_squelch;
	my $precision= $self->_precision;
	if (!defined $squelch && !defined $precision) {
		$squelch= .01;
		$precision= 2;
	} else {
		# calculation for digit length of number of steps
		$precision //= int(log(1/$squelch)/log(10) + .99999);
		$squelch //= 1/(10**$precision);
	}
	$self->{squelch}= $squelch;
	$self->{precision}= $precision;
}

sub _build__writer {
	my $self= shift;
	
	my $prefix= "progress: ".(defined $self->step_id? $self->step_id.' ' : '');
	my $to= $self->to;
	my $type= ref $to;
	return ($type eq 'GLOB')? sub { print $to $prefix.join('', @_)."\n"; }
		:  ($type eq 'CODE')? sub { $to->($prefix.join('', @_)); }
		:  ($type->can('print'))? sub { $to->print($prefix.join('', @_)."\n"); }
		:  ($type->can('info'))? sub { $to->info($prefix.join('', @_)); }
		: die "'to' must be a file handle, coderef, or logger object";
}

sub progress {
	my ($self, $progress, $message)= @_;
	$progress= 1 if $progress > 1;
	$progress= 0 if $progress < 0;
	my $w= $self->_writer; # Do this first to refresh cache if needed
	my $sq= $self->squelch;
	my $formatted= sprintf("%.*f", $self->precision, int($progress/$sq + .0000000001)*$sq);
	return if defined $self->_last_progress
	      and abs($formatted - $self->_last_progress)+.0000000001 < $sq;
	$self->_last_progress($formatted);
	$w->($formatted . ($message? " - $message":''));
}

sub progress_ratio {
	my ($self, $num, $denom, $message)= @_;
	$self->progress($num/$denom, "($num/$denom)".($message? " $message":''));
}

sub substep {
	my ($self, $step_id, $step_contribution, $title)= @_;
	$step_id= $self->step_id . '.' . $step_id
		if length($self->step_id//'');
	
	my $sub_progress= ref($self)->new(
		to        => $self->to,
		squelch   => $self->_squelch,
		precision => $self->_precision,
		step_id   => $step_id,
	);
	
	if ($step_contribution) {
		$sub_progress->_writer->(sprintf("(%.*f) %s", $self->precision, $step_contribution, $title));
	} else {
		$sub_progress->_writer->("- $title");
	}
	
	return $sub_progress;
}

1;
