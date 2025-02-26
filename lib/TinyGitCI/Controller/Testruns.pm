package TinyGitCI::Controller::Testruns;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util 'dumper';

# ABSTRACT: web controller for test runs in TinyGitCI

# VERSION

=head1 DESCRIPTION

This mainly exists to provide a frontpage view of the most recent smoke runs
and to help testing a bit.

=cut

sub index ($self) {
	my @jobs;
	my $jobs = $self->minion->jobs( { tasks => ["test_commit_id_task"] } );
	while ( my $info = $jobs->next and @jobs < 10 ) {
		push @jobs, $info;
	}
	return $self->render( result => \@jobs );
}

sub result ($self) {
	return $self->reply->not_found unless    #
	  my $job = $self->minion->job( $self->param('id') );
	return $self->render                     #
	  ( result => $job->info->{result}, test_log => $job->info->{notes}{test_log} );
}

1;
