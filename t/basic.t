package CPAN::HTTP::Client {    # mocked
	$INC{"CPAN/HTTP/Client.pm"} = 1;
	use Mu;
	use strictures 2;
	use experimental 'signatures';
	use Path::Tiny 'path';

	sub bail {
		$DB::single = $DB::single = 1;
		exit;    # i have no damn idea how to get debug output extracted here
	}

	sub mirror ( $, $remote, $local ) {
		my %known = (
			"https://cpan.org/authors/01mailrc.txt.gz" =>
			  "$basic_test::START_PATH/corpus/data/01mailrc.txt.gz",
			"https://cpan.org/modules/02packages.details.txt.gz" =>
			  "$basic_test::START_PATH/corpus/data/02packages.details.txt.gz",
			"https://cpan.org/modules/03modlist.data.gz" =>
			  "$basic_test::START_PATH/corpus/data/03modlist.data.gz",
		);
		bail unless    #
		  my $source = $known{$remote};
		path($source)->copy($local);
		return { success => 1 };
	}

	sub AUTOLOAD { bail }
	sub DESTROY  { }
}

package basic_test;

use strictures 2;
use Mojo::Base -strict, -signatures;

use Test::InDistDir;
use Test::More;
use Mojo::mysql;
use Mojo::URL;
use Test::Mojo;
use Devel::Confess;
use Path::Tiny;
use Time::HiRes 'time';
use Mojo::Util 'dumper';
use Cwd 'getcwd';

our $START_PATH = getcwd;

my $NOW = time;

main() unless caller;

sub ping_time () {
	my $time = time - $NOW;
	return if $time < 0.2;
	say( sprintf( "%.2f", $time ) . " spent at " . ( caller() )[2] );
	$NOW = time;
}

sub file_inc() { state $id = 1; "file" . $id++ }

