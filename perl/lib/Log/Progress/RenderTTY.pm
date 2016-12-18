package Log::Progress::RenderTTY;
use Moo 2;
use Carp;
use Try::Tiny;
use Log::Progress::Parser;
use Term::Cap;
use Scalar::Util;

has listen_resize  => ( is => 'ro' );
has tty_metrics    => ( is => 'lazy', clearer => 1 );
has termcap        => ( is => 'lazy' );
has parser         => ( is => 'rw' );
has _prev_output   => ( is => 'rw' );
has _winch_handler => ( is => 'rw' );

sub _build_tty_metrics {
	my $self= shift;
	my $stty= `stty -a` or croak("unable to run 'stty -a' to fetch terminal size");
	my ($speed)= ($stty =~ /speed[ =]+(\d+)/);
	my ($cols)=  ($stty =~ /columns[ =]+(\d+)/);
	my ($rows)=  ($stty =~ /rows[ =]+(\d+)/);
	$self->_init_window_change_watch() if $self->listen_resize;
	return { speed => $speed, cols => $cols, rows => $rows };
}

sub _build_termcap {
	my $self= shift;
	my $speed= $self->tty_metrics->{speed} || 9600;
	return Tgetent Term::Cap { TERM => '', OSPEED => $speed };
}

sub _init_window_change_watch {
	my $self= shift;
	try {
		my $existing= $SIG{WINCH};
		Scalar::Util::weaken($self);
		my $handler= sub {
			$self->clear_tty_metrics if defined $self;
			goto $existing if defined $existing;
		};
		$self->_winch_handler([ $handler, $existing ]);
		$SIG{WINCH}= $handler;
	}
	catch {
		warn "Can't install SIGWINCH handler\n";
	};
}

sub format {
	my ($self, $state, $dims)= @_;
	
	# Build the new string of progress ascii art, but without terminal escapes
	my $str= '';
	$dims->{message_margin}= $dims->{cols} * .5;
	if ($state->{step}) {
		$dims->{title_width}= 10;
		for (values %{ $state->{step} }) {
			$dims->{title_width}= length($_->{title})
				if length($_->{title} || '') > $dims->{title_width};
		}
		for (sort { $a->{idx} <=> $b->{idx} } values %{ $state->{step} }) {
			$str .= $self->_format_step_progress_line($_, $dims);
		}
		$str .= "\n";
	}
	$str .= $self->_format_main_progress_line($state, $dims);
	return $str;
}

sub render {
	my $self= shift;
	my ($cols, $rows)= @{ $self->tty_metrics }{'cols','rows'};
	my $output= $self->format($self->parser->parse, {
		cols => $cols,
		rows => $rows
	});
	
	# Now the fun part.  Diff vs. previous output to figure out which lines (if any)
	# have changed, then move the cursor to those lines and repaint.
	# To make things extra interesting, the old output might have scrolled off the
	# screen, and if the new output also scrolls off the screen then we want to
	# let it happen naturally so that the scroll-back buffer is consistent.
	my @prev= defined $self->_prev_output? (split /\n/, $self->_prev_output, -1) : ();
	my @next= split /\n/, $output, -1;
	# we leave last line blank, so all calculations are rows-1
	my $first_vis_line= @prev > ($rows-1)? @prev - ($rows-1) : 0;
	my $starting_row= @prev > ($rows-1)? 0 : ($rows-1) - @prev;
	my $up= $self->termcap->Tputs('up');
	my $down= $self->termcap->Tputs('do');
	my $clear_eol= $self->termcap->Tputs('ce');
	my $str= '';
	my $cursor_row= $rows-1;
	my $cursor_seek= sub {
		my $dest_row= shift;
		if ($cursor_row > $dest_row) {
			print STDERR "up ".($cursor_row - $dest_row)."\n";
			$str .= $up x ($cursor_row - $dest_row);
		} elsif ($dest_row > $cursor_row) {
			print STDERR "down ".($dest_row - $cursor_row)."\n";
			$str .= $down x ($dest_row - $cursor_row);
		}
		$cursor_row= $dest_row;
	};
	my $i;
	for ($i= $first_vis_line; $i < @prev; $i++) {
		if ($prev[$i] ne $next[$i]) {
			# Seek to row
			$cursor_seek->($i - $first_vis_line + $starting_row);
			# clear line and replace
			print STDERR "print line $i: $next[$i]\n";
			$str .= $clear_eol . $next[$i] . "\n";
			$cursor_row++;
		}
	}
	$cursor_seek->($rows-1);
	# Now, print any new rows in @next, letting them scroll the screen as needed
	while ($i < @next) {
		print STDERR "print line $i, (wrap bottom): $next[$i]\n";
		$str .= $next[$i++] . "\n";
	}
	$self->_prev_output($output);
	
	print $str;
}

sub _format_main_progress_line {
	my ($self, $state, $dims)= @_;
	
	my $message= $state->{message};
	$message= '' unless defined $message;
	$message= sprintf("(%d/%d) %s", $state->{current}, $state->{total}, $message)
		if defined $state->{total} and defined $state->{current};
	
	my $max_chars= $dims->{cols} - 8;
	return sprintf "[%-*s] %3d%%\n",
		$max_chars, '=' x int( ($state->{progress}||0) * $max_chars + .000001 ),
		int( ($state->{progress}||0) * 100 + .0000001 ),
		$dims->{cols}, $message;
}

sub _format_step_progress_line {
	my ($self, $state, $dims)= @_;
	
	my $message= $state->{message};
	$message= '' unless defined $message;
	$message= sprintf("(%d/%d) %s", $state->{current}, $state->{total}, $message)
		if defined $state->{total} and defined $state->{current};
	
	my $max_chars= $dims->{cols} - $dims->{message_margin} - $dims->{title_width} - 11;
	return sprintf "  %-*.*s [%-*s] %3d%% %.*s\n",
		$dims->{title_width}, $dims->{title_width}, $_->{title},
		$max_chars, '=' x int( ($state->{progress}||0) * $max_chars + .000001 ),
		int( ($state->{progress}||0) * 100 + .000001 ),
		$dims->{message_margin}, $message;
}

sub DESTROY {
	my $self= shift;
	if ($self->_winch_handler) {
		if ($SIG{WINCH} eq $self->_winch_handler->[0]) {
			$SIG{WINCH}= $self->_winch_handler->[1];
		} else {
			warn "Can't uninstall SIGWINCH handler\n";
		}
		$self->_winch_handler(undef);
	}
}

1;
