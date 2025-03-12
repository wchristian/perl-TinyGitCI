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
		next if not $m->guard( "fetch_new_commit_id_task" . $repo->path => 86400 );
		next if not $m->guard( "test_commit_id_task" . $repo->path      => 86400 );
		push @queued, $m->enqueue( fetch_new_commit_id_task => [ $repo->path, $repo->remote ] );
	}
	return $job->finish( "done, queued: " . @queued );
}

sub fetch_new_commit_id_task ( $self, $job, $repo, $remote ) {
	my $m = $self->minion;
	return $self->reschedule( $job, "Previous commit id fetch is still active" ) unless    #
	  my $guard = $m->guard( "fetch_new_commit_id_task$repo" => 86400 );
	return $self->reschedule( $job, "Test run still active" ) unless                       #
	  $m->guard( "test_commit_id_task$repo" => 86400 );

	chdir $repo or die "cannot chdir to $repo";
	my @commits = fetch_new_commit_ids( Git::Wrapper->new($repo), $remote );
	my @ids     = map $m->enqueue( test_commit_id_task => [ $repo, $_ ] ), @commits;
	return $job->finish("done, queued: @ids");
}

sub test_commit_id_task( $self, $job, $repo, $commit_id ) {
	my $m = $self->minion;
	return $self->reschedule( $job, "Previous test run is still active" ) unless           #
	  my $guard = $m->guard( "test_commit_id_task$repo" => 86400 );

	my ($test_log) = capture_merged {
		chdir $repo or die "cannot chdir to $repo";
		Git::Wrapper->new($repo)->checkout($commit_id);
		$ENV{AUTOMATED_TESTING} = $ENV{PERL_MM_USE_DEFAULT} = 1;
		require CPAN;    # must be loaded after fork
		CPAN::Index->reload;
		CPAN::install(".");
	};
	$job->note( test_log => [ split /\n/, $test_log ] );
	my ($fail_list) = capture_merged { CPAN::Shell->failed };
	my ( $meth, $res ) = $fail_list =~ /Nothing failed in this session/    #
	  ? qw( finish PASS ) : qw( fail FAIL );
	$m->enqueue( send_email_task => [ $repo, $res, $test_log ] );
	return $job->$meth($res);
}

sub send_email_task( $self, $job, $repo, $res, $text,
	$email = $self->config->{email} || die "no email" )
{
	my $title     = "TinyGitCI result for $repo - $res";
	my $email_obj = Email::Simple                                          #
	  ->create( header => [ To => $email, From => $email, Subject => $title ], body => $text );
	die "error with email:\n" . dumper($email_obj) . "\n$@"
	  unless eval { Email::Sender::Simple->send($email_obj); 1 };
	return $job->finish;
}

sub reschedule ( $self, $job, $msg ) {
	$job->note($msg);
	$job->retry( { delay => 60 } );
	return;
}

1;