sub main {
	# This test requires a PostgreSQL connection string for an existing database
	#
	#   TEST_ONLINE=postgres://tester:testing@/test prove -l t/*.t
	#

	# test setup follows
	plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

	$|++;
	$ENV{MOJO_PUBSUB_EXPERIMENTAL}++;
	$ENV{PATH} = "$ENV{PATH}:/usr/bin" if $ENV{USERNAME} eq "Mithaldu";    # provide git in vscode
	my $tmp_homedir = clean_environment();

	my $url     = Mojo::URL->new( $ENV{TEST_ONLINE} );
	my $db      = Mojo::mysql->new($url);
	my $test_db = "ci_test";
	$db->db->query("DROP SCHEMA IF EXISTS $test_db");
	$db->db->query("CREATE SCHEMA $test_db");
	$db->db->query("SET GLOBAL log_bin_trust_function_creators = 1");
	$url->path("/$test_db");

	my $remote_path = path("$tmp_homedir/remote_repo")->mkdir;
	my $local_path  = path("$tmp_homedir/local_repo")->mkdir;

	my $mail_dir = "$tmp_homedir/new";
	$ENV{EMAIL_SENDER_TRANSPORT}     = 'Maildir';
	$ENV{EMAIL_SENDER_TRANSPORT_dir} = $tmp_homedir;

	# start
	my $t = Test::Mojo->new(
		TinyGitCI => {
			minion  => { mysql => $url },
			repos   => [$local_path],
			secrets => ['test_s3cret'],
			email   => 'email_we_send_from@example.com',
		}
	);
	my $m = $t->app->minion;
	$t->ua->max_redirects(10);

	$t->get_ok('/')->status_is(200)->text_is( title => 'TinyGitCI v<test>' )
	  ->element_exists('a[href*="minion"]');

	my $remote = Git::Wrapper->new($remote_path);
	$remote->config(qw( --global user.name TEST ));
	$remote->config(qw( --global user.email test@example.com ));
	$remote->init;

	my $local = Git::Wrapper->new($local_path);
	$local->init( -bare );
	$local->remote( add => origin => $remote_path );

	my $id = $m->enqueue("queue_repo_fetch_task");
	$t->get_ok("/testruns/$id")->status_is(200)->text_is( title => 'Result' )
	  ->text_is( p => 'Waiting for result...' )->element_exists_not('table');
	$m->perform_jobs;
	$t->get_ok( "/testruns/" . ( 1 + $id ) )->status_is(200)->text_is( title => 'Result' )
	  ->element_exists_not('p')->element_exists_not('table')
	  ->text_like( span => qr/does not have any commits yet/ );

	path($mail_dir)->remove_tree;
	new_commit($remote);
	$id = $m->enqueue("queue_repo_fetch_task");
	$t->get_ok("/testruns/$id")->status_is(200)->text_is( title => 'Result' )
	  ->text_is( p => 'Waiting for result...' )->element_exists_not('table');
	wait_job_finished( $m, $id );
	$t->get_ok("/testruns/$id")->status_is(200)->text_is( title => 'Result' )
	  ->text_like( span => qr/done/ )->element_exists_not('table')->element_exists_not("p");
	wait_job_finished( $m, $id += 2 );
	$t->get_ok("/testruns/$id")->text_like( span => qr/FAIL/ );
	is $m->job( $id + 1 )->info->{state}, "finished";
	like( ( path($mail_dir)->children )[0]->slurp, qr/make -- NOT OK/ );

	path($mail_dir)->remove_tree;
	new_commit( $remote, "Makefile.PL", "use ExtUtils::MakeMaker;use Data::Dumper; WriteMakefile" );
	wait_job_finished( $m, $id = 2 + $m->enqueue("queue_repo_fetch_task") );
	$t->get_ok("/testruns/$id")->content_like(qr/PASS/);
	is $m->job( $id + 1 )->info->{state}, "finished";
	like( ( path($mail_dir)->children )[0]->slurp, qr/test -- OK/ );

	path($mail_dir)->remove_tree;
	new_commit( $remote, "t/base.t", "use Test2::V0;pass;done_testing" );
	wait_job_finished( $m, $id = 2 + $m->enqueue("queue_repo_fetch_task") );
	$t->get_ok("/testruns/$id")->content_like(qr/PASS/);
	is $m->job( $id + 1 )->info->{state}, "finished";
	like( ( path($mail_dir)->children )[0]->slurp, qr/test -- OK/ );

	path($mail_dir)->remove_tree;
	new_commit( $remote, "t/base.t", "use Test2::V0;fail;done_testing" );
	wait_job_finished( $m, $id = 2 + $m->enqueue("queue_repo_fetch_task") );
	$t->get_ok("/testruns/$id")->content_like(qr/Failed test at t\/base.t line 1/);
	is $m->job( $id + 1 )->info->{state}, "finished";
	like( ( path($mail_dir)->children )[0]->slurp, qr/test -- NOT OK/ );

	$t->get_ok("/")->content_like(qr/minion\/jobs(.|\n)*minion\/jobs(.|\n)*minion\/jobs/s);
	note $t->tx->res->body;

	undef $m->backend->mysql->{pubsub};
	$db->db->query("DROP SCHEMA $test_db");

	done_testing;
}

# see https://metacpan.org/release/ETHER/Dist-Zilla-Plugin-Git-2.051/source/t/lib/Util.pm
sub clean_environment () {
	my $tempdir = Path::Tiny->tempdir( CLEANUP => 1 );
	delete $ENV{$_} for grep /^G(?:IT|PG)_/i, keys %ENV;
	$ENV{HOME}                = $ENV{GNUPGHOME} = $tempdir->stringify;
	$ENV{GIT_CONFIG_NOSYSTEM} = 1;                                       # Don't read /etc/gitconfig
	$tempdir;
}

sub new_commit( $git, $file = file_inc, $content = "" ) {
	path( $git->dir, $file )->touchpath->spew($content);
	$git->add(".");
	$git->commit( { message => "." } );
	my ($id) = $git->rev_parse("HEAD");
	return $id;
}

sub wait_job_finished( $m, $id ) {
	$m->perform_jobs;
	$NOW = time;
	while ( !$m->job($id)->info->{finished} ) {
		last if time - $NOW > 3;
	}
	return;
}
