package Log::Progress;
use Moo 2;
use Carp;
use IO::Handle; # for 'autoflush'
use JSON;

our $VERSION= '0.00_01';

# ABSTRACT: Conveniently write progress messages to logger or file handle

=head1 DESCRIPTION

This module assists with writing the Log::Progress protocol, which can then
be parsed with the Log::Progress::Parser.  It can write to file handles, log
objects (like Log::Any), a coderef, or any object with a "print" method.

Note that this module enables autoflush if you give it a file handle.

=head1 SYNOPSIS

  my $p= Log::Progress->new(to => \*STDERR); # The default
  $p->squelch(.1); # only emit messages every 10%
  my $max= 1000;
  for (my $i= 0; $i < $max; $i++) {
    # do the thing
    ...;
    $p->progress(($i+1)/$max);
    # -or-
    $p->progress_ratio($i+1, $max);
  }

=head1 ATTRIBUTES

=head2 to

The destination for progress messages.  \*STDERR is the default.
You can pass any file handle or handle-like object with a C<print> method,
Logger object with C<info> method, or a custom coderef.

=over

=item File Handle (or object with C<print> method)

The C<print> method is used, and passed a single newline-terminated string.

If the object also has a method C<autoflush>, this module calls it
before writing any messages.  (to avoid that behavior, use a coderef instead)

=item Logger object (with C<info> method)

The progress messages are passed to the C<info> method, without a terminating
newline.

=item coderef

The progress messages are passed as the only argument, without a terminating
newline.  The return value becomes the return value of the call to L</progress>
and should probably be a boolean to match behavior of C<<$handle->print>>.

  sub { my ($progress_message)= @_; ... }

=back

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
(but you can un-define it to restore that behavior)

=head2 squelch

You can prevent spamming your log file with tiny progress updates using
"squelch", which limits progress messages to one per some fraction of overall
progress.  For example, the default squelch of .01 will only emit at most 101
progress messages.  (unless you start reporting negative progress)

If you set squelch but not precision, the second will use a sensible default.
See example in L</precision>

Once set, squelch will not receive a default value from changing precision.
(but you can un-define it to restore that behavior)

=head2 step_id

If this object is reporting the progress of a sub-step, set this ID to
the step name.

The default value for this field comes from C<$ENV{PROGRESS_STEP_ID}>, so that
programs that perform simple progress reporting can be nested as child
processes of a larger job without having to specifically plan for that ability
in the child process.

=cut

has to         => ( is => 'rw', isa => \&_assert_valid_output, default => sub { \*STDERR },
                    trigger => sub { delete $_[0]{_writer} } );
sub squelch    {
	my $self= shift;
	if (@_) { $self->_squelch(shift); $self->_calc_precision_squelch() }
	$self->{squelch};
}
sub precision  {
	my $self= shift;
	if (@_) { $self->_precision(shift); $self->_calc_precision_squelch() }
	$self->{precision};
}
has step_id    => ( is => 'rw', default => sub { $ENV{PROGRESS_STEP_ID} },
                    trigger => sub { delete $_[0]{_writer} } );

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
		defined $precision or $precision= int(log(1/$squelch)/log(10) + .99999);
		defined $squelch or $squelch= 1/(10**$precision);
	}
	$self->{squelch}= $squelch;
	$self->{precision}= $precision;
}

sub _assert_valid_output {
	my $to= shift;
	my $type= ref $to;
	$type && (
		$type eq 'GLOB'
		or $type eq 'CODE'
		or $type->can('print')
		or $type->can('info')
	) or die "$to is not a file handle, logger object, or code reference";
}

sub _build__writer {
	my $self= shift;
	
	my $prefix= "progress: ".(defined $self->step_id? $self->step_id.' ' : '');
	my $to= $self->to;
	my $type= ref $to;
	$to->autoflush(1) if $type eq 'GLOB' or $type->can('autoflush');
	return ($type eq 'GLOB')? sub { print $to $prefix.join('', @_)."\n"; }
		:  ($type eq 'CODE')? sub { $to->($prefix.join('', @_)); }
		:  ($type->can('print'))? sub { $to->print($prefix.join('', @_)."\n"); }
		:  ($type->can('info'))? sub { $to->info($prefix.join('', @_)); }
		: die "unhandled case";
}

=head1 METHODS

=head2 progress

  $p->progress( $current, $maximum );
  $p->progress( $current, $maximum, $message );

Report progress (but only if the progress since the last output is greater
than L<squelch>).  Message is optional.

If C<$maximum> is undefined or exactly '1', then this will print C<$current>
as a formatted decimal.  Otherwise it prints the fraction of C<$current>/C<$maximum>.
When using fractional form, the decimal precision is omitted if C<$current> is
a whole number.

=cut

sub progress {
	my ($self, $current, $maximum, $message)= @_;
	$maximum= 1 unless defined $maximum;
	my $progress= $current / $maximum;
	my $sq= $self->squelch;
	my $formatted= sprintf("%.*f", $self->precision, int($progress/$sq + .0000000001)*$sq);
	return if defined $self->_last_progress
	      and abs($formatted - $self->_last_progress)+.0000000001 < $sq;
	$self->_last_progress($formatted);
	if ($maximum != 1) {
		$formatted= (int($current) == $current)? "$current/$maximum"
			: sprintf("%.*f/%d", $self->precision, $current, $maximum);
	}
	$self->_writer->($formatted . ($message? " - $message":''));
}

=head2 data

If you want to write any progress-associated data, use this method.
The data must be a hashref.

=cut

sub data {
	my ($self, $data)= @_;
	ref $data eq 'HASH' or croak "data must be a hashref";
	$self->_writer->(JSON->new->encode($data));
}

=head2 substep

  $progress_obj= $progress->substep( $id, $contribution, $title );

Create a named sub-step progress object, and declare it on the output.

C<$id> and C<$title> are required.  The C<$contribution> rate (a multiplier
for applying the sub-step's progress to the parent progress bar) is
recommended but not required.

Note that the sub-step gets declared on the output stream each time you call
this method, but it isn't harmful to do so multiple times for the same step.

=cut

sub substep {
	my ($self, $step_id, $step_contribution, $title)= @_;
	length $title or croak "sub-step title is required";
	
	$step_id= $self->step_id . '.' . $step_id
		if defined $self->step_id and length $self->step_id;
	
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
