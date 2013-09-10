package AnyEvent::Git::Wrapper;

use strict;
use warnings;
use Carp qw( croak );
use base qw( Git::Wrapper );
use File::pushd;
use AnyEvent;
use AnyEvent::Open3::Simple;
use Git::Wrapper::Exception;
use Git::Wrapper::Statuses;
use Git::Wrapper::Log;

# ABSTRACT: Wrap git command-line interface without blocking
# VERSION

=head1 SYNOPSIS

 use AnyEvent::Git::Wrapper;
 
 # add all files and make a commit...
 my $git = AnyEvent::Git::Wrapper->new($dir);
 $git->add('.', sub {
   $git->commit({ message => 'initial commit' }, sub {
     say "made initial commit";
   });
 });

=head1 DESCRIPTION

This module provides a non-blocking and blocking API for git in the style and using the data 
structures of L<Git::Wrapper>.  For methods that execute the git binary, if the last argument is 
either a code reference or an L<AnyEvent> condition variable, then the command is run in 
non-blocking mode and the result will be sent to the condition variable when the command completes.  
For most commands (all those but C<status>, C<log> and C<version>), the result comes back via the 
C<recv> method on the condition variable as two array references, one representing the standard out 
and the other being the standard error.  Because C<recv> will return just the first value if 
called in scalar context, you can retrieve just the output by calling C<recv> in scalar context.

 # ignoring stderr
 $git->branch(sub {
   my $out = shift->recv;
   foreach my $line (@$out)
   {
     ...
   }
 });
 
 # same thing, but saving stderr
 $git->branch(sub {
   my($out, $err) = shit->recv;
   foreach my $line(@$out)
   {
     ...
   }
 });

Like L<Git::Wrapper>, you can also access the standard output and error via the C<OUT> and C<ERR>, but care
needs to be taken that you either save the values immediately if other commands are being run at the same
time.

 $git->branch(sub {
   my $out = $git->OUT;
   foreach my $line (@$out)
   {
     ...
   }
 });

If git signals an error condition the condition variable will croak, so you will need to wrap your call
to C<recv> in an eval if you want to handle it:

 $git->branch(sub {
   my $out = eval { shift->recv };
   if($@)
   {
     warn "error: $@";
     return;
   }
   ...
 });

=head1 METHODS

=head2 $git-E<gt>RUN($command, [ @arguments ], [ $callback | $condvar ])

Run the given git command with the given arguments (see L<Git::Wrapper>).  If the last argument is
either a code reference or a condition variable then the command will be run in non-blocking mode
and a condition variable will be returned immediately.  Otherwise the command will be run in 
normal blocking mode, exactly like L<Git::Wrapper>.

If you provide this method with a condition variable it will use that to send the results of the
command.  If you provide a code reference it will create its own condition variable and attach
the code reference  to its callback.  Either way it will return the condition variable.

=cut

sub RUN
{
  my($self) = shift;
  my $cv;
  if(ref($_[-1]) eq 'CODE')
  {
    $cv = AE::cv;
    $cv->cb(pop);
  }
  elsif(eval { $_[-1]->isa('AnyEvent::CondVar') })
  {
    $cv = pop;
  }
  else
  {
    return $self->SUPER::RUN(@_);
  }

  my $cmd = shift;

  my $in;  
  my @out;
  my @err;
  
  my $ipc = AnyEvent::Open3::Simple->new(
    on_start  => sub {
      my($proc) = @_;
      $proc->print($in) if defined $in;
      $proc->close;
    },
    on_stdout => \@out,
    on_stderr => \@err,
    on_error  => sub {
      my($error) = @_;
      $cv->croak(
        Git::Wrapper::Exception->new(
          output => \@out,
          error  => \@err,
          status => -1,
        )
      );
    },
    on_exit   => sub {
      my($proc, $exit, $signal) = @_;
      
      # borrowed from superclass, see comment there
      my $stupid_status = $cmd eq 'status' && @out && ! @err;
      
      if(($exit || $signal) && ! $stupid_status)
      {
        $cv->croak(
          Git::Wrapper::Exception->new(
            output => \@out,
            error  => \@err,
            status => $exit,
          )
        );
      }
      else
      {
        $self->{err} = \@err;
        $self->{out} = \@out;
        $cv->send(\@out, \@err);
      }
    },
  );
  
  do {
    my $d = pushd $self->dir unless $cmd eq 'clone';
    
    my $parts;
    ($parts, $in) = Git::Wrapper::_parse_args( $cmd, @_ );
    my @cmd = ( $self->git, @$parts );
    
    local $ENV{GIT_EDITOR} = '';
    $ipc->run(@cmd);
  };
  
  $cv;
}

=head2 $git-E<gt>status( [@args ], [ $coderef | $condvar ] )

If called in blocking mode (without a code reference or condition variable as the last argument),
this method works exactly as with L<Git::Wrapper>.  If run in non blocking mode, the Git::Wrapper::Statuses
object will be passed back via the C<recv> method on the condition variable.

 # with a code ref
 $git->status(sub {
   my $statuses = shift->recv;
   ...
 });
 
 # with a condition variable
 my $cv = $git->status(AE::cv)
 $cv->cb(sub {
   my $statuses = shift->recv;
   ...   
 });

=cut

my %STATUS_CONFLICTS = map { $_ => 1 } qw<DD AU UD UA DU AA UU>;

