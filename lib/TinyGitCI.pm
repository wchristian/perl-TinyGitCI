package TinyGitCI;

use Mojo::Base 'Mojolicious', -signatures;

use Mojo::Util 'dumper';
use curry;
use Git::FetchNewCommitIds 'fetch_new_commit_ids';
use App::Prove;
use Capture::Tiny qw' capture_merged tee_merged  ';
use Git::Wrapper;
use Mojo::File    qw' curfile path ';
use File::HomeDir ();
use Email::Simple;
use Email::Sender::Simple;
use Devel::Confess;
use Time::HiRes qw' sleep time ';
use IO::All -binary;
use Sys::SigAction 'timeout_call';

use TinyGitCI::Repo;

# ABSTRACT: watch a git repo's remote for changes and test them

# VERSION

=head1 SYNOPSIS

    $ cat ~/.tinygitci :
    {
        minion     =>     # db to use, pg has better support, see Minion::Backend::*
                          { mysql => 'mysql://tgci:tgci@xenwide/tgci' },
        secrets    =>     # app salt for encrypted cookies, csrf, etc. change to a random value
                          ['asdf'],
        repos       =>    # repositories to watch and test, string or hash
                          ["/path/to", {path=>"/path/to", remote => "outer"}],
        keep_files  =>    # regex to keep in the repositories between test runs
                          "etc/config.yml",
        fetch_secs => 60, # how often to check for new commits, defaults to 60
        email      => 'email_we_send_from@example.com',
    }
    $ tinygitci minion worker &  # this one grabs tasks and executes them
    $ tinygitci daemon &         # this one's the web interface

=cut

sub startup($self) {
	push @{ $self->renderer->paths }, curfile->sibling( __PACKAGE__, 'resources', 'templates' );

	$self->defaults( version => my $v = __PACKAGE__->VERSION || "<test>" );

	$self->log->debug( "version: $v - config file:" => my $cfg_file =
		  File::HomeDir::home . "/.tinygitci" );
	$self->plugin( Config => { file => $cfg_file } )
	  if not keys %{ $self->config };
	my $c = $self->config;
	die "no config, create $cfg_file" if not keys %{$c};
	$self->secrets( $c->{secrets} || die "config is missing secrets" );
	$self->plugin( Minion => $c->{minion} || die "no config: minion" );
	$self->plugin("Minion::Admin");
	$_ = TinyGitCI::Repo->new($_) for @{ $self->config->{repos} };
	die "no repos configured in $cfg_file" if not @{ $self->config->{repos} };

	my $r = $self->routes;
	$r->get('/')->to('testruns#index')->name('index');
	$r->get('/testruns/:id')->to('testruns#result')->name('result');

	my $m = $self->minion;
	$m->add_task( $_ => $self->curry::_($_) )
	  for qw( queue_repo_fetch_task fetch_new_commit_id_task test_commit_id_task send_email_task );

	Mojo::IOLoop->recurring    #
	  ( ( $c->{fetch_secs} || 60 ), $m->curry::enqueue( "queue_repo_fetch_task", undef, undef ) )
	  if not $ENV{TEST_ONLINE};
	return;
}

sub queue_repo_fetch_task ( $self, $job ) {
	my $m = $self->minion;
	return $self->reschedule( $job, "Previous commit id fetch is still active" ) unless    #
	  my $guard = $m->guard( queue_repo_fetch_task => 86400 );
	my @queued;
	for my $repo ( @{ $self->config->{repos} } ) {
		next if $m->is_locked( "fetch_new_commit_id_task" . $repo->path );
		next if $m->is_locked( "test_commit_id_task" . $repo->path );
		push @queued, $m->enqueue( fetch_new_commit_id_task => [ $repo->path, $repo->remote ] );
	}
	return $job->finish( "done, queued: " . @queued );
}

sub fetch_new_commit_id_task ( $self, $job, $repo, $remote ) {
	my $m = $self->minion;
	return $self->reschedule( $job, "Previous commit id fetch is still active" ) unless    #
	  my $guard = $m->guard( "fetch_new_commit_id_task$repo" => 86400 );
	return $self->reschedule( $job, "Test run still active" )
	  if $m->is_locked("test_commit_id_task$repo");

	chdir $repo or die "cannot chdir to $repo";
	my @commits = fetch_new_commit_ids( Git::Wrapper->new($repo), $remote );
	my @ids     = map $m->enqueue( test_commit_id_task => [ $repo, $_ ] ), @commits;
	return $job->finish("done, queued: @ids");
}