sub status
{
  my($self) = shift;
  my $cv;
  if(ref($_[-1]) eq 'CODE')
  {
    $cv = AE::cv;
    $cv->cb(pop);
  }
  elsif(eval { $_[-1]->isa('AnyEvent::CondVar') })
  {
    $cv = pop;
  }
  else
  {
    return $self->SUPER::status(@_);
  }

  my $opt = ref $_[0] eq 'HASH' ? shift : {};
  $opt->{porcelain} = 1;

  $self->RUN('status' => $opt, @_, sub {
    my $out = shift->recv;
    my $stat = Git::Wrapper::Statuses->new;

    for(@$out)
    {
      my ($x, $y, $from, $to) = $_ =~ /\A(.)(.) (.*?)(?: -> (.*))?\z/;
      if ($STATUS_CONFLICTS{"$x$y"})
      {
        $stat->add('conflict', "$x$y", $from, $to);
      }
      elsif ($x eq '?' && $y eq '?')
      {
        $stat->add('unknown', '?', $from, $to);
      }
      else
      {
        $stat->add('changed', $y, $from, $to)
          if $y ne ' ';
        $stat->add('indexed', $x, $from, $to)
          if $x ne ' ';
      }
    }
    
    $cv->send($stat);
  });
  
  $cv;
}

=head2 $git-E<gt>log( [ @args ], [ $callback | $condvar )

In blocking mode works just like L<Git::Wrapper>.  With a code reference or condition variable it runs in
blocking mode and the list of L<Git::Wrapper::Log> objects is returned via the condition variable.

 # to get the whole log:
 $git->log(sub {
   my @logs = shift->recv;
 });
 
 # to get just the first line:
 $git->log('-1', sub {
   my $log = shift->recv;
 });

=cut

sub log
{
  my($self) = shift;
  my $cv;
  if(ref($_[-1]) eq 'CODE')
  {
    $cv = AE::cv;
    $cv->cb(pop);
  }
  elsif(eval { $_[-1]->isa('AnyEvent::CondVar') })
  {
    $cv = pop;
  }
  else
  {
    return $self->SUPER::log(@_);
  }
  
  my $opt = ref $_[0] eq 'HASH' ? shift : {};
  $opt->{no_color}         = 1;
  $opt->{pretty}           = 'medium';
  $opt->{no_abbrev_commit} = 1
    if $self->supports_log_no_abbrev_commit;
  
  my $raw = defined $opt->{raw} && $opt->{raw};
  
  $self->RUN(log => $opt, @_, sub {
    my $out = shift->recv;
    
    my @logs;
    while(my $line = shift @$out) {
      unless($line =~ /^commit (\S+)/)
      {
        $cv->croak("unhandled: $line");
        return;
      }
      
      my $current = Git::Wrapper::Log->new($1);
      
      $line = shift @$out;  # next line
      
      while($line =~ /^(\S+):\s+(.+)$/)
      {
        $current->attr->{lc $1} = $2;
        $line = shift @$out; # next line
      }
      
      if($line)
      {
        $cv->croak("no blank line separating head from message");
        return;
      }
      
      my($initial_indent) = $out->[0] =~ /^(\s*)/ if @$out;
      
      my $message = '';
      while(@$out and $out->[0] !~ /^commit (\S+)/ and length($line = shift @$out))
      {
        $line =~ s/^$initial_indent//; # strip just the indenting added by git
        $message .= "$line\n";
      }
      
      $current->message($message);
      
      if($raw)
      {
        my @modifications;
        while(@$out and $out->[0] =~ m/^\:(\d{6}) (\d{6}) (\w{7})\.\.\. (\w{7})\.\.\. (\w{1})\t(.*)$/)
        {
          push @modifications, Git::Wrapper::File::RawModification->new($6,$5,$1,$2,$3,$4);
          shift @$out;
        }
        $current->modifications(@modifications) if @modifications;
      }
      
      push @logs, $current;
    }
    
    $cv->send(@logs);
  });
  
  $cv;
}

=head2 $git-E<gt>version( [ $callback | $condvar ] )

In blocking mode works just like L<Git::Wrapper>.  With a code reference or condition variable it runs in
blocking mode and the version is returned via the condition variable.

 # cod ref
 $git->version(sub {
   my $version = shift->recv;
   ...
 });
 
 # cond var
 my $cv = $git->version(AE::cv);
 $cv->cb(sub {
   my $version = shift->recv;
   ...
 });

=cut

sub version
{
  my($self) = @_;
  my $cv;
  if(ref($_[-1]) eq 'CODE')
  {
    $cv = AE::cv;
    $cv->cb(pop);
  }
  elsif(eval { $_[-1]->isa('AnyEvent::CondVar') })
  {
    $cv = pop;
  }
  else
  {
    return $self->SUPER::version(@_);
  }
  
  $self->RUN('version', sub {
    my $out = eval { shift->recv };
    if($@)
    {
      $cv->croak($@);
    }
    else
    {
      my $version = $out->[0];
      $version =~ s/^git version //;
      $cv->send($version);
    }
  });
  
  $cv;
}

=head1 CAVEATS

This module necessarily uses the private _parse_args method from L<Git::Wrapper>, so changes
to that module may break this one.  Also, some functionality is duplicated because there
isn't a good way to hook into just parts of the commands that this module overrides.  The
author has made a good faith attempt to reduce the amount of duplication.

You probably don't want to be doing multiple git write operations at once (strange things are
likely to happen), but you may want to do multiple git read operations or mix git and other
L<AnyEvent> operations at once.

=head1 BUNDLED FILES

In addition to inheriting from L<Git::Wrapper>, this distribution includes tests that come
with L<Git::Wrapper>, and are covered by this copyright:

This software is copyright (c) 2008 by Hand Dieter Pearcey.

This is free software you can redistribute it and/or modify it under the same terms as the Perl 5
programming language system itself.

Thanks also to Chris Prather and John SJ Anderson for their work on L<Git::Wrapper>.

=cut

1;