sub test_commit_id_task( $self, $job, $repo, $commit_id ) {
	my $m = $self->minion;
	my @l;
	return $self->reschedule( $job, "Previous test run is still active" )
	  if not $self->guard( \@l, $job, "test_commit_id_task$repo" => 86400 );
	$self->update_log( $job, \@l, "guard allowed, running job" );

	$job->note( test_log   => [] );
	$job->note( last_state => "start" );
	my ($test_log) = capture_merged {
		chdir $repo or die "cannot chdir to $repo";
		$job->note( last_state => "changed dir" );
		my $git = Git::Wrapper->new($repo);
		$git->checkout($commit_id);
		my $c = $self->config;
		$git->clean( { d => 1, f => 1, x => 1, ( e => $c->{keep_files} ) x !!$c->{keep_files} } );
		$job->note( last_state => "checked out commit" );
		$ENV{HARNESS_VERBOSE} = $ENV{AUTOMATED_TESTING} = $ENV{PERL_MM_USE_DEFAULT} = 1;
		$job->note( last_state => "cleaned" );
		my $test_call =
		  qq[perl -e 'use CPAN; CPAN::Index->reload; CPAN::clean("."); CPAN::install(".")'];
		print "timed out\n" if timeout_call 30, sub { system $test_call };
		$job->note( last_state => "installed" );
	};
	$job->note( test_log => [ split /\n/, $test_log ] );
	my ( $meth, $res ) = ( $test_log =~ /Result: FAIL/ )    #
	  ? qw( finish PASS ) : qw( fail FAIL );
	$m->enqueue( send_email_task => [ $repo, $res, $test_log, $commit_id ] );
	$job->$meth($res);
	$self->update_log( $job, \@l, "guard unlocking" );
	$m->unlock("test_commit_id_task$repo");
	$self->update_log( $job, \@l, "guard unlocked" );
	return;
}

sub send_email_task( $self, $job, $repo, $res, $text, $commit_id,
	$email = $self->config->{email} || die "no email" )
{
	my ($commit)  = Git::Wrapper->new($repo)->RUN( "show", "-s", '--format=%h : %s', $commit_id );
	my $title     = "TinyGitCI result for $repo - $res - $commit";
	my $email_obj = Email::Simple                                                                  #
	  ->create( header => [ To => $email, From => $email, Subject => $title ], body => $text );
	die "error with email:\n" . dumper($email_obj) . "\n$@"
	  unless eval { Email::Sender::Simple->send($email_obj); 1 };
	return $job->finish;
}

sub reschedule ( $self, $job, $msg ) {
	$job->note( reschedule_reason => $msg );
	$job->retry( { delay => 60 } );
	return;
}

# all of this is necessary because: 1. workers run in separate processes
# 2. sqlite seems to allow lock attempts to pass each other by
#    https://metacpan.org/dist/Minion-Backend-SQLite/source/lib/Minion/Backend/SQLite.pm#L217
# 3. the guard function does not return the id of the created guard
sub guard ( $self, $l, $j, $name, $duration ) {
	$self->update_log( $j, $l, "guard start" );
	my $m = $self->minion;
	return if $m->is_locked($name);    # allow blocked tasks to exit eary to not pollute ui
	$self->update_log( $j, $l, "guard first log check passed" );
	sleep 5 * rand;                    # make similarly scheduled tasks less likely to collide
	return if $m->is_locked($name);
	$self->update_log( $j, $l, "guard second log check passed post sleep" );
	my $real_duration    = $duration + int( 256 * rand ); # randomize expiry so it can be recognized
	my $expected_expires = time + $real_duration;
	return if not $m->lock( $name => $real_duration );
	$self->update_log( $j, $l, "guard object acquired" );
	sleep 1;    # make sure we don't miss interference from other tasks
	my $locks = $m->backend->list_locks( 0, 2, { names => [$name] } )->{locks};
	return if @{$locks} != 1;    # should be exactly 1 lock
	$self->update_log( $j, $l, "guard count == 1" );
	$self->update_log( $j, $l, "guard expiry real: $locks->[0]{expires}, exp: $expected_expires" );
	return if abs( $locks->[0]{expires} - $expected_expires ) > 3; # big diff => lock for wrong task
	$self->update_log( $j, $l, "guard expiry looks reasonable" );
	return 1;                                                      # *probably* correct lock
}

sub update_log( $self, $job, $job_log, $msg ) {
	push @{$job_log}, my $log_line = "[" . time . "] " . $job->id . " $msg";
	$job->note( job_log => $job_log );
	io("/tmp/tgci_worker.log")->append("$log_line\n");
	return;
}

1;
